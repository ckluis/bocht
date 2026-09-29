# Bocht source bundle — pinned release r61

This is the actual framework source behind the Bocht site, packaged so the
claims on the site can be independently checked. Built and verified on
2026-09-28; this bundle was assembled 2026-09-29.

## What is pinned

- **Binary:** `medium/fresh/med_native_r61` (Linux x86-64 — will NOT run on a Mac)
- **Binary SHA-256:** `6d6806435e5d94fa1c86527b12075a7324ce5117888050463751f515357bd654`
- **Build input SHA-256:** `cedfe66d12142a1f946615555f92a5904f75176e349e7b6e31c3d67363a88ffd`
- **Manifest:** `manifest_r61.txt` binds that exact binary SHA to its test results
  (`RESULT: PASS=27 FAIL=0` for the bound item; the full Round 3 campaign ran
  200/200 against this binary)

## Contents

- `bocht-r61.bend` — the exact 8,777-line assembled program r61 was built from.
  SHA-256 `cedfe66d…` (verify: `sha256sum bocht-r61.bend`). This is the file to
  check and rebuild.
- `effs/` — the custom C effect implementations r61 was built against
  (`net_send_timeout.c`, `walfs_*.c`, `snap_hmac.c`, …). They are pulled in by
  `import "./effs/….c"` lines inside the .bend source; keep this directory next
  to `bocht-r61.bend`. (The `.js` files are the interpreter-backend variants.)
- `src/` — the same program split into 12 readable part-files
  (`med_types`, `med_util`, `med_sha`, `med_parse`, `med_store`, `med_svc`,
  `med_net`, `med_evt`, `med_auth`, `med_main`, `med_test`). Note: this is the
  living working copy and is *newer* than r61 (later work landed here). For
  verifying the pinned release, `bocht-r61.bend` is authoritative.
- `campaign/` — the verification tooling:
  - `verify_claims.py` — checks every evidence claim against files on disk
    (source SHA, binary SHA, build exit code, manifest binding). Run this first.
  - `stamp_manifest.sh` — binds a binary SHA-256 to result files after a test run.
  - `safe_native_build.sh` — builds to `<out>.new`, replaces `<out>` only on
    exit 0; a failed build can never delete the working binary.
  - `preflight.sh`, `check_pinned_backup.sh` — toolchain/disk checks and the
    pinned-binary backup canary.
- `tests/item197/` — the probe script bound by `manifest_r61.txt`
  (`item197.py`) and its result log. The pattern for all 200 campaign items:
  probe script → `RESULT: PASS=n FAIL=0` line → manifest stamp → verifier.

## Building on a Mac (Bend is cross-platform — do NOT use the Linux zip)

1. Install Bend natively: `curl -fsSL https://bend-lang.com/install.sh | sh`
   (the pinned r61 binary was built and verified with Bend 2.0.32; the r61
   source does NOT build under 2.0.34 — verified 2026-09-29, it needs a
   one-line `TCP.listen(host, port)` migration)
2. Install clang: `xcode-select --install`
3. Typecheck only: `bend bocht-r61.bend -o /tmp/bocht-r61.js`
4. Native build: `bend bocht-r61.bend -o bocht-r61` (~5 minutes; if `/tmp` is
   small set `TMPDIR` to a roomy directory first — the C codegen is large)
5. Compare: `sha256sum bocht-r61` will NOT match the pinned hash — the pinned
   binary is a Linux x86-64 build. What you can verify: it builds clean
   (exit 0), and the freshly built binary passes the probes below.

## Running it

- `./bocht-r61` listens on `127.0.0.1:18081` (plain HTTP).
- Auth: `BOCHT_API_KEYS="name:tenant:role"` env entries; requests carry
  `Authorization: Bearer <key>`.
- The source comments are the documentation — `med_types.bend` (types),
  `med_svc.bend` (service surface), `med_store.bend` (WAL + snapshots).

## Honest limits (read before judging)

- Single-node server. No replication, clustering, sharding, or consensus.
- WAL-backed persistence, but no guaranteed power-loss durability.
- The 200/200 campaign is a test suite passing against one binary, not a proof
  of correctness. `verify_claims.py` verifies that the *evidence* is real and
  bound to the binary — it does not verify the framework is bug-free.
- Bend's toolchain has been volatile (three breaking upgrades in 12 days:
  2.0.27, 2.0.29, 2.0.32, 2.0.34). The build works on 2.0.34; other versions
  may need the source migrations documented in the part-file headers.
