import json, subprocess, os
import pytest
from reconcile.engine import issue, gen_crl, _profile_expiry_days
from reconcile.config import Identity

def _throwaway_ca(d):
    key = os.path.join(d, "ca.key"); crt = os.path.join(d, "ca.crt")
    subprocess.run(["openssl","genrsa","-out",key,"2048"], check=True)
    subprocess.run(["openssl","req","-x509","-new","-key",key,"-days","3650","-subj","/O=test-ca",
                    "-addext","basicConstraints=critical,CA:TRUE","-out",crt], check=True)
    return crt, key

def test_issue_client_cert(tmp_path):
    crt, key = _throwaway_ca(str(tmp_path))
    b = issue("nick-desktop", "0x2001", crt, key)
    leaf = tmp_path / "leaf.pem"; leaf.write_bytes(b.cert_pem)
    text = subprocess.run(["openssl","x509","-in",str(leaf),"-noout","-text"], capture_output=True, text=True).stdout
    assert "TLS Web Client Authentication" in text
    assert "nick-desktop.ha.apps.somemissing.info" in text
    assert "2001" in subprocess.run(["openssl","x509","-in",str(leaf),"-noout","-serial"],
                                    capture_output=True, text=True).stdout.lower()
    assert b.p12 and b.key_pem.startswith(b"-----BEGIN")

def test_issue_bakes_identity_subject_dn_and_san_emails(tmp_path):
    crt, key = _throwaway_ca(str(tmp_path))
    ident = Identity(
        uid="nickv-uid", display_name="Nick V Display", given_name="Nick", surname="Venenga",
        organization="homelab-org", organizational_units=["admins-ou", "sre-ou"],
        primary_email="nick@example.com", additional_email_addresses=["nick.alt@example.org"],
    )
    b = issue("nick-desktop", "0x2001", crt, key, identity=ident)
    leaf = tmp_path / "leaf.pem"; leaf.write_bytes(b.cert_pem)
    text = subprocess.run(["openssl","x509","-in",str(leaf),"-noout","-text"],
                          capture_output=True, text=True).stdout
    # subject DN carries every identity attribute (uid/displayName/GN/SN/O/OU)
    for value in ("nickv-uid", "Nick V Display", "homelab-org", "admins-ou", "sre-ou"):
        assert value in text, f"missing subject value {value!r}"
    # emails land in the SAN, primary first
    assert "nick@example.com" in text and "nick.alt@example.org" in text
    # profile still enforced
    assert "TLS Web Client Authentication" in text
    assert "nick-desktop.ha.apps.somemissing.info" in text

def test_gen_crl_lists_revoked(tmp_path):
    crt, key = _throwaway_ca(str(tmp_path))
    crl = gen_crl(["0x2002"], crt, key)
    out = tmp_path / "crl.pem"; out.write_bytes(crl)
    text = subprocess.run(["openssl","crl","-in",str(out),"-noout","-text"], capture_output=True, text=True).stdout
    assert "2002" in text.lower()

def test_profile_expiry_rejects_unsupported_format(tmp_path):
    cfg = tmp_path / "ca-config.json"
    cfg.write_text(json.dumps({"signing": {"profiles": {"client": {"expiry": "7305d"}}}}))
    with pytest.raises(ValueError):
        _profile_expiry_days(str(cfg))
