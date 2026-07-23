# homelab-pki/reconcile/state.py
import base64
from reconcile.engine import CertBundle

LABEL_SELECTOR = "pki/name,pki/serial"

def read_existing(namespace="homelab-pki", client=None):
    out = {}
    resp = client.list_namespaced_secret(namespace, label_selector=LABEL_SELECTOR)
    for it in resp.items:
        lbl = it.metadata.labels
        out.setdefault(lbl["pki/name"], []).append(lbl["pki/serial"])
    for k in out:
        out[k] = sorted(out[k], key=lambda x: int(x, 16))
    return out

def read_bundle(name, serial, namespace, client):
    s = client.read_namespaced_secret(f"pki-{name}-{serial}", namespace)
    d = s.data
    return CertBundle(
        key_pem=base64.b64decode(d["tls.key"]),
        cert_pem=base64.b64decode(d["tls.crt"]),
        p12=base64.b64decode(d[f"{name}.p12"]),
    )
