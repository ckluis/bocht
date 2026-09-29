#!/usr/bin/env python3
"""Verify hardening_status.md Evidence claims against files on disk.

Checks:
  1. Source file exists and SHA-256 matches the claimed Source SHA-256.
  2. Binary file exists and SHA-256 matches the claimed Binary SHA-256.
  3. Build meta file exists and its EXIT_CODE is 0.
  4. The claimed "N/N PASS" is bound to the binary: the latest manifest_*.txt
     must exist, its BINARY_SHA256 must equal the claimed binary hash,
     its TOTAL_FAIL must be 0, and its TOTAL_PASS must equal the claimed N.
     (No manifest yet -> WARN, not fail; manifests are required going forward.)

Usage: verify_claims.py [status.md] [test-dir]
Exit 0 = all claims verified (warnings allowed); exit 1 = any check FAILED.
"""
import re, sys, hashlib, glob, os

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def main():
    status = os.path.expanduser(sys.argv[1]) if len(sys.argv) > 1 else \
        os.path.expanduser("~/workspace/bocht/.test_runs/hardening_status.md")
    tdir = os.path.expanduser(sys.argv[2]) if len(sys.argv) > 2 else \
        os.path.expanduser("~/workspace/bocht/.test_runs/fresh-r1/")
    text = open(status).read()
    fails, warns = [], []

    m = re.search(r"Build:\s*`([^`]+)`\s*\(\d+\s*lines?\)\s*(?:->|→)\s*`([^`]+)`\s*\((\d+)\s*bytes?\)", text)
    if not m:
        fails.append("could not parse Build line (expected: Build: `src` (N lines) -> `bin` (M bytes))")
        print("VERIFY: FAILED"); [print("  FAIL:", x) for x in fails]; return 1
    src_name, bin_name = m.group(1), m.group(2)
    src_sha = re.search(r"Source SHA-256:\s*`([0-9a-f]{64})`", text)
    bin_sha = re.search(r"Binary SHA-256:\s*`([0-9a-f]{64})`", text)
    meta_m = re.search(r"EXIT_CODE 0[^\n]*`([^`]+_meta\.txt)`", text)
    pass_m = re.search(r"\*\*(\d+)/(\d+)\s*PASS\*\*", text)
    # Also check for documented env-sensitive failures: **N/M PASS / K env-sensitive**
    env_m = re.search(r"\*\*(\d+)/(\d+)\s*PASS\s*/\s*(\d+)\s*env-sensitive", text)

    src_path = os.path.join(tdir, src_name)
    if not src_sha:
        fails.append("no Source SHA-256 claim found")
    elif not os.path.isfile(src_path):
        fails.append(f"source file missing on disk: {src_path}")
    elif sha256(src_path) != src_sha.group(1):
        fails.append(f"source sha mismatch: disk={sha256(src_path)[:16]}... claim={src_sha.group(1)[:16]}...")
    else:
        print(f"  OK: source {src_name} sha matches claim")

    bin_path = os.path.join(tdir, bin_name)
    if not bin_sha:
        fails.append("no Binary SHA-256 claim found")
    elif not os.path.isfile(bin_path):
        fails.append(f"binary missing on disk: {bin_path}")
    elif sha256(bin_path) != bin_sha.group(1):
        fails.append(f"binary sha mismatch: disk={sha256(bin_path)[:16]}... claim={bin_sha.group(1)[:16]}...")
    else:
        print(f"  OK: binary {bin_name} sha matches claim")

    if not meta_m:
        warns.append("no build meta file referenced in Evidence (expected `..._meta.txt`)")
    else:
        meta_path = os.path.join(tdir, meta_m.group(1))
        if not os.path.isfile(meta_path):
            fails.append(f"build meta missing: {meta_path}")
        else:
            mm = re.search(r"EXIT_CODE:\s*(\d+)", open(meta_path).read())
            if not mm or mm.group(1) != "0":
                fails.append(f"build meta EXIT_CODE != 0 in {meta_path}")
            else:
                print(f"  OK: {meta_m.group(1)} EXIT_CODE 0")

    # Manifest check: triggered by **N/M PASS** or **N/M PASS / K env-sensitive**
    # Scope the claim to the LATEST entry block only: the ledger is stacked
    # newest-first and older entries begin at the first "- Previous:" marker.
    # Taking the first env-sensitive pattern in the WHOLE file can compare an
    # older entry's numbers against the newest manifest and produce a false
    # failure (item 147 hit this: item 146's "2 env-sensitive" vs a 66/0 manifest).
    latest_block = text
    prev_m = re.search(r"(?m)^- Previous:", text)
    if prev_m:
        latest_block = text[:prev_m.start()]
    env_all = re.findall(r"\*\*(\d+)/(\d+)\s*PASS\s*/\s*(\d+)\s*env-sensitive", latest_block)
    pass_all = re.findall(r"\*\*(\d+)/(\d+)\s*PASS\*\*", latest_block)
    claimed_m = None
    env_fails = 0
    if env_all:
        claimed = int(env_all[0][0]); env_fails = int(env_all[0][2])
        claimed_m = True
    elif pass_all:
        claimed = int(pass_all[0][0])
        claimed_m = True
    if claimed_m:
        mans = sorted(glob.glob(os.path.join(tdir, "manifest_*.txt")))
        if not mans:
            warns.append(f"claimed {claimed}/{claimed} PASS has no manifest — stamp one with stamp_manifest.sh")
        else:
            man = open(mans[-1]).read()
            bsha = re.search(r"BINARY_SHA256:\s*([0-9a-f]{64})", man)
            tp = re.search(r"TOTAL_PASS:\s*(\d+)", man); tf = re.search(r"TOTAL_FAIL:\s*(\d+)", man)
            if not (bsha and tp and tf):
                fails.append(f"manifest {os.path.basename(mans[-1])} unreadable")
            elif bin_sha and bsha.group(1) != bin_sha.group(1):
                fails.append("manifest binds results to a DIFFERENT binary than claimed")
            elif int(tf.group(1)) == env_fails and int(tp.group(1)) == claimed:
                if env_fails:
                    print(f"  OK: manifest binds {claimed}/{claimed} PASS + {env_fails} documented env-sensitive FAILs to claimed binary")
                else:
                    print(f"  OK: manifest binds {claimed}/{claimed} PASS to claimed binary")
            elif int(tf.group(1)) != env_fails:
                fails.append(f"manifest shows TOTAL_FAIL={tf.group(1)} (expected {env_fails} documented env-sensitive)")
            elif int(tp.group(1)) != claimed:
                fails.append(f"manifest TOTAL_PASS={tp.group(1)} != claimed {claimed}")
            else:
                print(f"  OK: manifest binds {claimed}/{claimed} PASS to claimed binary")

    for w in warns: print("  WARN:", w)
    for f in fails: print("  FAIL:", f)
    print("VERIFY: " + ("FAILED" if fails else "PASSED"))
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
