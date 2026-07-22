from collections import Counter
from dataclasses import dataclass

import hcl2
from hcl2.utils import SerializationOptions

# python-hcl2==8.1.2: string values are NOT unquoted by default (they retain
# literal surrounding double-quotes) unless strip_string_quotes=True is passed
# via serialization_options. Disable __comments__ output since we don't use it.
_SERIALIZATION_OPTIONS = SerializationOptions(strip_string_quotes=True, with_comments=False)


@dataclass
class User:
    key: dict
    ekus: list
    extra_extensions: list
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
            extra_extensions=u.get("extra_extensions", []),
            devices=u["devices"],
        )
    return Config(users=users, revoked_serials=revoked)
