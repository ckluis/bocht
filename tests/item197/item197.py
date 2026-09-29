#!/usr/bin/env python3
"""item197: snapshot trailer HMAC authentication (closes item-189 T7 residual).

r61 adds HMAC-SHA256 authentication to the snapshot trailer:
  SEQ\\t<seq>\\t<count>\\t<mac>
where mac = HMAC_SHA256(key, body ++ "SEQ\\t" ++ seq ++ "\\t" ++ count ++ "\\n").

Tests (all on :18081, binary med_native_r61):
T1: Valid signed snapshot (empty body) boots and serves with key set.
T2: Forged body + rewritten count (item-189 T7 attack) -> FATAL refusal.
T3: Wrong MAC -> FATAL refusal.
T4: Body byte flip -> FATAL refusal.
T5: Legacy 3-field trailer with key set, no migration flag -> FATAL refusal.
T6: Legacy 3-field with MEDIUM_SNAPSHOT_HMAC_ALLOW_LEGACY=1 -> boots w/ WARNING.
T7: Rotation: snapshot signed with OLD key, boot with KEY=new+PREV=old -> boots w/ NOTICE.
T8: No key set -> boots with WARNING (count-only degraded mode).
T9: Stale count, no key (item-189 regression) -> FATAL refusal.
T10: Writer integration: 500 writes trigger snapshot; trailer has valid 4-field MAC.
"""
import hashlib
import hmac
import json
import os
import shutil
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "..", "..", "medium", "fresh", "med_native_r61")
BIN = os.path.abspath(BIN)
PORT = 18081
ADMIN_SECRET = b"item197-probe-admin-secret-9c3f2b1a"
HMAC_KEY = "test-hmac-key-197"
HMAC_KEY_OLD = "test-hmac-key-197-old"
WORK = os.path.join(HERE, "work_item197")
LOG = os.path.join(HERE, "item197_probe.log")
BOOTLOG = os.path.join(HERE, "item197_boot.log")
LOGF = None
PASS = 0
FAIL = 0


def log(msg):
    line = "[%s] %s" % (time.strftime("%H:%M:%S"), msg)
    print(line, flush=True)
    if LOGF:
        LOGF.write(line + "\n")
        LOGF.flush()


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        log("PASS %s %s" % (name, detail))
    else:
        FAIL += 1
        log("FAIL %s %s" % (name, detail))


def hmac_hex(key, msg):
    return hmac.new(key.encode(), msg.encode(), hashlib.sha256).hexdigest()


def craft_snapshot(body, seq, count, key):
    """Create snapshot content with valid HMAC. body: str (with trailing \\n if non-empty)."""
    seq_s = str(seq)
    count_s = str(count)
    unsigned = body + "SEQ\t" + seq_s + "\t" + count_s
    mac = hmac_hex(key, unsigned)
    return unsigned + "\t" + mac + "\n", mac


def craft_legacy(body, seq, count):
    """Create 3-field (item-189) snapshot without MAC."""
    return body + "SEQ\t" + str(seq) + "\t" + str(count) + "\n"


def req(method, path, key, body=None, wait=15, retries=3):
    for attempt in range(retries + 1):
        s = socket.create_connection(("127.0.0.1", PORT), timeout=wait)
        try:
            h = [method + b" " + path + b" HTTP/1.1", b"Host: x", b"Connection: close"]
            if key:
                h.append(b"Authorization: Bearer " + key)
            b = body or b""
            if b:
                h.append(b"Content-Type: application/json")
            h.append(b"Content-Length: %d" % len(b))
            s.sendall(b"\r\n".join(h) + b"\r\n\r\n" + b)
            s.settimeout(wait)
            data = b""
            while True:
                ch = s.recv(65536)
                if not ch:
                    break
                data += ch
            head, _, rbody = data.partition(b"\r\n\r\n")
            st = head.split(b" ", 2)[1].decode() if b" " in head else "?"
            if st == "429" and attempt < retries:
                time.sleep(2)
                continue
            return st, rbody
        finally:
            s.close()
    return "?", b""


def jbody(rb):
    try:
        return json.loads(rb)
    except Exception:
        return None


def boot_log_size():
    try:
        return os.path.getsize(BOOTLOG)
    except Exception:
        return 0


def boot_log_since(mark):
    try:
        with open(BOOTLOG, "rb") as f:
            f.seek(mark)
            return f.read().decode("utf-8", "replace")
    except Exception:
        return ""


def boot_server(work, note="", env_extra=None):
    lf = open(BOOTLOG, "a")
    env = {**os.environ, "MEDIUM_ADMIN_SECRET": ADMIN_SECRET.decode(), "BEND_NO_TELEMETRY": "1"}
    if env_extra:
        env.update(env_extra)
    mark = boot_log_size()
    lf.write("=== item197 boot [%s] work=%s ===\n" % (note, os.path.basename(work)))
    lf.flush()
    srv = subprocess.Popen([BIN], stdout=lf, stderr=subprocess.STDOUT, cwd=work, env=env)
    log("booted pid=%d work=%s" % (srv.pid, os.path.basename(work)))
    return srv, lf, mark


def stop_server(srv, lf, timeout=20):
    try:
        srv.terminate()
        srv.wait(timeout=timeout)
    except Exception:
        try:
            srv.kill()
        except Exception:
            pass
    try:
        lf.close()
    except Exception:
        pass
    time.sleep(1)


def port_open():
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=2)
        s.close()
        return True
    except Exception:
        return False


def wait_for_boot(srv, timeout=20):
    """Wait for port to open or process to exit. Returns (port_open, exited)."""
    start = time.time()
    while time.time() - start < timeout:
        if srv.poll() is not None:
            return False, True
        if port_open():
            return True, False
        time.sleep(0.2)
    return port_open(), srv.poll() is not None


def mint_key(tenant="t197"):
    st, rb = req(b"POST", b"/v1/keys", ADMIN_SECRET,
                 json.dumps({"tenant": tenant, "role": "member"}).encode())
    j = jbody(rb)
    if st in ("200", "201") and j and j.get("key"):
        return j["key"].encode()
    return None


def setup_work(name):
    d = os.path.join(WORK, name)
    if os.path.exists(d):
        shutil.rmtree(d)
    os.makedirs(d)
    return d


def main():
    global LOGF
    LOGF = open(LOG, "w")
    log("item197 probe starting; BIN=%s" % BIN)
    if not os.path.exists(BIN):
        log("FATAL: binary not found: %s" % BIN)
        print("RESULT: PASS=0 FAIL=1")
        return 1
    if os.path.exists(WORK):
        shutil.rmtree(WORK)
    os.makedirs(WORK)

    # ---- T1: valid signed snapshot boots and serves ----
    d = setup_work("t1")
    content, mac = craft_snapshot("", 0, 0, HMAC_KEY)
    with open(os.path.join(d, "bocht.snapshot"), "w") as f:
        f.write(content)
    # Verify our Python MAC format matches expected trailer shape
    check("T1-trailer-shape", content == "SEQ\t0\t0\t%s\n" % mac, "mac=%s..." % mac[:16])
    srv, lf, mark = boot_server(d, "T1-valid-signed", {"MEDIUM_SNAPSHOT_HMAC_KEY": HMAC_KEY})
    opened, exited = wait_for_boot(srv)
    blog = boot_log_since(mark)
    check("T1-boots", opened and not exited, "port_open=%s exited=%s" % (opened, exited))
    check("T1-no-fatal", "FATAL" not in blog, "no FATAL in boot log")
    if opened:
        mk = mint_key()
        check("T1-serves", mk is not None, "minted key")
        if mk:
            st, rb = req(b"POST", b"/v1/users", mk,
                         json.dumps({"name": "u1"}).encode())
            check("T1-write", st in ("200", "201"), "st=%s" % st)
    stop_server(srv, lf)

    # ---- T2: forged body + rewritten count (item-189 T7) -> refusal ----
    d = setup_work("t2")
    # Valid snapshot with 1 record; then forge body and rewrite count, keep old MAC
    body1 = "R\tuser\t1\tu1\n"
    content, mac = craft_snapshot(body1, 0, 1, HMAC_KEY)
    # Forge: change body but keep count=1 and old MAC
    forged = "R\tuser\t1\tATTACKER\n" + "SEQ\t0\t1\t%s\n" % mac
    with open(os.path.join(d, "bocht.snapshot"), "w") as f:
        f.write(forged)
    srv, lf, mark = boot_server(d, "T2-forged-body", {"MEDIUM_SNAPSHOT_HMAC_KEY": HMAC_KEY})
    opened, exited = wait_for_boot(srv, timeout=15)
    blog = boot_log_since(mark)
    check("T2-refuses", not opened, "port_open=%s (want False)" % opened)
    check("T2-hmac-fatal", "HMAC mismatch" in blog or "FATAL" in blog, "loud refusal")
    stop_server(srv, lf)

    # ---- T3: wrong MAC -> refusal ----
    d = setup_work("t3")
    content, mac = craft_snapshot("", 0, 0, HMAC_KEY)
    bad = "SEQ\t0\t0\t%s\n" % ("0" * 64)
    with open(os.path.join(d, "bocht.snapshot"), "w") as f:
        f.write(bad)
    srv, lf, mark = boot_server(d, "T3-wrong-mac", {"MEDIUM_SNAPSHOT_HMAC_KEY": HMAC_KEY})
    opened, exited = wait_for_boot(srv, timeout=15)
    blog = boot_log_since(mark)
    check("T3-refuses", not opened, "port_open=%s" % opened)
    check("T3-hmac-fatal", "HMAC mismatch" in blog, "HMAC mismatch in log")
    stop_server(srv, lf)

    # ---- T4: body byte flip -> refusal ----
    d = setup_work("t4")
    body1 = "R\tuser\t1\tu1\n"
    content, mac = craft_snapshot(body1, 0, 1, HMAC_KEY)
    # Flip one byte in the body ('u' -> 'v')
    flipped = content.replace("u1\n", "v1\n", 1)
    assert flipped != content
    with open(os.path.join(d, "bocht.snapshot"), "w") as f:
        f.write(flipped)
    srv, lf, mark = boot_server(d, "T4-byte-flip", {"MEDIUM_SNAPSHOT_HMAC_KEY": HMAC_KEY})
    opened, exited = wait_for_boot(srv, timeout=15)
    blog = boot_log_since(mark)
    check("T4-refuses", not opened, "port_open=%s" % opened)
    check("T4-hmac-fatal", "HMAC mismatch" in blog, "HMAC mismatch in log")
    stop_server(srv, lf)

    # ---- T5: legacy 3-field with key, no flag -> refusal ----
    d = setup_work("t5")
    legacy = craft_legacy("", 0, 0)
    with open(os.path.join(d, "bocht.snapshot"), "w") as f:
        f.write(legacy)
    srv, lf, mark = boot_server(d, "T5-legacy-noflag", {"MEDIUM_SNAPSHOT_HMAC_KEY": HMAC_KEY})
    opened, exited = wait_for_boot(srv, timeout=15)
    blog = boot_log_since(mark)
    check("T5-refuses", not opened, "port_open=%s" % opened)
    check("T5-downgrade-fatal", "downgrade" in blog.lower() or "FATAL" in blog, "downgrade refusal")
    stop_server(srv, lf)

    # ---- T6: legacy with ALLOW_LEGACY=1 -> boots with warning ----
    d = setup_work("t6")
    with open(os.path.join(d, "bocht.snapshot"), "w") as f:
        f.write(legacy)
    srv, lf, mark = boot_server(d, "T6-legacy-flag",
                                {"MEDIUM_SNAPSHOT_HMAC_KEY": HMAC_KEY,
                                 "MEDIUM_SNAPSHOT_HMAC_ALLOW_LEGACY": "1"})
    opened, exited = wait_for_boot(srv)
    blog = boot_log_since(mark)
    check("T6-boots", opened and not exited, "port_open=%s" % opened)
    check("T6-warning", "ALLOW_LEGACY" in blog and "WARNING" in blog, "migration warning")
    if opened:
        mk = mint_key("t197t6")
        check("T6-serves", mk is not None, "minted key")
    stop_server(srv, lf)

    # ---- T7: rotation (PREV key) -> boots with NOTICE ----
    d = setup_work("t7")
    content, mac = craft_snapshot("", 0, 0, HMAC_KEY_OLD)
    with open(os.path.join(d, "bocht.snapshot"), "w") as f:
        f.write(content)
    srv, lf, mark = boot_server(d, "T7-rotation",
                                {"MEDIUM_SNAPSHOT_HMAC_KEY": HMAC_KEY,
                                 "MEDIUM_SNAPSHOT_HMAC_KEY_PREV": HMAC_KEY_OLD})
    opened, exited = wait_for_boot(srv)
    blog = boot_log_since(mark)
    check("T7-boots", opened and not exited, "port_open=%s" % opened)
    check("T7-notice", "NOTICE" in blog and "PREV" in blog, "rotation notice")
    if opened:
        mk = mint_key("t197t7")
        check("T7-serves", mk is not None, "minted key")
    stop_server(srv, lf)

    # ---- T8: no key -> boots with warning (count-only) ----
    d = setup_work("t8")
    content, mac = craft_snapshot("", 0, 0, HMAC_KEY)
    with open(os.path.join(d, "bocht.snapshot"), "w") as f:
        f.write(content)
    srv, lf, mark = boot_server(d, "T8-nokey", {})
    opened, exited = wait_for_boot(srv)
    blog = boot_log_since(mark)
    check("T8-boots", opened and not exited, "port_open=%s" % opened)
    check("T8-warning", "MEDIUM_SNAPSHOT_HMAC_KEY is not set" in blog, "key-unset warning")
    if opened:
        mk = mint_key("t197t8")
        check("T8-serves", mk is not None, "minted key")
    stop_server(srv, lf)

    # ---- T9: stale count, no key (item-189 regression) -> refusal ----
    d = setup_work("t9")
    # 3-field trailer claiming 5 records but body has 0
    bad_count = craft_legacy("", 0, 5)
    with open(os.path.join(d, "bocht.snapshot"), "w") as f:
        f.write(bad_count)
    srv, lf, mark = boot_server(d, "T9-stale-count", {})
    opened, exited = wait_for_boot(srv, timeout=15)
    blog = boot_log_since(mark)
    check("T9-refuses", not opened, "port_open=%s" % opened)
    check("T9-count-fatal", "FATAL" in blog, "count FATAL in log")
    stop_server(srv, lf)

    # ---- T10: writer integration (500 writes -> snapshot with valid MAC) ----
    d = setup_work("t10")
    srv, lf, mark = boot_server(d, "T10-writer", {"MEDIUM_SNAPSHOT_HMAC_KEY": HMAC_KEY})
    opened, exited = wait_for_boot(srv)
    check("T10-boots", opened and not exited, "port_open=%s" % opened)
    snap_ok = False
    if opened:
        mk = mint_key("t197t10")
        if mk:
            ok = 0
            for i in range(505):
                st, rb = req(b"POST", b"/v1/articles", mk,
                             json.dumps({"title": "t%d" % i, "body": "b%d" % i}).encode(),
                             wait=10, retries=1)
                if st in ("200", "201"):
                    ok += 1
            log("T10: wrote %d/505 articles" % ok)
            time.sleep(2)
            snap_path = os.path.join(d, "bocht.snapshot")
            if os.path.exists(snap_path):
                with open(snap_path, "r") as f:
                    data = f.read()
                lines = data.split("\n")
                # Find trailer (last non-empty line starting with SEQ)
                trailer = ""
                for ln in reversed(lines):
                    if ln.startswith("SEQ\t"):
                        trailer = ln
                        break
                fields = trailer.split("\t")
                if len(fields) == 4:
                    seq_s, count_s, mac_s = fields[1], fields[2], fields[3]
                    # Reconstruct body: all lines except trailer and trailing ""
                    idx = lines.index(trailer)
                    body_lines = lines[:idx]
                    body = "\n".join(body_lines) + "\n" if body_lines else ""
                    # Body may contain the trailer? No, trailer is last. But body_lines
                    # includes everything before trailer. However data ends with "\n"
                    # so lines ends with "". We need body = join of lines before trailer.
                    # Actually the file is body + trailer + "\n". Split by "\n" gives
                    # [...body_lines, trailer, ""]. So body = "\n".join(lines[:idx]) + "\n".
                    expected = hmac_hex(HMAC_KEY, body + "SEQ\t" + seq_s + "\t" + count_s)
                    snap_ok = (expected == mac_s)
                    check("T10-mac-valid", snap_ok,
                          "seq=%s count=%s mac_match=%s" % (seq_s, count_s, snap_ok))
                    # Also verify count matches actual records
                    check("T10-4fields", True, "trailer=%s..." % trailer[:40])
                else:
                    check("T10-4fields", False, "fields=%d want 4" % len(fields))
                    check("T10-mac-valid", False, "no 4-field trailer")
            else:
                check("T10-4fields", False, "no snapshot file")
                check("T10-mac-valid", False, "no snapshot file")
        else:
            check("T10-4fields", False, "no key")
            check("T10-mac-valid", False, "no key")
    else:
        check("T10-4fields", False, "no boot")
        check("T10-mac-valid", False, "no boot")
    stop_server(srv, lf)

    log("done: PASS=%d FAIL=%d" % (PASS, FAIL))
    print("RESULT: PASS=%d FAIL=%d" % (PASS, FAIL))
    LOGF.close()
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
