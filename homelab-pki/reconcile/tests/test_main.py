# homelab-pki/reconcile/tests/test_main.py
import base64
from reconcile.config import Config, User
from reconcile.plan import reconcile
from reconcile.main import build_tfvars
from reconcile.engine import CertBundle

def _bundle(tag): return CertBundle(key_pem=b"K"+tag, cert_pem=b"C"+tag, p12=b"P"+tag)

def test_build_tfvars_creates_and_keeps():
    cfg = Config(users={"nick": User(key={"algorithm":"RSA","size":2048}, ekus=["clientAuth"],
                                     extra_extensions=[], devices=["nick-desktop","nick-desktop"])},
                 revoked_serials=["0x9999"])
    existing = {"nick-desktop": ["2001"]}
    # keep 2001, create 1 new: next_serial after existing max 0x2001 (floor 0x2000) is 0x2002.
    plan = reconcile(existing, {"nick-desktop": 2}, cfg.revoked_serials)
    minted = {("nick-desktop","2002"): _bundle(b"11")}
    kept   = {("nick-desktop","2001"): _bundle(b"01")}
    tf = build_tfvars(cfg, plan, mint=lambda n,s: minted[(n,s)], kept=lambda n,s: kept[(n,s)],
                      crl_pem=b"CRLDATA")
    assert set(tf["pki_secrets"]) == {"pki-nick-desktop-2001", "pki-nick-desktop-2002"}
    entry = tf["pki_secrets"]["pki-nick-desktop-2002"]
    assert entry["data"]["tls.crt"] == base64.b64encode(b"C11").decode()
    assert entry["data"]["nick-desktop.p12"] == base64.b64encode(b"P11").decode()
    assert tf["crl_pem_b64"] == base64.b64encode(b"CRLDATA").decode()
