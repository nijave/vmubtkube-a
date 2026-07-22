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
    """Read the cfssl signing profile's expiry (e.g. "175320h") so the final,
    explicitly-serialed cert (see `issue`) gets the same lifetime cfssl would
    have given it, without duplicating the value as a separate constant."""
    with open(cfg_path) as f:
        cfg = json.load(f)
    expiry = cfg["signing"]["profiles"][profile]["expiry"]
    hours = int(re.match(r"^(\d+)h$", expiry).group(1))
    return max(1, hours // 24)


def issue(name, serial_hex, ca_cert, ca_key, key_algo="RSA", key_size=2048,
          ekus=("clientAuth",), extra_extensions=(), domain=DOMAIN, p12_password="password"):
    cn = f"{name}.{domain}"
    with tempfile.TemporaryDirectory() as d:
        key = os.path.join(d, "k.pem"); csr = os.path.join(d, "c.csr")
        _run(["openssl", "genrsa", "-out", key, str(key_size)])
        # CSR carries SAN + any custom-OID extensions (copied by cfssl copy_extensions).
        ext = [f"subjectAltName=DNS:{cn}"]
        for e in extra_extensions:
            crit = "critical," if e.get("critical") else ""
            ext.append(f"{e['oid']}={crit}DER:{e['value_b64']}")   # value pre-encoded; adjust if base64
        cnf = os.path.join(d, "csr.cnf")
        with open(cnf, "w") as f:
            f.write("[req]\ndistinguished_name=dn\nreq_extensions=e\n[dn]\n[e]\n" + "\n".join(ext) + "\n")
        _run(["openssl", "req", "-new", "-key", key, "-subj", f"/CN={cn}", "-config", cnf, "-out", csr])

        # cfssl's "client" profile stamps the correct extensions (keyUsage,
        # clientAuth EKU, basicConstraints CA:FALSE, and copies the CSR's SAN/
        # extra extensions), but `cfssl sign` has no CLI flag for an explicit
        # certificate serial number -- verified against cfssl 1.6.5: the CLI's
        # SignRequest never populates the library-only `Serial` field, so any
        # serial we passed would be silently ignored. cfssl always assigns a
        # random serial here. We re-sign with openssl afterwards (below) to
        # stamp the caller-supplied serial while preserving cfssl's extensions
        # (openssl `x509 -CA` copies the input cert's extensions verbatim).
        cfg = CA_CONFIG
        signed = _run(["cfssl", "sign", "-ca", ca_cert, "-ca-key", ca_key,
                       "-config", cfg, "-profile", "client",
                       f"-hostname={cn}", csr])
        cfssl_cert_pem = json.loads(signed.stdout)["cert"].encode()
        cfssl_crt = os.path.join(d, "cfssl_leaf.pem")
        with open(cfssl_crt, "wb") as f:
            f.write(cfssl_cert_pem)

        days = _profile_expiry_days(cfg)
        crt = os.path.join(d, "leaf.pem")
        _run(["openssl", "x509", "-in", cfssl_crt, "-CA", ca_cert, "-CAkey", ca_key,
              "-set_serial", str(int(serial_hex, 16)), "-days", str(days), "-out", crt])
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
