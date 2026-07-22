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
    # Resolved list of {"oid", "value", "critical"} — the shape engine.issue
    # consumes. Authored in HCL as a name->value (plain ASCII) map plus the
    # top-level `oids` registry; load_config() converts human-readable names to
    # dotted OIDs. The ASCII value is ASN1/UTF8String-encoded at issue time.
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


def _oid_registry(raw):
    """Parse the top-level `oids` map: human-readable name -> {oid, critical}."""
    registry = {}
    for name, spec in _unwrap(raw.get("oids", {})).items():
        spec = _unwrap(spec)
        registry[name] = {"oid": spec["oid"], "critical": bool(spec.get("critical", False))}
    return registry


def _resolve_extensions(ext_map, registry, user):
    """Convert a user's extra_extensions map (oid-name -> value_b64) into the
    internal list [{oid, value_b64, critical}] using the OID registry."""
    ext_map = _unwrap(ext_map)
    if isinstance(ext_map, list):
        if ext_map:
            raise ValueError(f"user {user!r}: extra_extensions must be a map of oid-name -> value_b64")
        return []
    resolved = []
    for oid_name, value in ext_map.items():
        if oid_name not in registry:
            raise ValueError(
                f"user {user!r} references unknown OID name {oid_name!r}; "
                f"add it to the top-level `oids` registry"
            )
        entry = registry[oid_name]
        resolved.append({"oid": entry["oid"], "value": value, "critical": entry["critical"]})
    return resolved


def load_config(path: str) -> Config:
    with open(path) as f:
        raw = hcl2.load(f, serialization_options=_SERIALIZATION_OPTIONS)

    registry = _oid_registry(raw)
    users_raw = _unwrap(raw["users"])
    revoked = _unwrap(raw.get("revoked_serials", []))

    users = {}
    for name, u in users_raw.items():
        u = _unwrap(u)
        users[name] = User(
            key=_unwrap(u["key"]),
            ekus=u.get("ekus", []),
            extra_extensions=_resolve_extensions(u.get("extra_extensions", {}), registry, name),
            devices=u["devices"],
        )
    return Config(users=users, revoked_serials=revoked)
