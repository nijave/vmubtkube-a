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
