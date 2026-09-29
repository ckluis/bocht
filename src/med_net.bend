# med_net.bend — custom native effects closing three Base 2.0.18 gaps.
#
# Base's TCP.send parks the task until the socket is writable with NO
# deadline (a zero-window peer parks the writer forever); TCP.accept
# discards the peer address (accept(fd, NULL, NULL)), making per-IP rate
# limiting impossible with stock effects; and there is no fsync primitive,
# so durability covers process crashes only. Each def below is a thin
# effect binding; the C implementations live in ./effs/ (the .js files are
# best-effort stubs — the campaign builds and tests native only).

def Net.send_timeout(sock: Socket, +data: String, +ms: U32) -> IO(Socket & Result<&1, &1, U32 & String, Unit>):
  import "./effs/net_send_timeout.c"
  import "./effs/net_send_timeout.js"

def Net.peer_ip(sock: Socket) -> IO(Socket & String):
  import "./effs/net_peer_ip.c"
  import "./effs/net_peer_ip.js"

def File.sync(file: File) -> IO(File & Result<&1, &1, U32 & String, Unit>):
  import "./effs/file_sync.c"
  import "./effs/file_sync.js"

# --- Segmented-WAL filesystem effects (Round 3 item 14) ---
#
# Base 2.0.18 has no directory creation, enumeration, rename, or delete
# primitives, so the segmented WAL layout (wal/active/seg-NNNNNN.wal plus
# wal/archive/YYYY/MM/seg-NNNNNN.wal) needs these thin native bindings.
# Each returns a U32 status code (1 = success) rather than a Bool, because
# Bool constructor CIDs are awkward to construct from C. The .js files are
# best-effort stubs — the campaign builds and tests native only.

def FS.mkdir_p(path: String) -> IO(U32):
  import "./effs/walfs_mkdir.c"
  import "./effs/walfs_mkdir.js"

def FS.list_dir(path: String) -> IO(String):
  import "./effs/walfs_listdir.c"
  import "./effs/walfs_listdir.js"

def FS.rename_seg(src: String, dst: String) -> IO(U32):
  import "./effs/walfs_rename.c"
  import "./effs/walfs_rename.js"

def FS.unlink(path: String) -> IO(U32):
  import "./effs/walfs_unlink.c"
  import "./effs/walfs_unlink.js"

def FS.file_size(path: String) -> IO(U32):
  import "./effs/walfs_size.c"
  import "./effs/walfs_size.js"

def FS.file_mtime(path: String) -> IO(U32):
  import "./effs/walfs_mtime.c"
  import "./effs/walfs_mtime.js"

def FS.sync_dir(path: String) -> IO(U32):
  import "./effs/walfs_syncdir.c"
  import "./effs/walfs_syncdir.js"

def FS.now_sec() -> IO(U32):
  import "./effs/walfs_now.c"
  import "./effs/walfs_now.js"

# FS.hmac_sha256_hex — HMAC-SHA256(key, msg), lowercase hex (64 chars).
# Round 3 item 197 (T7 residual): the snapshot trailer MAC. The C backend
# (snap_hmac.c) is a self-contained FIPS 180-4 + RFC 2104 implementation;
# the .js is a pure-JS equivalent. Pure-Bend HMAC measured ~2 KiB/s native
# — infeasible for boot-time verification of multi-MiB snapshots.
def FS.hmac_sha256_hex(key: String, msg: String) -> IO(String):
  import "./effs/snap_hmac.c"
  import "./effs/snap_hmac.js"

# Bound applied to every response write (10s).
def write_deadline_ms() -> U32:
  10000

# --- HTTP keep-alive (Round 3 item 183) ---
# Ka carries the handler's keep-alive decision to the owner and writer.
# want: RFC 9112 version/header defaults (ka_want_ver, med_parse.bend) AND
#   the request count n+1 is under ka_max_reqs() AND no pipelined bytes
#   were observed. `Connection: close` always wins; an explicit
#   `Connection: keep-alive` opts in on any version; otherwise HTTP/1.1
#   defaults to keep-alive while HTTP/1.0 (and others) default to close.
#   (Corrected 2026-09-28, item 187: the old text claimed "explicit opt-in
#   only" with no 1.1 default — that predated the item-183 implementation.)
# backch: one-shot channel for the writer to return the socket (keep-alive
#   agreed and write succeeded) or signal closure (channel closed, no socket).
# The writer rewrites the Connection header via the keep param threaded
# through the response builders (med_parse.bend) — no string surgery.
type Ka is Data:
  Ka{want: Bool, backch: Chan(Socket)}

# Max sequential requests per keep-alive connection. Bounds the time a
# single connection can hold its token (256-slot pool) and forces periodic
# re-handshake. 100 is generous for API clients, tight enough to recycle.
def ka_max_reqs() -> Nat:
  100n

def ka_want(+ka: Ka) -> Bool:
  match ka:
    case Ka{want, backch}: want

# Writer completion for keep-alive: on success + want, return the socket to
# the handler via backch for the next request; otherwise close the socket
# and close backch so the handler's recv gets None and exits. The handler
# parks on backch only after donech, so exactly one recv is always waiting —
# the send never parks and the close is always observed.
def writer_ka_back(want: Bool, s2: Socket, +backch: Chan(Socket)) -> IO(Unit):
  match want:
    case True{}:
      do IO<Unit>:
        _ok : Bool <- Chan.send(Socket, backch, s2)
        IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        _c : Unit <- Socket.close(s2)
        _cl : Unit <- Chan.close(Socket, backch)
        IO.pure(Unit, Unit{})

def writer_ka_res(res: Result<&1, &1, U32 & String, Unit>, want: Bool, s2: Socket, +backch: Chan(Socket)) -> IO(Unit):
  match res:
    case Done{_u}: writer_ka_back(want, s2, backch)
    case Fail{_e}: writer_ka_back(False{}, s2, backch)

def writer_ka_done(sr: Socket & Result<&1, &1, U32 & String, Unit>, +ka: Ka) -> IO(Unit):
  (s2, res) = sr
  match ka:
    case Ka{want, backch}: writer_ka_res(res, want, s2, backch)

def writer_task_ka(sock: Socket, +text: String, +ka: Ka) -> IO(Unit):
  do IO<Unit>:
    sr : Socket & Result<&1, &1, U32 & String, Unit> <- Net.send_timeout(sock, text, write_deadline_ms())
    writer_ka_done(sr, ka)

# --- writer tasks (Round 2 item 2) ---
# Response writes run in forked writer tasks, NEVER in the serialized owner.
# A stalled (zero-window) peer parks only its own writer task; the owner
# keeps serving other requests. Every write carries the bounded deadline
# above; past it the socket is closed and the task ends. One task writes
# exactly one response to exactly one socket, so concurrent writers can
# never interleave bytes on a single connection.

def writer_done(sr: Socket & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (s2, res) = sr
  do IO<Unit>:
    _u : Unit <- Socket.close(s2)
    IO.pure(Unit, Unit{})

def writer_task(sock: Socket, +text: String) -> IO(Unit):
  do IO<Unit>:
    sr : Socket & Result<&1, &1, U32 & String, Unit> <- Net.send_timeout(sock, text, write_deadline_ms())
    writer_done(sr)

# Parked subscriptions (long-poll, item 183 deadlock fix): the owner holds
# the socket beyond the request lifetime, so the handler must NOT wait on
# backch. Close it — the handler's recv gets None, it exits and returns its
# connection token. The parked socket is then owner-owned; the wake path
# (wake_one_go) answers it with the plain non-ka writer, which closes it.
# This restores the pre-keep-alive token semantics for parked subs.
def ka_park_close(+ka: Ka) -> IO(Unit):
  match ka:
    case Ka{want, backch}:
      do IO<Unit>:
        _c : Unit <- Chan.close(Socket, backch)
        IO.pure(Unit, Unit{})
