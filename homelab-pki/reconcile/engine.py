import base64
import json
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass

DOMAIN = "ha.apps.somemissing.info"
CA_CONFIG = os.path.join(os.path.dirname(__file__), "..", "cfssl", "ca-config.json")


@dataclass
class CertBundle:
    key_pem: bytes
    cert_pem: bytes
    p12: bytes


def _run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, **kw)


def _profile_expiry_days(cfg_path, profile="client"):
    """Read the cfssl signing profile's expiry (e.g. "175320h") for the leaf
    lifetime, so the value lives in one place (ca-config.json) rather than a
    duplicated constant. (cfssl itself is now used only for gen_crl.)"""
    with open(cfg_path) as f:
        cfg = json.load(f)
    expiry = cfg["signing"]["profiles"][profile]["expiry"]
    m = re.match(r"^(\d+)h$", expiry)
    if not m:
        raise ValueError(f"unsupported cfssl profile expiry format (want '<N>h'): {expiry!r}")
    return max(1, int(m.group(1)) // 24)


def _dn(name, domain, identity):
    """openssl req config building the leaf subject DN from the identity. Field
    names mirror python-envoy-authz's ClientIdentity; displayName is registered
    via oid_section since openssl has no built-in short name for it."""
    cn = getattr(identity, "common_name", None) or f"{name}.{domain}"
    lines = [f"CN = {cn}"]

    def add(field, attr):
        val = getattr(identity, attr, None) if identity else None
        if val:
            lines.append(f"{field} = {val}")

    add("UID", "uid")                 # 0.9.2342.19200300.100.1.1
    # openssl has no built-in short name for displayName in this build; the
    # `OID.<dotted>` form is the portable way to put an arbitrary OID in the DN.
    add("OID.2.16.840.1.113730.3.1.241", "display_name")  # displayName
    add("GN", "given_name")           # 2.5.4.42
    add("SN", "surname")              # 2.5.4.4
    add("O", "organization")          # 2.5.4.10
    ous = (getattr(identity, "organizational_units", None) or []) if identity else []
    for i, ou in enumerate(ou for ou in ous if ou):
        lines.append(f"{i}.OU = {ou}")  # 2.5.4.11 (numbered so keys stay unique)

    return (
        "[req]\nprompt = no\ndistinguished_name = dn\n"
        "string_mask = utf8only\nutf8 = yes\n"
        "[dn]\n" + "\n".join(lines) + "\n"
    )


def _ext(name, domain, ekus, identity):
    """openssl x509 extension file: leaf key usage/EKU/basic constraints plus a
    SAN with the device DNS name and the identity's rfc822Name email(s)."""
    eku = ", ".join(ekus) if ekus else "clientAuth"
    san = [f"DNS.1 = {name}.{domain}"]
    emails = []
    if identity:
        if getattr(identity, "primary_email", None):
            emails.append(identity.primary_email)
        emails += [e for e in (getattr(identity, "additional_email_addresses", None) or []) if e]
    for i, email in enumerate(emails, start=1):
        san.append(f"email.{i} = {email}")
    return (
        "[e]\n"
        "basicConstraints = critical, CA:FALSE\n"
        "keyUsage = critical, digitalSignature, keyEncipherment\n"
        f"extendedKeyUsage = {eku}\n"
        "subjectKeyIdentifier = hash\n"
        "authorityKeyIdentifier = keyid, issuer\n"
        "subjectAltName = @alt\n"
        "[alt]\n" + "\n".join(san) + "\n"
    )


def issue(name, serial_hex, ca_cert, ca_key, key_algo="RSA", key_size=2048,
          ekus=("clientAuth",), identity=None, domain=DOMAIN, p12_password="password"):
    with tempfile.TemporaryDirectory() as d:
        key = os.path.join(d, "k.pem")
        csr = os.path.join(d, "c.csr")
        _run(["openssl", "genrsa", "-out", key, str(key_size)])

        csr_cnf = os.path.join(d, "csr.cnf")
        with open(csr_cnf, "w") as f:
            f.write(_dn(name, domain, identity))
        # subject DN comes from the config's [dn]; no -subj.
        _run(["openssl", "req", "-new", "-key", key, "-config", csr_cnf, "-out", csr])

        ext_cnf = os.path.join(d, "ext.cnf")
        with open(ext_cnf, "w") as f:
            f.write(_ext(name, domain, ekus, identity))

        # openssl x509 -req preserves the CSR's full multi-attribute subject and
        # sets the explicit serial directly, in one signing step (cfssl sign has
        # no serial flag and can drop non-standard subject attributes).
        crt = os.path.join(d, "leaf.pem")
        _run(["openssl", "x509", "-req", "-in", csr, "-CA", ca_cert, "-CAkey", ca_key,
              "-set_serial", str(int(serial_hex, 16)), "-days", str(_profile_expiry_days(CA_CONFIG)),
              "-sha256", "-extfile", ext_cnf, "-extensions", "e", "-out", crt])
        cert_pem = open(crt, "rb").read()

        p12 = os.path.join(d, "b.p12")
        _run(["openssl", "pkcs12", "-export", "-out", p12, "-inkey", key, "-in", crt,
              "-passout", f"pass:{p12_password}"])
        return CertBundle(key_pem=open(key, "rb").read(), cert_pem=cert_pem, p12=open(p12, "rb").read())


def gen_crl(revoked_serials, ca_cert, ca_key, expiry_hours=168):
    # cfssl gencrl takes decimal serials in the input file (verified against
    # cfssl 1.6.5) and prints base64-encoded DER on stdout (no PEM framing);
    # convert to PEM so downstream (Envoy/HTTPProxy) gets a standard CRL file.
    with tempfile.TemporaryDirectory() as d:
        serials = os.path.join(d, "serials")
        with open(serials, "w") as f:
            for s in revoked_serials:
                f.write(str(int(s, 16)) + "\n")
        out = _run(["cfssl", "gencrl", serials, ca_cert, ca_key, str(expiry_hours * 3600)])
        der = base64.b64decode(out.stdout.strip())
        pem = _run(["openssl", "crl", "-inform", "DER", "-outform", "PEM"], input=der).stdout
        return pem
