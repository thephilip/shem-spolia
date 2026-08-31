#!/usr/bin/env python3
"""Verify a shem-spolia attest bundle. Python 3 stdlib only. See README.txt."""
import hashlib, json, sys
from pathlib import Path

def sha256_hex(b): return hashlib.sha256(b).hexdigest()

def main(argv):
    root = Path(argv[1] if len(argv) > 1 else ".")
    manifest = json.loads((root / "manifest.json").read_text())

    # Chain: fold sha256 over the exact events.jsonl line bytes.
    gc = manifest.get("gc")
    head = gc["portable_anchor"] if gc else sha256_hex(manifest["session_id"].encode("utf-8"))
    with (root / "events.jsonl").open("rb") as f:
        n = 0
        for raw in f:
            line = raw.rstrip(b"\n")
            if not line:
                continue
            head = sha256_hex(head.encode("utf-8") + line)
            n += 1

    if gc:
        range_str = f'{gc["pruned_count"] + 1}-{gc["pruned_count"] + n}'
    else:
        range_str = f"1-{n}"

    ok = True
    if head == manifest["portable_head"]:
        print(f"events {range_str} OK · portable head {head[:12]}… matches")
    else:
        ok = False
        print(f"CHAIN MISMATCH: recomputed {head[:12]}… != manifest {manifest['portable_head'][:12]}…")

    if gc:
        print(f'events 1-{gc["pruned_count"]} pruned (digest anchor {gc["portable_anchor"][:12]}…); remainder verified from anchor')

    for t in manifest["tools"]:
        if t["status"] != "present":
            print(f"tool {t['name']}: MISSING from source system at export (not in bundle)")
            continue
        matches = [p for p in (root / "tools").glob(t["sha256"] + ".*")]
        if not matches:
            ok = False; print(f"tool {t['name']}: file missing"); continue
        actual = sha256_hex(matches[0].read_bytes())
        if actual == t["sha256"]:
            print(f"tool {t['name']}: sha256 OK")
        else:
            ok = False; print(f"tool {t['name']}: SHA MISMATCH")

    bh = manifest.get("beam_head")
    if bh:
        print(f"beam head {bh[:12]}… (cross-check with `shem_audit verify` on the source system; not recomputable here)")

    print("VERIFIED" if ok else "FAILED")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv))