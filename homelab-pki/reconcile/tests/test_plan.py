from reconcile.plan import reconcile, norm_serial

BASE = {"nick-desktop": ["0x2001", "0x2002"], "pixel7": ["0x2010"]}

def test_case1_no_change_no_revoke():
    p = reconcile(existing=BASE, desired_counts={"nick-desktop": 2, "pixel7": 1}, revoked_serials=[])
    assert p.create == [] and p.delete == []
    assert sorted(p.keep) == [("nick-desktop","2001"),("nick-desktop","2002"),("pixel7","2010")]
    assert p.crl_serials == []

def test_case2_revoke_only_keeps_storage():
    p = reconcile(existing=BASE, desired_counts={"nick-desktop": 2, "pixel7": 1}, revoked_serials=["0x2002"])
    assert p.create == [] and p.delete == []            # revocation never deletes
    assert len(p.keep) == 3
    assert p.crl_serials == ["2002"]

def test_case3_shrink_deletes_arbitrary_no_crl():
    p = reconcile(existing=BASE, desired_counts={"nick-desktop": 1, "pixel7": 1}, revoked_serials=[])
    assert len(p.delete) == 1 and p.delete[0][0] == "nick-desktop"
    assert p.crl_serials == []

def test_case4_shrink_plus_revoke_deletes_the_revoked_one():
    p = reconcile(existing=BASE, desired_counts={"nick-desktop": 1, "pixel7": 1}, revoked_serials=["0x2002"])
    assert p.delete == [("nick-desktop","2002")]        # revoked-preferred deletion
    assert p.crl_serials == ["2002"]

def test_grow_allocates_above_floor_and_existing():
    p = reconcile(existing=BASE, desired_counts={"nick-desktop": 2, "pixel7": 1, "nick-ipad": 2}, revoked_serials=[])
    new = sorted(s for _, s in p.create)
    assert new == ["2011", "2012"]                      # max(existing=0x2010, floor)+1,+2
    assert all(n == "nick-ipad" for n, _ in p.create)

def test_idempotent():
    p1 = reconcile(existing=BASE, desired_counts={"nick-desktop": 2, "pixel7": 1}, revoked_serials=[])
    assert not p1.create and not p1.delete

def test_norm_serial():
    assert norm_serial("0x2001") == "2001" and norm_serial("2001") == "2001" and norm_serial("0X02001") == "2001"
