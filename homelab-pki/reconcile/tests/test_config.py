from reconcile.config import load_config


def test_parses_users_counts_and_identity(tmp_path):
    (tmp_path / "c.hcl").write_text('''
revoked_serials = ["0x1000"]
users = {
  nick = {
    key = { algorithm = "RSA", size = 2048 },
    ekus = ["clientAuth"],
    identity = {
      uid = "nick",
      display_name = "Nick V",
      organization = "homelab",
      organizational_units = ["admins", "sre"],
      primary_email = "nick@example.com",
      additional_email_addresses = ["nick.alt@example.org"]
    },
    devices = ["nick-desktop","nick-desktop","pixel7"]
  }
}
''')
    c = load_config(str(tmp_path / "c.hcl"))
    assert c.revoked_serials == ["0x1000"]
    u = c.users["nick"]
    assert u.device_counts == {"nick-desktop": 2, "pixel7": 1}
    assert u.ekus == ["clientAuth"] and u.key["size"] == 2048
    i = u.identity
    assert i.uid == "nick"
    assert i.display_name == "Nick V"
    assert i.organization == "homelab"
    assert i.organizational_units == ["admins", "sre"]
    assert i.primary_email == "nick@example.com"
    assert i.additional_email_addresses == ["nick.alt@example.org"]
    # unset fields default to None / []
    assert i.surname is None and i.given_name is None and i.common_name is None


def test_absent_identity_defaults_empty(tmp_path):
    (tmp_path / "c.hcl").write_text('''
users = {
  nick = { key = { algorithm = "RSA", size = 2048 }, ekus = [], devices = ["d"] }
}
''')
    c = load_config(str(tmp_path / "c.hcl"))
    i = c.users["nick"].identity
    assert i.uid is None and i.organizational_units == [] and i.additional_email_addresses == []
