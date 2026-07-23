# homelab-pki/reconcile/main.py
import base64, json, os, sys

def _b64(b): return base64.b64encode(b).decode()

def build_tfvars(config, plan, mint, kept, crl_pem):
    secrets = {}
    for name, serial in plan.create:
        b = mint(name, serial)
        secrets[f"pki-{name}-{serial}"] = _entry(name, serial, b)
    for name, serial in plan.keep:
        b = kept(name, serial)
        secrets[f"pki-{name}-{serial}"] = _entry(name, serial, b)
    return {"pki_secrets": secrets, "crl_pem_b64": _b64(crl_pem)}

def _entry(name, serial, b):
    return {"name": name, "serial": serial,
            "data": {"tls.crt": _b64(b.cert_pem), "tls.key": _b64(b.key_pem), f"{name}.p12": _b64(b.p12)}}

def main():
    from kubernetes import client, config as kcfg
    from reconcile.config import load_config
    from reconcile.plan import reconcile
    from reconcile import state, engine
    kcfg.load_incluster_config()
    v1 = client.CoreV1Api()
    ns = os.environ.get("PKI_NAMESPACE", "homelab-pki")
    cfg = load_config(os.environ.get("PKI_CONFIG", "/config/config.hcl"))
    existing = state.read_existing(ns, v1)
    counts = {}
    users_by_name = {}
    for uname, u in cfg.users.items():
        for dev, c in u.device_counts.items():
            counts[dev] = counts.get(dev, 0) + c
            users_by_name[dev] = u
    plan = reconcile(existing, counts, cfg.revoked_serials)
    ca_cert = os.environ.get("CA_CERT", "/ca/tls.crt")
    ca_key  = os.environ.get("CA_KEY",  "/ca/tls.key")
    def mint(name, serial):
        u = users_by_name[name]
        return engine.issue(name, serial, ca_cert, ca_key,
                            key_algo=u.key["algorithm"], key_size=u.key["size"],
                            ekus=tuple(u.ekus), identity=u.identity)
    def kept(name, serial):
        return state.read_bundle(name, serial, ns, v1)
    crl = engine.gen_crl(cfg.revoked_serials, ca_cert, ca_key)
    tf = build_tfvars(cfg, plan, mint, kept, crl)
    with open("/work/secrets.auto.tfvars.json", "w") as f:
        json.dump(tf, f)
    # delete-set is handled by OpenTofu (secrets absent from pki_secrets are pruned by for_each);
    # print it for the run log / trace.
    print("DELETE:", plan.delete, file=sys.stderr)

if __name__ == "__main__":
    main()
