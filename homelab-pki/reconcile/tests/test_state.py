# homelab-pki/reconcile/tests/test_state.py
from reconcile.state import read_existing

class _FakeSecrets:
    def __init__(self, items): self._items = items
    def list_namespaced_secret(self, ns, label_selector=None):
        class R: pass
        r = R(); r.items = self._items; return r

class _Item:
    def __init__(self, name, serial):
        self.metadata = type("M", (), {"labels": {"pki/name": name, "pki/serial": serial}})

def test_groups_serials_by_name():
    fake = _FakeSecrets([_Item("nick-desktop","2001"), _Item("nick-desktop","2002"), _Item("pixel7","2010")])
    out = read_existing(client=fake)
    assert out == {"nick-desktop": ["2001","2002"], "pixel7": ["2010"]}
