import pytest

from reconcile.config import load_config


def test_parses_users_counts_and_resolves_oids(tmp_path):
    (tmp_path / "c.hcl").write_text('''
oids = {
  user_id = { oid = "1.3.6.1.4.1.99999.1", critical = false }
}
revoked_serials = ["0x1000"]
users = {
  nick = {
    key = { algorithm = "RSA", size = 2048 },
    ekus = ["clientAuth"],
    extra_extensions = { user_id = "QUJD" },
    devices = ["nick-desktop","nick-desktop","pixel7"]
  }
}
''')
    c = load_config(str(tmp_path / "c.hcl"))
    assert c.revoked_serials == ["0x1000"]
    u = c.users["nick"]
    assert u.device_counts == {"nick-desktop": 2, "pixel7": 1}
    assert u.ekus == ["clientAuth"] and u.key["size"] == 2048
    # human-readable name resolved to the registry's dotted OID + criticality
    assert u.extra_extensions == [
        {"oid": "1.3.6.1.4.1.99999.1", "value_b64": "QUJD", "critical": False}
    ]


def test_empty_extensions_map_ok(tmp_path):
    (tmp_path / "c.hcl").write_text('''
oids = {}
users = {
  nick = { key = { algorithm = "RSA", size = 2048 }, ekus = [], extra_extensions = {}, devices = ["d"] }
}
''')
    c = load_config(str(tmp_path / "c.hcl"))
    assert c.users["nick"].extra_extensions == []


def test_unknown_oid_name_raises(tmp_path):
    (tmp_path / "c.hcl").write_text('''
oids = {}
users = {
  nick = { key = { algorithm = "RSA", size = 2048 }, ekus = [], extra_extensions = { nope = "QUJD" }, devices = ["d"] }
}
''')
    with pytest.raises(ValueError, match="unknown OID name"):
        load_config(str(tmp_path / "c.hcl"))
