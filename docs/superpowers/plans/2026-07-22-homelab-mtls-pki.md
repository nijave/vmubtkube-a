# Homelab mTLS Client-Cert PKI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-run `make-ca/ca.sh` with a declarative, on-demand, in-cluster reconciler that issues Home Assistant mTLS client certs (custom-OID capable) and a CRL from the *preserved* existing CA, publishing results as Secrets.

**Architecture:** A one-shot container (OpenTofu + cfssl + openssl + a Python reconciler) runs as a Kubernetes `Job` (on config change) and a `CronJob` (CRL refresh). A Python **reconciler pre-step** reads the HCL config + current cluster state, computes the concrete per-serial plan (count-based), mints only new certs (reusing existing ones), and generates the CRL; it writes `secrets.auto.tfvars.json`. OpenTofu then materializes serial-keyed `kubernetes_secret`s + the CRL Secret, with state in the `kubernetes` backend. The CRL is distributed to consumer namespaces by an **in-cluster k8s→k8s copy** via external-secrets' kubernetes provider (the repo's existing `k8s-ca` pattern); Bitwarden is used *only* to deliver the CA key.

**Tech Stack:** OpenTofu ≥1.11 (`kubernetes` backend + `kubernetes` provider), cfssl/cfssljson, openssl, Python 3 (+`python-hcl2`, `pytest`), external-secrets (Bitwarden SM), Argo CD, Contour.

**Design spec:** `docs/superpowers/specs/2026-07-22-homelab-mtls-pki-design.md` (authoritative; read it first).

## Global Constraints

- **Preserve the CA.** Never generate/re-key the CA. The reconciler only *signs* with the imported CA cert+key.
- **OpenTofu ≥ 1.11**, image `ghcr.io/opentofu/opentofu:1.11` as the base (verified: v1.11.13, alpine, has `/bin/sh`).
- **Secrets never in git.** The **CA key** is delivered via Bitwarden SM (`ClusterSecretStore/default`) → `ExternalSecret` (it originates out-of-band). The **CRL stays in-cluster**: reconciler writes it in `homelab-pki`, and consumer namespaces copy it k8s→k8s via an external-secrets **kubernetes-provider** `SecretStore` (no Bitwarden round-trip).
- **Serials:** auto-assigned, hex, **start at `0x2000`** (legacy `ca.sh` certs occupy `0x1000`–`0x100x`). Allocation = `max(existing_serials ∪ {0x1FFF}) + 1, +2, …` (deterministic from cluster state).
- **Two orthogonal controls:** `devices` list → storage (count-based per name); `revoked_serials` → CRL only. See spec "Reconciliation semantics" — the four worked examples are the acceptance oracle.
- **Reconciler idempotency:** re-run with unchanged config + cluster state ⇒ no new certs, no diff.
- **Namespaces:** reconciler + state + per-device Secrets in `homelab-pki`; CRL consumed in `default` (HTTPProxy) and `projectcontour` (python-envoy-authz).
- **Domain:** `ha.apps.somemissing.info`; CN/SAN `<device>.ha.apps.somemissing.info`; leaf EKU `clientAuth`; CA is single-level, name-constrained (one CRL covers the chain).
- **Repo conventions:** Argo CD GitOps; manifests validated by `.ci/validate.sh` (kubeconform); stage explicit paths; images pushed to `registry.apps.nickv.me/nijave/…`.
- **Tracing is a SEPARATE commit after MVP** (Phase 8). Do not touch `application.otel-collector*.yaml` before then.

---

## File Structure

New directory `homelab-pki/` in the repo root:

```
homelab-pki/
  reconcile/
    plan.py            # pure reconciliation algorithm (no I/O) — the core, unit-tested
    engine.py          # cert/CRL generation via cfssl+openssl (subprocess)
    state.py           # read existing cert Secrets from the cluster (kubernetes client)
    config.py          # parse the HCL config (python-hcl2) into typed dicts
    main.py            # entrypoint: config + state -> plan -> engine -> secrets.auto.tfvars.json
    tests/
      test_plan.py     # the 4 worked examples + idempotency + serial allocation
      test_engine.py   # throwaway-CA issuance + CRL assertions (openssl-verified)
      test_config.py   # HCL parsing
  tofu/
    main.tf            # kubernetes backend + provider; for_each secrets + CRL from tfvars
    variables.tf       # pki_secrets, crl_pem_b64 (produced by the reconciler)
  cfssl/
    ca-config.json     # signing profiles (client profile: clientAuth, copy_extensions)
  Dockerfile           # opentofu base + cfssl + openssl + python3 + reconciler
  config.hcl           # the human-authored declarative config (users, revoked_serials)
```

New repo manifests (Argo-managed), added at repo root alongside existing ones:

```
namespace.homelab-pki.yaml         # the homelab-pki namespace
homelab-pki.yaml                   # SA, RBAC, ExternalSecret(CA), config-change Job, CRL CronJob
application.homelab-pki.yaml        # (only if a separate Argo app is needed; else root app picks it up)
```

Modified (Phase 7, load-bearing): `proxy_homeassistant.yaml`, `python-envoy-authz.yaml`.
Modified (Phase 8, separate commit): `application.otel-collector.yaml`, `application.otel-collector-contour.yaml`.

---

## Phase 1 — Reconciliation core (pure logic, unit-tested)

The algorithm is the highest-risk part; build it first, in isolation, with the spec's four worked examples as tests. No cluster, no cert-gen — pure data transforms.

### Task 1: `plan.py` — target serial set + create/keep/delete/revoke decisions

**Files:**
- Create: `homelab-pki/reconcile/plan.py`
- Test: `homelab-pki/reconcile/tests/test_plan.py`

**Interfaces:**
- Produces:
  - `reconcile(existing: dict[str, list[str]], desired_counts: dict[str, int], revoked_serials: list[str], serial_floor: int = 0x2000) -> Plan`
    - `existing`: `{name: [serial_hex, …]}` currently-stored certs (from cluster).
    - `desired_counts`: `{name: count}` from the `devices` list (duplicates collapsed to a count).
    - returns `Plan` dataclass with:
      - `create: list[tuple[str, str]]` — `(name, new_serial_hex)` to mint.
      - `keep: list[tuple[str, str]]` — `(name, serial_hex)` unchanged.
      - `delete: list[tuple[str, str]]` — `(name, serial_hex)` secrets to remove.
      - `crl_serials: list[str]` — exactly `revoked_serials` (normalized hex).
  - Serial normalization: `norm_serial(s: str) -> str` lowercases hex, strips `0x`, no leading zeros → canonical form for comparison.

- [ ] **Step 1: Write the failing tests (the four worked examples + idempotency + allocation)**

```python
# homelab-pki/reconcile/tests/test_plan.py
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cd homelab-pki && python -m pytest reconcile/tests/test_plan.py -v`
Expected: FAIL (`ModuleNotFoundError: reconcile.plan`).

- [ ] **Step 3: Implement `plan.py`**

```python
# homelab-pki/reconcile/plan.py
from dataclasses import dataclass, field

def norm_serial(s: str) -> str:
    s = s.strip().lower()
    if s.startswith("0x"):
        s = s[2:]
    s = s.lstrip("0") or "0"
    return s

@dataclass
class Plan:
    create: list = field(default_factory=list)   # (name, serial)
    keep:   list = field(default_factory=list)
    delete: list = field(default_factory=list)
    crl_serials: list = field(default_factory=list)

def reconcile(existing, desired_counts, revoked_serials, serial_floor=0x2000):
    existing = {n: [norm_serial(s) for s in v] for n, v in existing.items()}
    revoked = {norm_serial(s) for s in revoked_serials}
    plan = Plan(crl_serials=sorted(revoked, key=lambda x: int(x, 16)))

    # allocate new serials above floor and above every existing serial
    all_ints = [int(s, 16) for v in existing.values() for s in v]
    next_serial = max([serial_floor - 1] + all_ints) + 1

    names = set(existing) | set(desired_counts)
    for name in sorted(names):
        have = list(existing.get(name, []))
        want = desired_counts.get(name, 0)
        if len(have) <= want:
            for s in have:
                plan.keep.append((name, s))
            for _ in range(want - len(have)):
                plan.create.append((name, format(next_serial, "x")))
                next_serial += 1
        else:
            # shrink: delete (len-have - want), revoked-preferred, else arbitrary (lowest serial)
            to_delete = len(have) - want
            revoked_here = [s for s in have if s in revoked]
            others = sorted((s for s in have if s not in revoked), key=lambda x: int(x, 16))
            ordered_for_deletion = revoked_here + others          # prefer revoked first
            deleted = ordered_for_deletion[:to_delete]
            for s in have:
                (plan.delete if s in deleted else plan.keep).append((name, s))
    return plan
```

- [ ] **Step 4: Run to verify pass**

Run: `cd homelab-pki && python -m pytest reconcile/tests/test_plan.py -v`
Expected: PASS (7 passed).

- [ ] **Step 5: Commit**

```bash
git add homelab-pki/reconcile/plan.py homelab-pki/reconcile/tests/test_plan.py
git commit -m "feat(pki): count-based reconciliation core with worked-example tests"
```

### Task 2: `config.py` — parse the HCL config

**Files:**
- Create: `homelab-pki/reconcile/config.py`, `homelab-pki/config.hcl`
- Test: `homelab-pki/reconcile/tests/test_config.py`

**Interfaces:**
- Produces: `load_config(path: str) -> Config` where `Config` has `.users: dict[str, User]` and `.revoked_serials: list[str]`; `User` has `.key`, `.ekus`, `.extra_extensions`, `.device_counts: dict[str,int]` (the `devices` list collapsed to counts) and `.devices: list[str]` (raw).

- [ ] **Step 1: Write `config.hcl` (the authored config; matches spec)**

```hcl
# homelab-pki/config.hcl
revoked_serials = []

users = {
  nick = {
    key              = { algorithm = "RSA", size = 2048 }
    ekus             = ["clientAuth"]
    extra_extensions = []
    devices          = ["nick-desktop", "nick-ipad", "nick-xps", "pixel7"]
  }
  kara = {
    key              = { algorithm = "RSA", size = 2048 }
    ekus             = ["clientAuth"]
    extra_extensions = []
    devices          = ["kara-iphone"]
  }
}
```

- [ ] **Step 2: Write the failing test**

```python
# homelab-pki/reconcile/tests/test_config.py
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
```

- [ ] **Step 3: Run to verify failure**

Run: `cd homelab-pki && python -m pytest reconcile/tests/test_config.py -v` → FAIL (import error).

- [ ] **Step 4: Implement `config.py`**

```python
# homelab-pki/reconcile/config.py
from collections import Counter
from dataclasses import dataclass
import hcl2

@dataclass
class User:
    key: dict
    ekus: list
    extra_extensions: list
    devices: list
    @property
    def device_counts(self):
        return dict(Counter(self.devices))

@dataclass
class Config:
    users: dict
    revoked_serials: list

def load_config(path):
    with open(path) as f:
        raw = hcl2.load(f)                         # hcl2.load wraps values in single-item lists for blocks
    users_raw = raw["users"] if isinstance(raw["users"], dict) else raw["users"][0]
    revoked = raw.get("revoked_serials", [])
    revoked = revoked[0] if revoked and isinstance(revoked, list) and isinstance(revoked[0], list) else revoked
    users = {}
    for name, u in users_raw.items():
        users[name] = User(key=u["key"], ekus=u.get("ekus", []),
                            extra_extensions=u.get("extra_extensions", []), devices=u["devices"])
    return Config(users=users, revoked_serials=revoked)
```

> Note: `python-hcl2` sometimes wraps scalars in lists depending on version; the defensive unwrapping above handles both. Pin the version in the image (Task 7) and adjust if the test reveals a different shape.

- [ ] **Step 5: Run to verify pass**

Run: `cd homelab-pki && python -m pytest reconcile/tests/test_config.py -v` → PASS.

- [ ] **Step 6: Commit**

```bash
git add homelab-pki/reconcile/config.py homelab-pki/config.hcl homelab-pki/reconcile/tests/test_config.py
git commit -m "feat(pki): HCL config parser (users -> device counts, revoked_serials)"
```

---

## Phase 2 — Cert & CRL engine (cfssl + openssl)

### Task 3: `cfssl/ca-config.json` + `engine.py` issuance

**Files:**
- Create: `homelab-pki/cfssl/ca-config.json`, `homelab-pki/reconcile/engine.py`
- Test: `homelab-pki/reconcile/tests/test_engine.py`

**Interfaces:**
- Consumes: CA at paths `ca_cert_pem`, `ca_key_pem` (files).
- Produces:
  - `issue(name, serial_hex, ca_cert, ca_key, key_algo="RSA", key_size=2048, ekus=("clientAuth",), extra_extensions=(), domain="ha.apps.somemissing.info", p12_password="password") -> CertBundle` where `CertBundle` has `.key_pem`, `.cert_pem`, `.p12` (bytes). CN/SAN = `<name>.<domain>`; explicit serial = `int(serial_hex,16)`.
  - `gen_crl(revoked_serials, ca_cert, ca_key, expiry_hours=168) -> bytes` (PEM CRL) via `cfssl gencrl`.

- [ ] **Step 1: Write `cfssl/ca-config.json` (client profile mirroring `ca.sh`)**

```json
{
  "signing": {
    "default": { "expiry": "175320h" },
    "profiles": {
      "client": {
        "expiry": "175320h",
        "usages": ["signing", "digital signature", "key encipherment", "client auth"],
        "copy_extensions": true
      }
    }
  }
}
```

- [ ] **Step 2: Write the failing test (throwaway CA; asserts EKU/SAN/serial + CRL)**

```python
# homelab-pki/reconcile/tests/test_engine.py
import subprocess, tempfile, os
from reconcile.engine import issue, gen_crl

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

def test_gen_crl_lists_revoked(tmp_path):
    crt, key = _throwaway_ca(str(tmp_path))
    crl = gen_crl(["0x2002"], crt, key)
    out = tmp_path / "crl.pem"; out.write_bytes(crl)
    text = subprocess.run(["openssl","crl","-in",str(out),"-noout","-text"], capture_output=True, text=True).stdout
    assert "2002" in text.lower()
```

- [ ] **Step 3: Run to verify failure**

Run: `cd homelab-pki && python -m pytest reconcile/tests/test_engine.py -v` → FAIL (import error). (Requires `cfssl`+`openssl` on PATH; run inside the image once built, or install cfssl locally for dev.)

- [ ] **Step 4: Implement `engine.py`**

```python
# homelab-pki/reconcile/engine.py
import json, os, subprocess, tempfile
from dataclasses import dataclass

DOMAIN = "ha.apps.somemissing.info"

@dataclass
class CertBundle:
    key_pem: bytes
    cert_pem: bytes
    p12: bytes

def _run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, **kw)

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
        cfg = os.path.join(os.path.dirname(__file__), "..", "cfssl", "ca-config.json")
        out = _run(["cfssl", "sign", "-ca", ca_cert, "-ca-key", ca_key,
                    "-config", cfg, "-profile", "client",
                    f"-hostname={cn}", csr])
        cert_pem = json.loads(out.stdout)["cert"].encode()
        crt = os.path.join(d, "leaf.pem"); open(crt, "wb").write(cert_pem)
        p12 = os.path.join(d, "b.p12")
        _run(["openssl", "pkcs12", "-export", "-out", p12, "-inkey", key, "-in", crt,
              "-passout", f"pass:{p12_password}"])
        return CertBundle(key_pem=open(key, "rb").read(), cert_pem=cert_pem, p12=open(p12, "rb").read())

def gen_crl(revoked_serials, ca_cert, ca_key, expiry_hours=168):
    # cfssl gencrl reads a file of newline-separated serials (decimal or hex per cfssl docs -> use decimal).
    with tempfile.TemporaryDirectory() as d:
        serials = os.path.join(d, "serials")
        with open(serials, "w") as f:
            for s in revoked_serials:
                f.write(str(int(s, 16)) + "\n")
        out = _run(["cfssl", "gencrl", serials, ca_cert, ca_key, str(expiry_hours * 3600)])
        # cfssl gencrl returns base64 DER CRL on stdout; convert to PEM.
        der_b64 = out.stdout.strip()
        import base64
        der = base64.b64decode(der_b64)
        pem = _run(["openssl", "crl", "-inform", "DER", "-outform", "PEM"], input=der).stdout
        return pem
```

> Note: confirm `cfssl gencrl`'s serial format (decimal vs hex) and output encoding against the installed cfssl version during Step 5; adjust the decimal conversion / base64 decode if the version differs. The `test_gen_crl_lists_revoked` test is the oracle.

- [ ] **Step 5: Run to verify pass (inside the image or with cfssl+openssl installed)**

Run: `cd homelab-pki && python -m pytest reconcile/tests/test_engine.py -v`
Expected: PASS. If cfssl serial/encoding differs, fix `gen_crl`/`issue` until the openssl assertions pass.

- [ ] **Step 6: Commit**

```bash
git add homelab-pki/cfssl/ca-config.json homelab-pki/reconcile/engine.py homelab-pki/reconcile/tests/test_engine.py
git commit -m "feat(pki): cfssl+openssl issuance and CRL engine, openssl-verified"
```

### Task 4: `state.py` — read existing cert Secrets from the cluster

**Files:**
- Create: `homelab-pki/reconcile/state.py`
- Test: `homelab-pki/reconcile/tests/test_state.py`

**Interfaces:**
- Produces:
  - `read_existing(namespace="homelab-pki", client=None) -> dict[str, list[str]]` — lists Secrets labelled `pki/name` + `pki/serial`, returns `{name: [serial,…]}`.
  - `read_bundle(name, serial, namespace, client) -> CertBundle | None` — reads an existing cert Secret's `tls.crt`/`tls.key`/`<name>.p12` so kept serials are reused, never re-minted.
  - Secret naming: `pki-<name>-<serial>`; labels `pki/name=<name>`, `pki/serial=<serial>`; data keys `tls.crt`, `tls.key`, `<name>.p12`.

- [ ] **Step 1: Write the failing test (fake client)**

```python
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
```

- [ ] **Step 2: Run → FAIL.** `cd homelab-pki && python -m pytest reconcile/tests/test_state.py -v`

- [ ] **Step 3: Implement `state.py`**

```python
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
```

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit**

```bash
git add homelab-pki/reconcile/state.py homelab-pki/reconcile/tests/test_state.py
git commit -m "feat(pki): read existing cert Secrets to drive reconciliation and reuse"
```

### Task 5: `main.py` — orchestrate and emit `secrets.auto.tfvars.json`

**Files:**
- Create: `homelab-pki/reconcile/main.py`
- Test: `homelab-pki/reconcile/tests/test_main.py`

**Interfaces:**
- Produces: `build_tfvars(config, existing, bundles_for_kept, mint_fn, crl_fn) -> dict` returning:
  ```
  { "pki_secrets": { "pki-<name>-<serial>": {"name","serial","data":{"tls.crt","tls.key","<name>.p12"} (b64)} for create∪keep },
    "crl_pem_b64": "<b64 of crl.pem>" }
  ```
  and CLI `main()` that wires `config.load_config` + `state` (real kubernetes client) + `engine` and writes `/work/secrets.auto.tfvars.json`.

- [ ] **Step 1: Write the failing test (pure `build_tfvars`, injected fns)**

```python
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
                 revoked_serials=["0x2002"])
    existing = {"nick-desktop": ["2001"]}
    plan = reconcile(existing, {"nick-desktop": 2}, cfg.revoked_serials)   # keep 2001, create 1 new
    minted = {("nick-desktop","2011"): _bundle(b"11")}
    kept   = {("nick-desktop","2001"): _bundle(b"01")}
    tf = build_tfvars(cfg, plan, mint=lambda n,s: minted[(n,s)], kept=lambda n,s: kept[(n,s)],
                      crl_pem=b"CRLDATA")
    assert set(tf["pki_secrets"]) == {"pki-nick-desktop-2001", "pki-nick-desktop-2011"}
    entry = tf["pki_secrets"]["pki-nick-desktop-2011"]
    assert entry["data"]["tls.crt"] == base64.b64encode(b"C11").decode()
    assert entry["data"]["nick-desktop.p12"] == base64.b64encode(b"P11").decode()
    assert tf["crl_pem_b64"] == base64.b64encode(b"CRLDATA").decode()
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement `main.py`**

```python
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
                            ekus=tuple(u.ekus), extra_extensions=tuple(u.extra_extensions))
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
```

- [ ] **Step 4: Run → PASS** (`test_main.py`; the injected fns keep it cluster-free).

- [ ] **Step 5: Commit**

```bash
git add homelab-pki/reconcile/main.py homelab-pki/reconcile/tests/test_main.py
git commit -m "feat(pki): reconciler entrypoint emits secrets.auto.tfvars.json"
```

---

## Phase 3 — Container image

### Task 6: `Dockerfile` + CI build

**Files:**
- Create: `homelab-pki/Dockerfile`
- Modify: `.woodpecker.yaml` (add a build step) — or document a manual `docker build`/`push`.

**Interfaces:**
- Produces image `registry.apps.nickv.me/nijave/homelab-pki:<tag>` containing `tofu`, `cfssl`, `cfssljson`, `openssl`, `python3`, `python-hcl2`, `kubernetes` (py), and `/app/reconcile`.

- [ ] **Step 1: Write `Dockerfile`**

```dockerfile
# homelab-pki/Dockerfile
FROM ghcr.io/opentofu/opentofu:1.11
USER root
RUN apk add --no-cache cfssl openssl python3 py3-pip ca-certificates \
 && python3 -m pip install --break-system-packages python-hcl2==7.3.0 kubernetes==34.1.0 pytest==9.0.1
COPY reconcile/ /app/reconcile/
COPY cfssl/     /app/cfssl/
COPY tofu/      /app/tofu/
ENV PYTHONPATH=/app
ENTRYPOINT ["/bin/sh"]
```

> Pin the `apk`/`pip` versions to whatever the build resolves; the versions above are placeholders to be replaced with the actual resolved versions and committed (reproducibility).

- [ ] **Step 2: Build locally and run the full test suite inside the image (this is the test)**

Run:
```bash
cd homelab-pki
docker build -t registry.apps.nickv.me/nijave/homelab-pki:test .
docker run --rm registry.apps.nickv.me/nijave/homelab-pki:test \
  -c "cd /app && python -m pytest reconcile/tests -v"
```
Expected: all Phase 1–2 tests PASS *inside the image* (proves cfssl/openssl/python-hcl2 present and wired).

- [ ] **Step 3: Push a real tag**

Run:
```bash
docker tag registry.apps.nickv.me/nijave/homelab-pki:test registry.apps.nickv.me/nijave/homelab-pki:0.1.0
docker push registry.apps.nickv.me/nijave/homelab-pki:0.1.0
```

- [ ] **Step 4: Commit**

```bash
git add homelab-pki/Dockerfile
git commit -m "build(pki): reconciler image (opentofu+cfssl+openssl+python)"
```

---

## Phase 4 — OpenTofu apply module (verified in a throwaway namespace)

### Task 7: `tofu/main.tf` + `variables.tf` — materialize secrets + CRL

**Files:**
- Create: `homelab-pki/tofu/main.tf`, `homelab-pki/tofu/variables.tf`

**Interfaces:**
- Consumes: `secrets.auto.tfvars.json` (`pki_secrets`, `crl_pem_b64`) from the reconciler.
- Produces: one `kubernetes_secret` per `pki_secrets` key (labelled `pki/name`,`pki/serial`); one `kubernetes_secret` `pki-crl` (`crl.pem`). State in the `kubernetes` backend.

- [ ] **Step 1: Write `variables.tf`**

```hcl
# homelab-pki/tofu/variables.tf
variable "namespace"   { type = string, default = "homelab-pki" }
variable "pki_secrets" {
  type = map(object({ name = string, serial = string, data = map(string) }))
  default = {}
}
variable "crl_pem_b64" { type = string, default = "" }
```

- [ ] **Step 2: Write `main.tf`**

```hcl
# homelab-pki/tofu/main.tf
terraform {
  required_version = ">= 1.11.0"
  backend "kubernetes" {
    secret_suffix     = "homelab-pki"
    namespace         = "homelab-pki"
    in_cluster_config = true
  }
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
  }
}
provider "kubernetes" {}

resource "kubernetes_secret" "cert" {
  for_each = var.pki_secrets
  metadata {
    name      = each.key
    namespace = var.namespace
    labels    = { "pki/name" = each.value.name, "pki/serial" = each.value.serial }
  }
  # data values arrive base64 from the reconciler; kubernetes_secret expects raw,
  # so decode here (the provider re-encodes for the API).
  data = { for k, v in each.value.data : k => base64decode(v) }
  type = "Opaque"
}

resource "kubernetes_secret" "crl" {
  count = var.crl_pem_b64 == "" ? 0 : 1
  metadata { name = "pki-crl", namespace = var.namespace }
  data = { "crl.pem" = base64decode(var.crl_pem_b64) }
  type = "Opaque"
}

output "issued" { value = sort(keys(var.pki_secrets)) }
```

- [ ] **Step 3: Verify in a throwaway namespace with a throwaway CA (the test)**

This reuses the proven smoke-test shape. Create `homelab-pki-test`, an SA with the Role from Phase 5, a throwaway CA, run the reconciler+tofu in-cluster against a tiny config, and assert secrets appear. Concretely, run the image as a Job that (a) makes a throwaway CA, (b) runs `python -m reconcile.main`, (c) `tofu init && tofu apply`, then assert:

```bash
kubectl -n homelab-pki-test get secret -l pki/name --show-labels
kubectl -n homelab-pki-test get secret pki-crl -o jsonpath='{.data.crl\.pem}' | base64 -d | openssl crl -noout -text | head
```
Expected: one secret per device with `pki/name`,`pki/serial` labels; `pki-crl` parses as a CRL. Then `kubectl delete ns homelab-pki-test`.

- [ ] **Step 4: Commit**

```bash
git add homelab-pki/tofu/main.tf homelab-pki/tofu/variables.tf
git commit -m "feat(pki): opentofu module materializes per-serial secrets + CRL"
```

---

## Phase 5 — Deployment manifests (GitOps, gated)

### Task 8: namespace + RBAC + config ConfigMap + config-change Job + CRL CronJob

**Files:**
- Create: `namespace.homelab-pki.yaml`, `homelab-pki.yaml`

**Interfaces:**
- Produces: `homelab-pki` namespace; `pki-reconciler` SA + Role (secrets+leases, from the validated smoke test) + RoleBinding; a ConfigMap of `config.hcl`; a **config-hash-named Job** (immutable ⇒ new hash → new run) and a **CRL-refresh CronJob** (`concurrencyPolicy: Forbid`). Both run the image: `python -m reconcile.main && cd /app/tofu && tofu init -input=false && tofu apply -input=false -auto-approve`.

- [ ] **Step 1: Write `namespace.homelab-pki.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: homelab-pki
```

- [ ] **Step 2: Write `homelab-pki.yaml`** (SA, Role, RoleBinding, ConfigMap, Job, CronJob)

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: pki-reconciler, namespace: homelab-pki }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: pki-reconciler, namespace: homelab-pki }
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get","list","watch","create","update","patch","delete"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get","list","watch","create","update","patch","delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: pki-reconciler, namespace: homelab-pki }
subjects: [{ kind: ServiceAccount, name: pki-reconciler, namespace: homelab-pki }]
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: pki-reconciler }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: pki-config, namespace: homelab-pki }
data:
  config.hcl: |
    # keep in sync with homelab-pki/config.hcl (source of truth in git)
    revoked_serials = []
    users = {
      nick = { key = { algorithm = "RSA", size = 2048 }, ekus = ["clientAuth"], extra_extensions = [], devices = ["nick-desktop","nick-ipad","nick-xps","pixel7"] }
      kara = { key = { algorithm = "RSA", size = 2048 }, ekus = ["clientAuth"], extra_extensions = [], devices = ["kara-iphone"] }
    }
---
# Config-change Job. NOTE: name carries a config hash so a config change creates
# a NEW Job (immutable) and an unchanged config does not re-run. The hash is
# rendered by CI/Argo from the ConfigMap contents (see Step 4).
apiVersion: batch/v1
kind: Job
metadata:
  name: pki-reconcile-__CONFIG_HASH__
  namespace: homelab-pki
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: pki-reconciler
      containers:
        - name: reconcile
          image: registry.apps.nickv.me/nijave/homelab-pki:0.1.0
          env:
            - { name: HOME, value: /work }
            - { name: PKI_NAMESPACE, value: homelab-pki }
            - { name: PKI_CONFIG, value: /config/config.hcl }
            - { name: CA_CERT, value: /ca/tls.crt }
            - { name: CA_KEY,  value: /ca/tls.key }
          command: ["/bin/sh","-c"]
          args:
            - |
              set -eux
              python -m reconcile.main
              cp /work/secrets.auto.tfvars.json /app/tofu/
              cd /app/tofu
              tofu init -input=false -no-color
              tofu apply -input=false -auto-approve -no-color
          volumeMounts:
            - { name: config, mountPath: /config, readOnly: true }
            - { name: ca,     mountPath: /ca,     readOnly: true }
            - { name: work,   mountPath: /work }
      volumes:
        - { name: config, configMap: { name: pki-config } }
        - { name: ca, secret: { secretName: pki-ca } }          # delivered in Phase 6
        - { name: work, emptyDir: {} }
---
apiVersion: batch/v1
kind: CronJob
metadata: { name: pki-crl-refresh, namespace: homelab-pki }
spec:
  schedule: "0 3 * * *"          # daily; CRL validity 7d (168h) -> comfortable margin
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: pki-reconciler
          containers:
            - name: reconcile
              image: registry.apps.nickv.me/nijave/homelab-pki:0.1.0
              env:
                - { name: HOME, value: /work }
                - { name: PKI_NAMESPACE, value: homelab-pki }
                - { name: PKI_CONFIG, value: /config/config.hcl }
                - { name: CA_CERT, value: /ca/tls.crt }
                - { name: CA_KEY,  value: /ca/tls.key }
              command: ["/bin/sh","-c"]
              args:
                - |
                  set -eux
                  python -m reconcile.main
                  cp /work/secrets.auto.tfvars.json /app/tofu/
                  cd /app/tofu && tofu init -input=false -no-color && tofu apply -input=false -auto-approve -no-color
              volumeMounts:
                - { name: config, mountPath: /config, readOnly: true }
                - { name: ca,     mountPath: /ca,     readOnly: true }
                - { name: work,   mountPath: /work }
          volumes:
            - { name: config, configMap: { name: pki-config } }
            - { name: ca, secret: { secretName: pki-ca } }
            - { name: work, emptyDir: {} }
```

- [ ] **Step 3: Validate manifests locally (the test)**

Run: `.ci/validate.sh` (or `kubeconform -strict namespace.homelab-pki.yaml homelab-pki.yaml`).
Expected: no schema errors.

- [ ] **Step 4: Wire the config hash** (choose one, document in the file header)

Use a pre-commit/CI substitution that replaces `__CONFIG_HASH__` with `sha256sum` of the ConfigMap `data` (first 12 chars). Simplest: a `kustomization.yaml` `configMapGenerator` (hash suffix) + a Job that references it; or a small CI step. Record the chosen mechanism as a comment at the top of `homelab-pki.yaml`.

- [ ] **Step 5: Commit (do NOT let Argo sync yet — CA secret absent by design)**

```bash
git add namespace.homelab-pki.yaml homelab-pki.yaml
git commit -m "feat(pki): namespace, RBAC, config, config-change Job + CRL CronJob"
```

---

## Phase 6 — CA delivery + first real issuance

### Task 9: deliver the CA key/cert via Bitwarden + ExternalSecret, run first issuance

**Files:**
- Modify: `homelab-pki.yaml` (add the `ExternalSecret` for `pki-ca`)

**Interfaces:**
- Consumes: Bitwarden SM secrets `ca-ha.apps.somemissing.info` (cert, already present) and `ca-ha.apps.somemissing.info.key` (**you load this once**).
- Produces: Secret `pki-ca` in `homelab-pki` with `tls.crt` + `tls.key` for the reconciler to sign with.

- [ ] **Step 1: Load the CA key into Bitwarden (manual, out-of-band — never in git)**

Put the contents of `~/Documents/workspace/misc/make-ca/certs-and-keys/ca-ha.apps.somemissing.info.key.pem` into a Bitwarden SM secret named `ca-ha.apps.somemissing.info.key` (same project as the existing CA-cert secret).

- [ ] **Step 2: Add the `ExternalSecret` to `homelab-pki.yaml`**

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: pki-ca, namespace: homelab-pki }
spec:
  refreshInterval: 1h
  secretStoreRef: { name: default, kind: ClusterSecretStore }
  target: { name: pki-ca, template: { type: kubernetes.io/tls } }
  data:
    - secretKey: tls.crt
      remoteRef: { key: ca-ha.apps.somemissing.info }
    - secretKey: tls.key
      remoteRef: { key: ca-ha.apps.somemissing.info.key }
```

- [ ] **Step 3: Verify the CA secret materializes (the test)**

Run:
```bash
kubectl -n homelab-pki get secret pki-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -ext nameConstraints
```
Expected: subject `O=homelab`, nameConstraints permitting `ha.apps.somemissing.info`.

- [ ] **Step 4: Trigger the first reconcile Job and verify issuance**

Run (after Argo syncs, or `kubectl create job --from`):
```bash
kubectl -n homelab-pki get secret -l pki/name --show-labels
# pick one and verify it chains to the CA and is a client cert:
kubectl -n homelab-pki get secret pki-nick-desktop-2001 -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/leaf.pem
kubectl -n homelab-pki get secret pki-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/ca.pem
openssl verify -CAfile /tmp/ca.pem /tmp/leaf.pem
openssl x509 -in /tmp/leaf.pem -noout -text | grep -A1 "Extended Key Usage"
```
Expected: `OK`; EKU = `TLS Web Client Authentication`.

- [ ] **Step 5: Commit**

```bash
git add homelab-pki.yaml
git commit -m "feat(pki): deliver CA via Bitwarden ExternalSecret; first real issuance"
```

---

## Phase 7 — CRL distribution + consumption wiring (load-bearing)

### Task 10: copy the CRL k8s→k8s into consumer namespaces (external-secrets kubernetes provider)

The reconciler already writes the `pki-crl` Secret in `homelab-pki` (Task 7). Copy it into `default` and `projectcontour` in-cluster — the same mechanism `clusterissuer.yaml` uses for `k8s-ca`. **No Bitwarden.**

**Files:**
- Modify: `homelab-pki.yaml` (RBAC so consumer SAs can read `pki-crl`); `proxy_homeassistant.yaml` (SecretStore + ExternalSecret in `default`); `python-envoy-authz.yaml` (SecretStore + ExternalSecret in `projectcontour`).

**Interfaces:**
- Produces: Secret `pki-crl` (`crl.pem`) in `default` and `projectcontour`, copied from `homelab-pki/pki-crl`.

- [ ] **Step 1: In `homelab-pki.yaml`, grant consumer reader SAs read on the CRL Secret**

The kubernetes-provider `SecretStore` authenticates as a ServiceAccount in the *consumer* namespace; that identity needs read on `pki-crl` in `homelab-pki`. Create a reader SA per consumer namespace and bind it in `homelab-pki`:

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: pki-crl-reader, namespace: default }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: pki-crl-reader, namespace: projectcontour }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: pki-crl-reader, namespace: homelab-pki }
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["pki-crl"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: pki-crl-reader, namespace: homelab-pki }
subjects:
  - { kind: ServiceAccount, name: pki-crl-reader, namespace: default }
  - { kind: ServiceAccount, name: pki-crl-reader, namespace: projectcontour }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: pki-crl-reader }
```

- [ ] **Step 2: In `proxy_homeassistant.yaml` (`default`), add the kubernetes-provider SecretStore + ExternalSecret**

Mirrors the `k8s-ca` copy in `clusterissuer.yaml`, but `remoteNamespace: homelab-pki`:

```yaml
---
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata: { name: homelab-pki, namespace: default }
spec:
  provider:
    kubernetes:
      remoteNamespace: homelab-pki
      server:
        caProvider: { type: ConfigMap, name: kube-root-ca.crt, key: ca.crt }
      auth:
        serviceAccount: { name: pki-crl-reader }
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: pki-crl, namespace: default }
spec:
  refreshInterval: 15s
  secretStoreRef: { kind: SecretStore, name: homelab-pki }
  target: { name: pki-crl }
  data:
    - secretKey: crl.pem
      remoteRef: { key: pki-crl, property: crl.pem, conversionStrategy: Default, decodingStrategy: None, metadataPolicy: None }
```

- [ ] **Step 3: In `python-envoy-authz.yaml` (`projectcontour`), add the same SecretStore + ExternalSecret**

Identical to Step 2 but `namespace: projectcontour` on both the `SecretStore` and `ExternalSecret`.

- [ ] **Step 4: Verify the k8s→k8s copy (the test)**

Run:
```bash
kubectl -n default        get secret pki-crl -o jsonpath='{.data.crl\.pem}' | base64 -d | openssl crl -noout -lastupdate -nextupdate
kubectl -n projectcontour get secret pki-crl -o jsonpath='{.data.crl\.pem}' | base64 -d | openssl crl -noout -text | head
kubectl -n default get externalsecret pki-crl -o jsonpath='{.status.conditions[0].reason}'   # expect: SecretSynced
```
Expected: a valid CRL in both namespaces; `nextUpdate` ~7d out; `SecretSynced`.

- [ ] **Step 5: Commit**

```bash
git add homelab-pki.yaml proxy_homeassistant.yaml python-envoy-authz.yaml
git commit -m "feat(pki): copy CRL k8s->k8s into default+projectcontour (external-secrets kubernetes provider)"
```

### Task 11: wire the CRL into Contour `HTTPProxy`

**Files:**
- Modify: `proxy_homeassistant.yaml`

- [ ] **Step 1: Add `crlSecret` to `clientValidation`**

```yaml
    clientValidation:
      caSecret: ca-ha-homelab-somemissing-info-tls
      crlSecret: pki-crl                     # new
      optionalClientCertificate: true        # unchanged during migration
```

- [ ] **Step 2: Verify hot-reload + rejection (the test)**

Issue a throwaway client cert from the CA, revoke its serial (add to `config.hcl` `revoked_serials`, let the Job run), then:
```bash
# before revocation: succeeds; after (~15s): fails
curl -sk --cert client.p12-derived.pem --key client.key https://ha.apps.somemissing.info/ -o /dev/null -w '%{http_code}\n'
```
Expected: transitions to a TLS failure for the revoked cert on a **new** connection (existing sessions persist — documented). Confirm Envoy did not restart (`kubectl -n projectcontour get pods -l app.kubernetes.io/name=contour -w`).

- [ ] **Step 3: Commit**

```bash
git add proxy_homeassistant.yaml
git commit -m "feat(pki): enforce CRL at Contour HTTPProxy clientValidation"
```

### Task 12: python-envoy-authz manifest wiring (source change is cross-repo)

**Files:**
- Modify: `python-envoy-authz.yaml`

- [ ] **Step 1: Mount the CRL + env into the Deployment (mirrors `HA_CA_CERTIFICATE`)**

```yaml
        env:
          - name: HA_CRL
            valueFrom: { secretKeyRef: { name: pki-crl, key: crl.pem } }
```
(The Deployment already has `reloader.stakater.com/auto: "true"`, so a CRL change triggers a rollout.)

- [ ] **Step 2: Verify wiring only (the test)**

Run: `kubectl -n projectcontour set env deploy/python-envoy-authz --list | grep HA_CRL` and confirm the pod restarts on CRL change.
Expected: `HA_CRL` present. **Enforcement is inert until the cross-repo source change ships** (documented in the spec); open a tracking issue in the `python-envoy-authz` repo to check the presented cert's serial against `HA_CRL`.

- [ ] **Step 3: Commit**

```bash
git add python-envoy-authz.yaml
git commit -m "feat(pki): wire CRL into python-envoy-authz (source change tracked cross-repo)"
```

---

## Phase 8 — OpenTelemetry tracing (SEPARATE commit, after MVP is verified working)

### Task 13: enable OpenTofu tracing + wrapper spans + central-collector keep-policy

**Files:**
- Modify: `homelab-pki.yaml` (env on Job + CronJob), `homelab-pki/reconcile/main.py` (wrapper span, optional), `application.otel-collector.yaml`, `application.otel-collector-contour.yaml`.

- [ ] **Step 1: Add OTel env to both Job and CronJob containers**

```yaml
          env:
            - { name: OTEL_TRACES_EXPORTER, value: otlp }
            - { name: OTEL_EXPORTER_OTLP_ENDPOINT, value: "https://otel-collector.k8s.somemissing.info:4317" }
            - { name: OTEL_SERVICE_NAME, value: opentofu }
            - { name: OTEL_RESOURCE_ATTRIBUTES, value: "service.namespace=homelab-pki,tofu.project=homelab-pki" }
```

- [ ] **Step 2: Add the `opentofu` keep-policy to the central collector**

In `application.otel-collector.yaml`, add after the `claude-code` policy:

```yaml
              - name: opentofu
                type: ottl_condition
                ottl_condition:
                  error_mode: ignore
                  span:
                    - 'resource.attributes["service.name"] == "opentofu"'
```

- [ ] **Step 3: Add the clarifying comment to `application.otel-collector-contour.yaml`**

(The comment block explaining the ExtensionService exception — verbatim from the spec "CRL consumption / Collector routing" note.)

- [ ] **Step 4: Verify a trace lands (the test)**

Trigger a reconcile Job, then in HyperDX filter `service.namespace=homelab-pki`. Confirm one trace (OpenTofu spans) is retained (not 1%-sampled away) and `service.name=opentofu`.
Expected: trace visible; `tail_sampling` kept it via the new policy.

- [ ] **Step 5: Commit (separate from MVP)**

```bash
git add homelab-pki.yaml homelab-pki/reconcile/main.py application.otel-collector.yaml application.otel-collector-contour.yaml
git commit -m "feat(pki): OpenTelemetry tracing for reconciler runs (opentofu service.name)"
```

---

## Self-review notes (author → executor)

- **Spec coverage:** CA import/preserve (T9), fresh issuance + custom OIDs (T3), CRL (T3/T7), Secrets layout (T7), dual triggers (T8), CRL freshness CronJob (T8), consumption at both enforcement points (T11/T12), in-cluster k8s→k8s CRL distribution (T10), direct-to-central tracing + scope policy (T13). The four reconciliation worked examples are T1's tests.
- **Known confirmations required during execution (flagged inline, not placeholders):** exact `cfssl gencrl` serial format/encoding (T3 Step 5, oracle test provided); `python-hcl2` value-wrapping shape (T2 Step 4); the config-hash substitution mechanism (T8 Step 4). Each has a concrete verification and a default.
- **Load-bearing gates:** Phases 6–7 change running config; do them only after Phases 1–5 are green and after the throwaway-namespace verification (T7 Step 3) passes. The in-cluster smoke test already proved tofu+RBAC+backend work.
