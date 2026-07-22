from reconcile.config import load_config

def test_parses_users_and_counts(tmp_path):
    (tmp_path / "c.hcl").write_text('''
revoked_serials = ["0x1000"]
users = {
  nick = { key = { algorithm = "RSA", size = 2048 }, ekus = ["clientAuth"], extra_extensions = [], devices = ["nick-desktop","nick-desktop","pixel7"] }
}
''')
    c = load_config(str(tmp_path / "c.hcl"))
    assert c.revoked_serials == ["0x1000"]
    u = c.users["nick"]
    assert u.device_counts == {"nick-desktop": 2, "pixel7": 1}
    assert u.ekus == ["clientAuth"] and u.key["size"] == 2048
