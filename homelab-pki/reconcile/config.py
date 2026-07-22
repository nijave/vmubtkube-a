from collections import Counter
from dataclasses import dataclass, field

import hcl2
from hcl2.utils import SerializationOptions

# python-hcl2==8.1.2: string values are NOT unquoted by default (they retain
# literal surrounding double-quotes) unless strip_string_quotes=True is passed
# via serialization_options. Disable __comments__ output since we don't use it.
_SERIALIZATION_OPTIONS = SerializationOptions(strip_string_quotes=True, with_comments=False)


@dataclass
class Identity:
    """Subject-DN + SAN-email identity attributes baked into a device cert.

    Field names mirror python-envoy-authz's ClientIdentity model exactly, so a
    value set here is read back by that service. All optional; unset fields are
    simply not put on the cert. common_name defaults to the device hostname.
    """
    common_name: str | None = None                 # 2.5.4.3
    surname: str | None = None                      # 2.5.4.4
    given_name: str | None = None                   # 2.5.4.42
    display_name: str | None = None                 # 2.16.840.1.113730.3.1.241
    organization: str | None = None                 # 2.5.4.10
    organizational_units: list = field(default_factory=list)  # 2.5.4.11 (repeatable)
    uid: str | None = None                          # 0.9.2342.19200300.100.1.1
    primary_email: str | None = None                # SAN rfc822Name[0]
    additional_email_addresses: list = field(default_factory=list)  # SAN rfc822Name[1:]


@dataclass
class User:
    key: dict
    ekus: list
    identity: Identity
    devices: list

    @property
    def device_counts(self):
        return dict(Counter(self.devices))


@dataclass
class Config:
    users: dict
    revoked_serials: list


def _unwrap(value):
    """Defensively unwrap single-item list wrapping some python-hcl2 versions
    apply to block/scalar values. Observed unnecessary for python-hcl2==8.1.2
    with map-literal (`=`) syntax, but kept as a safety net across versions."""
    if isinstance(value, list) and len(value) == 1 and isinstance(value[0], (dict, list)):
        return value[0]
    return value


def _identity(raw):
    raw = _unwrap(raw or {})
    if isinstance(raw, list):  # empty `[]` or absent
        raw = {}
    return Identity(
        common_name=raw.get("common_name"),
        surname=raw.get("surname"),
        given_name=raw.get("given_name"),
        display_name=raw.get("display_name"),
        organization=raw.get("organization"),
        organizational_units=list(raw.get("organizational_units", []) or []),
        uid=raw.get("uid"),
        primary_email=raw.get("primary_email"),
        additional_email_addresses=list(raw.get("additional_email_addresses", []) or []),
    )


def load_config(path: str) -> Config:
    with open(path) as f:
        raw = hcl2.load(f, serialization_options=_SERIALIZATION_OPTIONS)

    users_raw = _unwrap(raw["users"])
    revoked = _unwrap(raw.get("revoked_serials", []))

    users = {}
    for name, u in users_raw.items():
        u = _unwrap(u)
        users[name] = User(
            key=_unwrap(u["key"]),
            ekus=u.get("ekus", []),
            identity=_identity(u.get("identity", {})),
            devices=u["devices"],
        )
    return Config(users=users, revoked_serials=revoked)
