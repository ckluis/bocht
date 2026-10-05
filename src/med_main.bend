# med_main.bend — fresh Medium service, part 9: serialized owner + concurrent accept.
# Architecture (from framework srv_conc.bend):
#   accept loop --(token from 256-slot pool)--> TCP.accept --> IO.spawn per
#   connection --> conn_handler_wrapped (returns token on completion)
#   conn_handler_wrapped (forked): conn_loop with fuel=100; each iteration
#     calls conn_handler_n (one-shot: recv_head via TCP.poll (10s idle
#     deadline) --> parse head + enforce limits --> recv_body --> package
#     MedReq --> owner via Chan(MedMsg) --> writer returns socket via
#     backch for keep-alive). Returns token to semch on completion.
#     --> parse head + enforce limits (414/431/400/411/413/408 answered HERE,
#     no owner involvement) --> recv_body via TCP.poll (10s idle deadline)
#     --> package MedReq{method, path, query, body, sockch} --> owner via
#     Chan(MedMsg) (503 + close if the owner channel is shut).
#   owner_loop (ONE serialized state owner) receives MedMsg, gets Socket
#     from sockch, routes request, hands the response bytes to a forked
#     writer task (writer_task: Net.send_timeout with a bounded 10s write
#     deadline, then closes the socket). The owner NEVER blocks on a socket
#     write — a stalled (zero-window) peer parks only its own writer task.
#     Handler-side error answers (414/431/400/411/413/408) also go through
#     writer tasks, so a stalled peer can't pin a handler and its token.
# The owner is the only task that mutates MedState. Connections are I/O only.
# At the connection cap, the accept loop parks on the token channel and the
# kernel listen backlog absorbs pressure until a slot frees.
#
# Why MedReq carries a Chan(Socket): Socket is a law Type, not Data, so it
# cannot be a Data constructor field. A Chan IS Data, so each handler mints a
# one-shot Chan(Socket, room=1), drops the socket into it, and sends the whole
# request — socket included — as ONE atomic message.
#
# Why MedReq carries a donech: the handler task parks on donech until the
# owner finishes processing its request (Round 2 item 3). The connection
# token is therefore held from accept until the owner's work is DONE, so the
# number of outstanding (queued or processing) requests can never exceed the
# 256 tokens — and the 256-room owner mailbox can never fill. Chan.send to
# the owner thus never parks on a full channel; the handler's only wait is
# for its OWN message to be processed (bounded by single-message owner
# time), never for 256 strangers ahead of it. This is end-to-end
# backpressure: when the owner falls behind, connection slots (not just
# mailbox room) absorb it, and the accept loop stalls instead of queueing
# unboundedly.

type MedReq is Data:
  MkReq{method: String, path: String, query: String, headers: Map<&2, String>, body: String, sockch: Chan(Socket), donech: Chan(Unit), ka: Ka}

type MedMsg is Data:
  ReqMsg{req: MedReq}
  TickMsg{}

# --- path/query split (router matches path_segs(path), query is separate) ---

def ch_qm() -> Char:
  Char.from_u32(63)

def spq_go(+parts: List<&2, String>) -> String & String:
  match parts:
    case Nil{}: ("", "")
    case h <> t: (h, join_str(t, "?"))

def split_path_query(+path: String) -> String & String:
  spq_go(split_char(path, ch_qm()))

# --- handler-side error answers (no owner involvement) ---

# Handler-side error answers also go through writer tasks (Round 2 item 2):
# the handler returns immediately and frees its connection token; the writer
# owns the bounded write and closes the socket. A stalled peer can no longer
# pin a handler (and its token) on a blocking send.

def conn_send_err(sock: Socket, +code: U32, +msg: String, +hint: String) -> IO(Unit):
  do IO<Unit>:
    _u : Unit <- IO.spawn(Unit, writer_task(sock, http_err(code, msg, hint, False{})))
    IO.pure(Unit, Unit{})

# Item 104: method-aware error send — HEAD responses carry headers only
# (RFC 9110 S9.3.2: a server MUST NOT send a message body on HEAD).
def conn_send_err_m(sock: Socket, +method: String, +code: U32, +msg: String, +hint: String) -> IO(Unit):
  do IO<Unit>:
    _u : Unit <- IO.spawn(Unit, writer_task(sock, Bool.pick(String, String.eq(method, "HEAD"), http_err_head(code, msg, hint, False{}), http_err(code, msg, hint, False{}))))
    IO.pure(Unit, Unit{})

def conn_hg_err_msg(+code: U32) -> String:
  Bool.pick(String, U32.is_eq(code, 431), "header_fields_too_large",
  Bool.pick(String, U32.is_eq(code, 408), "request_timeout", "bad_request"))

def conn_hg_err_hint(+code: U32) -> String:
  Bool.pick(String, U32.is_eq(code, 431), "Request head exceeds the 8192 byte limit. See GET /help for the API.",
  Bool.pick(String, U32.is_eq(code, 408), "Client was idle too long while sending the request head (10s limit). See GET /help for the API.",
    "Could not read the request head. See GET /help for the API."))

# --- handler-side request assembly ---

# Chan.send only returns False when the channel is shut (a full channel parks
# the sender instead — but see donech below: the owner mailbox cannot fill).
# If the owner channel is shut, answer 503 and close; never silently drop a
# request the client is waiting on.
# After handing the socket to the owner, the handler parks on donech until
# the owner finishes routing its request. This keeps the connection token
# checked out for the full request lifetime, bounding outstanding requests
# by the 256 token supply (item 3).
#
# Round 3 item 183 (HTTP keep-alive): after donech, the handler recvs the
# socket back from the writer via ka.backch. Some{sock} means keep-alive was
# agreed and the write succeeded — loop for the next request. None{} means
# the writer closed (or failed) — exit and return the token via the wrapper.

def conn_ka_recv(+ka: Ka) -> IO(Maybe<&1, Socket>):
  match ka:
    case Ka{want, backch}:
      do IO<Maybe<Socket>>:
        ms : Maybe<&1, Socket> <- Chan.recv(Socket, backch)
        IO.pure(Maybe<Socket>, ms)

# Round 3 item 183: keep-alive decision. want is true only if ALL hold:
#   - HTTP version + Connection header want keep-alive (ka_want_ver:
#     HTTP/1.1 defaults to keep-alive unless `Connection: close`;
#     HTTP/1.0 defaults to close unless `Connection: keep-alive`)
#   - request count n+1 is under ka_max_reqs() (the 100th request gets
#     Connection: close; bounds token hold time)
#   - no bytes beyond Content-Length were read (leftover_empty — a
#     non-empty leftover means the client pipelined, which we do not
#     support; force close rather than desync).

def conn_body_sent(sent: Bool, s2: Socket, +sc: Chan(Socket), +donech: Chan(Unit), +ka: Ka, +reqch: Chan(MedMsg), +n: Nat) -> IO(Maybe<Socket>):
  match sent:
    case True{}:
      do IO<Maybe<Socket>>:
        _ok : Bool <- Chan.send(Socket, sc, s2)
        _d : Maybe<&1, Unit> <- Chan.recv(Unit, donech)
        ms : Maybe<&1, Socket> <- conn_ka_recv(ka)
        IO.pure(Maybe<Socket>, ms)
    case False{}:
      do IO<Maybe<Socket>>:
        _u : Unit <- conn_send_err(s2, 503, "service_unavailable", "Server is overloaded or shutting down. Retry later. See GET /help for the API.")
        IO.pure(Maybe<Socket>, None{})

def conn_ka_want(+headers: Map<&2, String>, +ver: String, n: Nat, leftover_empty: Bool) -> Bool:
  Bool.and(ka_want_ver(ver, headers), Bool.and(Nat.is_lt(Nat.add(n, 1n), ka_max_reqs()), leftover_empty))

def conn_body_send(s2: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +reqch: Chan(MedMsg), +n: Nat, leftover_empty: Bool, +ver: String) -> IO(Maybe<Socket>):
  do IO<Maybe<Socket>>:
    +sc : Chan(Socket) <- Chan.new(Socket, 1)
    +donech : Chan(Unit) <- Chan.new(Unit, 1)
    +backch : Chan(Socket) <- Chan.new(Socket, 1)
    +ka : Ka = Ka{conn_ka_want(headers, ver, n, leftover_empty), backch}
    sent : Bool <- Chan.send(MedMsg, reqch, ReqMsg{MkReq{method, path, query, headers, body, sc, donech, ka}})
    conn_body_sent(sent, s2, sc, donech, ka, reqch, n)


def conn_body_trunc(short: Bool, s2: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +raw_body: String, +cl: Nat, +reqch: Chan(MedMsg), +n: Nat, +ver: String) -> IO(Maybe<Socket>):
  match short:
    case True{}: IO.bind(Unit, Maybe<Socket>, conn_send_err_m(s2, method, 400, "bad_request", "Request body ended before Content-Length bytes arrived. See GET /help for the API."), _u => IO.pure(Maybe<Socket>, None{}))
    # leftover_empty: raw_body longer than cl means the client sent bytes
    # beyond the framed request (pipelining) — force close (item 183).
    case False{}: conn_body_send(s2, method, path, query, headers, str_take_bytes(raw_body, cl), reqch, n, Nat.is_eq(utf8_byte_len(raw_body), cl), ver)


def conn_body_done(sbr: Socket & String, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +cl: Nat, +reqch: Chan(MedMsg), +n: Nat, +ver: String) -> IO(Maybe<Socket>):
  (s2, +raw_body) = sbr
  conn_body_trunc(Nat.is_lt(utf8_byte_len(raw_body), cl), s2, method, path, query, headers, raw_body, cl, reqch, n, ver)

def owner_req(+method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  route(method, path, query, headers, body, sock, st, ka)

# --- per-IP rate limiting (Round 2 item 4) ---
# Base's TCP.accept discards the peer address, so the owner recovers it here
# via the Net.peer_ip native effect (the socket reaches the owner through
# sockch before routing). Three fixed-window buckets live in the owner's rl
# map (Round 2 item 9 added the third and pruning):
#   "ip:"  ++ ip : 2000 requests / 60s per IP, every endpoint
#   "ipd:" ++ ip : 30 requests / 60s per IP, discovery endpoints (/help, /schema)
#   "kb:"  ++ bearer-token : 1000 requests / 60s per credential, every
#     request carrying an Authorization bearer token (survives source-IP
#     rotation, which defeats per-IP limiting)
# Over-limit requests get 429 "too_many_requests" through the normal writer
# path and are never routed. Entries for clients that never return are
# swept by rl_maybe_prune once the map exceeds 4000 entries, bounding
# memory to O(clients active within the window).

# NOTE (Round 3 item 172): iprl_window_ms moved to med_store.bend -- the
# snapshot RL section builder needs the window, and med_store precedes
# med_main in assembly. Single source of truth; this comment stays with the
# rate-limit documentation.

def iprl_global_limit() -> Nat:
  Nat.mul(20n, 100n)

def iprl_discovery_limit() -> Nat:
  30n

# NOTE (Round 3 item 22): iprl_is_discovery moved to just after canon_path —
# it must classify on the segment-normalized path (defs precede use in Bend).
# The classifier used to live here with raw-string equality.

def owner_iprl_deny(sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  send_err_ka(sock, st, ka, 429, "too_many_requests")

# --- per-credential rate limiting (Round 2 item 9) ---
# Per-IP limiting is bypassed by rotating source IPs; the bearer credential
# is the stable client identity. Every request carrying an Authorization
# bearer token is also counted in a "kb:<token>" bucket (1000 req/60s) in
# the owner path, before routing — keyed on the presented token so it works
# before auth resolution. (The old per-key claim was never wired into the
# fresh service; this is the real thing.) Unauthenticated requests skip it.
def keyrl_limit() -> Nat:
  Nat.mul(10n, 100n)

def owner_keyrl_deny(sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  send_err_ka(sock, st, ka, 429, "too_many_requests")

# --- per-tenant rate limiting (Round 3 item 17) ---
# Per-credential limiting is bypassed by minting keys: each new key gets its
# own 1000 req/60s bucket, so a tenant's aggregate throughput is unbounded in
# key count. The tenant is the stable billing identity. Every request whose
# Bearer <redacted> resolves to a valid Auth is also counted in a "kt:<tenant>"
# bucket (1500 req/60s) in the owner path, after the kb check and before
# routing. Applies to ALL routes carrying a valid token (same coverage as kb;
# no route carve-outs). Bogus/revoked/expired tokens skip it (they already
# counted against kb and will 401 at auth). Unauthenticated requests skip it.
# Memory: one rl entry per active tenant; the existing rl_maybe_prune sweep
# (4000-entry threshold, 60s time gate) covers kt entries with the same window.
def keyrl_tenant_limit() -> Nat:
  Nat.mul(15n, 100n)

def owner_tenant_deny(sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  send_err_ka(sock, st, ka, 429, "too_many_requests")

def owner_tenant_of_auth(+a: Auth) -> String:
  match a:
    case MkAuth{kid, k, t, r, e, rv}: t

def owner_tenant_of(m: Maybe<&1, Auth>) -> Maybe<&1, String>:
  match m:
    case None{}: None{}
    case Some{a}: Some{owner_tenant_of_auth(a)}

def owner_tenant_got(res: Map<&2, String> & Bool, sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +st: MedState, +ka: Ka) -> IO(MedState):
  (rl2, ok) = res
  match ok:
    case True{}: owner_req(method, path, query, headers, body, sock, st_with_rl(st, rl2), ka)
    case False{}: owner_tenant_deny(sock, st_with_rl(st, rl2), ka)

def owner_tenant_check(mt: Maybe<&1, String>, sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  match mt:
    case None{}: owner_req(method, path, query, headers, body, sock, st, ka)
    case Some{ten}: owner_tenant_got(check_rl(st_rl(st), "kt:" ++ ten, now, keyrl_tenant_limit(), iprl_window_ms()), sock, method, path, query, headers, body, st, ka)

def owner_tenant_go(+st: MedState, +ka: Ka, sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat) -> IO(MedState):
  owner_tenant_check(owner_tenant_of(auth_token_valid(bearer_key(find_header(headers, "authorization")), st_keys(st), now)), sock, method, path, query, headers, body, now, st, ka)

# --- sensitive-action route classification (Round 3 items 20-21) ---
# Classifiers operate on path_segs(path) — the same normalization the router
# uses (path_segs drops empty segments, so a bare trailing slash normalizes).
# Item 20 shipped raw-string exact equality for the restart route, which a
# trailing slash bypassed (POST /v1/admin/restart/ routed to the handler
# while kr: never fired — verified live on r15). Classifying on segments
# makes the classifier and the router agree on every request. These are pure
# Bool defs; is_rr/is_km are computed at the call site and passed as params
# (Bend forbids matching computed values). The kr: and ks: buckets are per
# presented bearer token, consistent with kb: — bogus tokens are counted
# too, so credential-spraying a sensitive endpoint burns the attacker’s own
# buckets before the 401.
def canon_path(+path: String) -> String:
  "/" ++ join_with(path_segs(path), "/")

# Discovery classifier (Round 3 item 22 fix). This used raw-string equality
# (String.eq(path, "/help")) while the router dispatches on path_segs(path),
# which drops empty segments — so /help/, //help, /schema/ etc. routed to the
# handler but were counted in the 2000/60s ip: bucket instead of the 30/60s
# ipd: discovery bucket (verified live on r16: 35x GET /help/ -> 0x429 while
# 31x GET /help -> 429 on the 31st). Same bug class item 20 fixed for the
# restart route. Classifying on canon_path makes the classifier and the
# router agree on every request spelling.
def iprl_is_discovery(+path: String) -> Bool:
  Bool.or(String.eq(canon_path(path), "/help"),
    String.eq(canon_path(path), "/schema"))

def is_restart_route(+method: String, +path: String) -> Bool:
  Bool.and(String.eq(method, "POST"),
    String.eq(canon_path(path), "/v1/admin/restart"))

# Key-plane mutating routes: POST /v1/keys (create),
# POST /v1/keys/:kid/rotate, POST /v1/keys/:kid/revoke. :kid is arbitrary,
# so the classifier matches on segment structure. Defined leaf-first so
# every def precedes its use (single-direction call chain, no mutual
# recursion); computed Bools travel as params.
def sens_keys_act2(is_rot: Bool, is_rev: Bool, +rest3: List<&2, String>) -> Bool:
  match rest3:
    case Nil{}: Bool.or(is_rot, is_rev)
    case _ <> _: False{}

def sens_keys_act(+acts: List<&2, String>) -> Bool:
  match acts:
    case a <> rest3: sens_keys_act2(String.eq(a, "rotate"), String.eq(a, "revoke"), rest3)
    case Nil{}: False{}

def sens_keys_tail(+tail: List<&2, String>) -> Bool:
  match tail:
    case Nil{}: True{}
    case _ <> acts: sens_keys_act(acts)

def sens_keys_k2(is_keys: Bool, +rest2: List<&2, String>) -> Bool:
  match is_keys:
    case True{}: sens_keys_tail(rest2)
    case False{}: False{}

def sens_keys_k(+rest: List<&2, String>) -> Bool:
  match rest:
    case k <> rest2: sens_keys_k2(String.eq(k, "keys"), rest2)
    case Nil{}: False{}

def sens_keys_v1(is_v1: Bool, +rest: List<&2, String>) -> Bool:
  match is_v1:
    case True{}: sens_keys_k(rest)
    case False{}: False{}

def sens_keys_segs(+segs: List<&2, String>) -> Bool:
  match segs:
    case v <> r1: sens_keys_v1(String.eq(v, "v1"), r1)
    case Nil{}: False{}

def is_keymut_route(+method: String, +path: String) -> Bool:
  Bool.and(String.eq(method, "POST"), sens_keys_segs(path_segs(path)))

def owner_restart_rl_deny(sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  send_err_ka(sock, st, ka, 429, "too_many_requests")

def owner_keymut_rl_deny(sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  send_err_ka(sock, st, ka, 429, "too_many_requests")

# --- key-management rate-limit enforcement (Round 3 item 21) ---
# The admin-only mutating key-plane routes are destructive control-plane
# actions like the restart route: a leaked, phished, or buggy admin
# credential could revoke every key in the tenant at the generic 1000
# req/60s bucket (availability DoS, persisted via WAL), mint keys at that
# rate (state-fill DoS against local disk), or churn every credential via
# rotate. A dedicated tight bucket "ks:<token>" (MEDIUM_KEY_RL requests per
# 60s per credential, default 5) is checked after the kr: step and before
# the tenant step. Over-limit attempts get 429 and are never routed.
def owner_keymut_rl_got(res: Map<&2, String> & Bool, sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  (rl2, ok) = res
  match ok:
    case True{}: owner_tenant_go(st_with_rl(st, rl2), ka, sock, method, path, query, headers, body, now)
    case False{}: owner_keymut_rl_deny(sock, st_with_rl(st, rl2), ka)

def owner_keymut_rl_tok(mtok: Maybe<&1, String>, +st: MedState, +ka: Ka, sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat) -> IO(MedState):
  match mtok:
    case None{}: owner_tenant_go(st, ka, sock, method, path, query, headers, body, now)
    case Some{tok}: owner_keymut_rl_got(check_rl(st_rl(st), "ks:" ++ tok, now, st_krl(st), iprl_window_ms()), sock, method, path, query, headers, body, now, st, ka)

def owner_keymut_rl_decide(is_km: Bool, +st: MedState, +ka: Ka, sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat) -> IO(MedState):
  match is_km:
    case True{}: owner_keymut_rl_tok(bearer_key(find_header(headers, "authorization")), st, ka, sock, method, path, query, headers, body, now)
    case False{}: owner_tenant_go(st, ka, sock, method, path, query, headers, body, now)

def owner_restart_rl_got(res: Map<&2, String> & Bool, is_km: Bool, sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  (rl2, ok) = res
  match ok:
    case True{}: owner_keymut_rl_decide(is_km, st_with_rl(st, rl2), ka, sock, method, path, query, headers, body, now)
    case False{}: owner_restart_rl_deny(sock, st_with_rl(st, rl2), ka)

def owner_restart_rl_tok(mtok: Maybe<&1, String>, is_km: Bool, +st: MedState, +ka: Ka, sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat) -> IO(MedState):
  match mtok:
    case None{}: owner_keymut_rl_decide(is_km, st, ka, sock, method, path, query, headers, body, now)
    case Some{tok}: owner_restart_rl_got(check_rl(st_rl(st), "kr:" ++ tok, now, st_rrl(st), iprl_window_ms()), is_km, sock, method, path, query, headers, body, now, st, ka)

def owner_restart_rl_decide(is_rr: Bool, is_km: Bool, +st: MedState, +ka: Ka, sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat) -> IO(MedState):
  match is_rr:
    case True{}: owner_restart_rl_tok(bearer_key(find_header(headers, "authorization")), is_km, st, ka, sock, method, path, query, headers, body, now)
    case False{}: owner_keymut_rl_decide(is_km, st, ka, sock, method, path, query, headers, body, now)

def owner_keyrl_got(res: Map<&2, String> & Bool, is_rr: Bool, is_km: Bool, sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  (rl2, ok) = res
  match ok:
    case True{}: owner_restart_rl_decide(is_rr, is_km, st_with_rl(st, rl2), ka, sock, method, path, query, headers, body, now)
    case False{}: owner_keyrl_deny(sock, st_with_rl(st, rl2), ka)

def owner_keyrl_check(mtok: Maybe<&1, String>, sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  match mtok:
    case None{}: owner_req(method, path, query, headers, body, sock, st, ka)
    case Some{tok}: owner_keyrl_got(check_rl(st_rl(st), "kb:" ++ tok, now, keyrl_limit(), iprl_window_ms()), is_restart_route(method, path), is_keymut_route(method, path), sock, method, path, query, headers, body, now, st, ka)

def owner_keyrl(sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  owner_keyrl_check(bearer_key(find_header(headers, "authorization")), sock, method, path, query, headers, body, now, st, ka)

def owner_iprl_disc_decide(ok: Bool, sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: owner_keyrl(sock, method, path, query, headers, body, now, st, ka)
    case False{}: owner_iprl_deny(sock, st, ka)

def owner_iprl_disc_got(res: Map<&2, String> & Bool, sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  (rl2, ok) = res
  owner_iprl_disc_decide(ok, sock, method, path, query, headers, body, now, st_with_rl(st, rl2), ka)

def owner_iprl_disc_go(sock: Socket, +ip: String, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  owner_iprl_disc_got(check_rl(st_rl(st), "ipd:" ++ ip, now, iprl_discovery_limit(), iprl_window_ms()), sock, method, path, query, headers, body, now, st, ka)

def owner_iprl_disc_auth(mtok: Maybe<&1, String>, sock: Socket, +ip: String, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  # Round 3 item 175: NAT fairness. The ipd: bucket (30/60s per source IP) is
  # shared by all clients behind a NAT egress -- one client's burn locks out
  # every other client's discovery access, including clients presenting valid
  # Bearer credentials. A presented credential gets its own kb: bucket
  # (1000/60s per credential, enforced by owner_keyrl), which is the correct
  # limiter for identified clients. So: credentialed discovery skips ipd:;
  # only anonymous discovery counts against the shared per-IP bucket.
  match mtok:
    case None{}: owner_iprl_disc_go(sock, ip, method, path, query, headers, body, now, st, ka)
    case Some{tok}: owner_keyrl(sock, method, path, query, headers, body, now, st, ka)

def owner_iprl_disc(is_disc: Bool, sock: Socket, +ip: String, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  match is_disc:
    case True{}: owner_iprl_disc_auth(bearer_key(find_header(headers, "authorization")), sock, ip, method, path, query, headers, body, now, st, ka)
    case False{}: owner_keyrl(sock, method, path, query, headers, body, now, st, ka)

def owner_iprl_decide(ok: Bool, sock: Socket, +ip: String, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: owner_iprl_disc(iprl_is_discovery(path), sock, ip, method, path, query, headers, body, now, st, ka)
    case False{}: owner_iprl_deny(sock, st, ka)

def owner_iprl_prune_applied(pr: Map<&2, String> & Nat & Nat, ok: Bool, sock: Socket, +ip: String, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  (rl3, rest) = pr
  (pruned_at, cur2) = rest
  owner_iprl_decide(ok, sock, ip, method, path, query, headers, body, now, st_with_rlcur(st_with_rlprune(st_with_rl(st, rl3), pruned_at), cur2), ka)

def owner_iprl_got(res: Map<&2, String> & Bool, sock: Socket, +ip: String, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  (rl2, ok) = res
  owner_iprl_prune_applied(rl_maybe_prune(rl2, now, iprl_window_ms(), st_rlprune(st), st_rlcur(st)), ok, sock, ip, method, path, query, headers, body, now, st, ka)

def owner_peer_go(sr: Socket & String, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +now: Nat, +st: MedState, +ka: Ka) -> IO(MedState):
  (sock, +ip) = sr
  owner_iprl_got(check_rl(st_rl(st), "ip:" ++ ip, now, iprl_global_limit(), iprl_window_ms()), sock, ip, method, path, query, headers, body, now, st, ka)

def owner_peer(sock: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +st: MedState, +ka: Ka) -> IO(MedState):
  do IO<MedState>:
    now : Nat <- IO.now()
    sr : Socket & String <- Net.peer_ip(sock)
    owner_peer_go(sr, method, path, query, headers, body, now, st, ka)


def owner_sock(ms: Maybe<&1, Socket>, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +st: MedState, +ka: Ka) -> IO(MedState):
  match ms:
    case None{}: IO.pure(MedState, st)
    case Some{sock}: owner_peer(sock, method, path, query, headers, body, st, ka)

def owner_ch_done(+donech: Chan(Unit), +st: MedState) -> IO(MedState):
  do IO<MedState>:
    _b : Bool <- Chan.send(Unit, donech, Unit{})
    IO.pure(MedState, st)

def owner_ch(+sockch: Chan(Socket), +donech: Chan(Unit), +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, +st: MedState, +ka: Ka) -> IO(MedState):
  do IO<MedState>:
    ms : Maybe<&1, Socket> <- Chan.recv(Socket, sockch)
    st2 : MedState <- owner_sock(ms, method, path, query, headers, body, st, ka)
    owner_ch_done(donech, st2)

def owner_apply(+req: MedReq, +st: MedState) -> IO(MedState):
  match req:
    case MkReq{method, path, query, headers, body, sockch, donech, ka}: owner_ch(sockch, donech, method, path, query, headers, body, st, ka)

def owner_proc(+msg: MedMsg, +st: MedState) -> IO(MedState):
  match msg:
    case ReqMsg{req}:
      do IO<MedState>:
        st2 : MedState <- owner_apply(req, st)
        maybe_snapshot(st2)
    case TickMsg{}: IO.pure(MedState, st)

# --- graceful restart machinery (Round 3 item 19) ---
#
# The Bend 2.0.18 native runtime retains ~0.95KB/request; no user-space fix
# can reclaim it. The answer is service-managed graceful restart:
#
#   * request budget (MEDIUM_REQ_BUDGET, default 200000, clamped 100..1e8)
#     or an authenticated admin POST /v1/admin/restart sets st.restart
#   * the owner closes a shared stop channel and loopback-wakes the accept
#     task, which stops accepting and closes the request channel
#   * the owner drains queued requests, runs a final unconditional snapshot
#     (WAL commits are already fsync-per-commit), and the process exits 0
#   * an external supervisor restarts the binary; WAL replay + snapshot make
#     the restart fast and lossless (item 15 bar: 10000 articles ~1506ms)
#
# There is no in-process re-exec in Base: the honest boundary is
# self-initiated graceful EXIT plus supervisor relaunch.

def default_budget() -> Nat:
  Nat.mul(20n, Nat.mul(100n, 100n))

def budget_min() -> Nat: 100n

def budget_max() -> Nat:
  Nat.mul(Nat.mul(100n, 100n), Nat.mul(100n, 100n))

def budget_bound(+n: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(budget_max(), n), budget_max(),
    Bool.pick(Nat, Nat.is_lt(n, budget_min()), budget_min(), n))

def budget_of_env(mn: Maybe<&1, Nat>) -> Nat:
  match mn:
    case None{}: default_budget()
    case Some{n}: budget_bound(n)

def budget_of(mr: Result<&1, &1, U32 & String, String>) -> Nat:
  match mr:
    case Fail{_e}: default_budget()
    case Done{s}: budget_of_env(parse_nat_opt(s))

def read_request_budget() -> IO(Nat):
  do IO<Nat>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_REQ_BUDGET")
    IO.pure(Nat, budget_of(mr))

# --- restart rate limit (Round 3 item 20) ---
# POST /v1/admin/restart is a destructive control-plane action: each accepted
# request tears the whole service down. The generic per-credential bucket
# (1000 req/60s) is far too generous for it — a leaked, phished, or buggy
# admin client could hold the service in a permanent restart loop (every
# shutdown is followed by a supervisor relaunch that resets in-memory
# state, so the loop never self-terminates). A dedicated tight bucket
# "kr:<token>" (MEDIUM_RESTART_RL requests per 60s per credential,
# default 5) is checked in the owner chain after the kb check and before
# routing. Over-limit attempts get 429 and are never routed, so no
# shutdown is scheduled.
def restart_rl_min() -> Nat: 1n

def restart_rl_max() -> Nat:
  Nat.mul(10n, 100n)

def restart_rl_bound(+n: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(restart_rl_max(), n), restart_rl_max(),
    Bool.pick(Nat, Nat.is_lt(n, restart_rl_min()), restart_rl_min(), n))

def restart_rl_of_env(mn: Maybe<&1, Nat>) -> Nat:
  match mn:
    case None{}: default_restart_rl()
    case Some{n}: restart_rl_bound(n)

def restart_rl_of(mr: Result<&1, &1, U32 & String, String>) -> Nat:
  match mr:
    case Fail{_e}: default_restart_rl()
    case Done{s}: restart_rl_of_env(parse_nat_opt(s))

def read_restart_rl() -> IO(Nat):
  do IO<Nat>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_RESTART_RL")
    IO.pure(Nat, restart_rl_of(mr))

# --- key-management rate limit (Round 3 item 21) ---
def key_rl_min() -> Nat: 1n

def key_rl_max() -> Nat:
  Nat.mul(10n, 100n)

def key_rl_bound(+n: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(key_rl_max(), n), key_rl_max(),
    Bool.pick(Nat, Nat.is_lt(n, key_rl_min()), key_rl_min(), n))

def key_rl_of_env(mn: Maybe<&1, Nat>) -> Nat:
  match mn:
    case None{}: default_key_rl()
    case Some{n}: key_rl_bound(n)

def key_rl_of(mr: Result<&1, &1, U32 & String, String>) -> Nat:
  match mr:
    case Fail{_e}: default_key_rl()
    case Done{s}: key_rl_of_env(parse_nat_opt(s))

def read_key_rl() -> IO(Nat):
  do IO<Nat>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_KEY_RL")
    IO.pure(Nat, key_rl_of(mr))

# Loopback self-wake: connect+close so a TCP.accept parked in the accept
# task returns. Never sends a request; the spawned handler sees EOF and ends.
def shutdown_wake_got(cr: Result<&1, &1, U32 & String, Socket>) -> IO(Unit):
  match cr:
    case Fail{_e}: IO.print("medium-fresh: shutdown self-wake connect failed (accept task may already be down)\n")
    case Done{sock}:
      do IO<Unit>:
        _c : Unit <- Socket.close(sock)
        IO.pure(Unit, Unit{})

def shutdown_wake() -> IO(Unit):
  do IO<Unit>:
    cr : Result<&1, &1, U32 & String, Socket> <- TCP.connect("127.0.0.1", 18081)
    shutdown_wake_got(cr)

def drain_fuel() -> Nat:
  Nat.mul(1000n, 100n)

# Drain queued requests after reqch is closed (None = closed+empty).
def owner_drain(rem: Nat, mr: Maybe<&1, MedMsg>, +reqch: Chan(MedMsg), +st: MedState) -> IO(MedState):
  match rem:
    case 0n: IO.pure(MedState, st)
    case 1n+r:
      match mr:
        case None{}: IO.pure(MedState, st)
        case Some{msg}:
          do IO<MedState>:
            +st2 : MedState <- owner_proc(msg, st)
            mr2 : Maybe<&1, MedMsg> <- Chan.recv(MedMsg, reqch)
            owner_drain(r, mr2, reqch, st2)

# Final flush: unconditional snapshot cycle, then the task ends and the
# process exits. WAL commits are fsync-per-commit, so this snapshot only
# needs to capture key-compacted state for fast replay.
def owner_finish(+st: MedState) -> IO(MedState):
  do IO<MedState>:
    st2 : MedState <- snap_cycle(st)
    _u : Unit <- IO.print("medium-fresh: graceful shutdown complete, final snapshot saved\n")
    IO.pure(MedState, st2)

# Coordinated shutdown: stop accepting (drain the stop-cycle token, then close
# stopch so the accept loop observes None), wake the accept task, drain queued
# requests, final snapshot, end. Terminal: never returns to owner_loop
# (avoids a mutual-recursion cycle).
# The token drain is essential: if the channel were closed with the cycle
# token still buffered, the accept loop's recv would return Some(token) and
# it would park in TCP.accept with no one left to wake it -> deadlock.
def owner_begin_shutdown(mr: Maybe<&1, MedMsg>, +reqch: Chan(MedMsg), +stopch: Chan(Unit), +st: MedState) -> IO(Unit):
  do IO<Unit>:
    _u1 : Unit <- IO.print("medium-fresh: graceful shutdown initiated, draining in-flight requests\n")
    _t : Maybe<&1, Unit> <- Chan.recv(Unit, stopch)
    _c : Unit <- Chan.close(Unit, stopch)
    # Wake twice: the accept loop spawns a handler for the first wake and
    # then parks in a second TCP.accept; the second wake unparks it so it
    # observes the closed stopch and halts (item 183 deadlock fix).
    _w : Unit <- shutdown_wake()
    _w2 : Unit <- shutdown_wake()
    st2 : MedState <- owner_drain(drain_fuel(), mr, reqch, st)
    _s : MedState <- owner_finish(st2)
    IO.pure(Unit, Unit{})

# Single directly-recursive owner loop. The stop decision is deferred-match
# style: each iteration computes the NEXT stop flag from the post-message
# state (st_restart) and passes it as a param, so every match scrutinizes a
# param or arm-bound value (Bend 2.0.18 forbids matching do-bound values).
# The first iteration carries a dummy TickMsg so the loop recvs first.
# Stop is checked BEFORE the queued message is processed: a shutdown
# decision never abandons a message already handed to the loop.
def owner_loop(rem: Nat, stop: Bool, mr: Maybe<&1, MedMsg>, +reqch: Chan(MedMsg), +stopch: Chan(Unit), +st: MedState) -> IO(Unit):
  match rem:
    case 0n: owner_begin_shutdown(mr, reqch, stopch, st)
    case 1n+r:
      match stop:
        case True{}: owner_begin_shutdown(mr, reqch, stopch, st)
        case False{}:
          match mr:
            case None{}: owner_begin_shutdown(mr, reqch, stopch, st)
            case Some{msg}:
              do IO<Unit>:
                +st2 : MedState <- owner_proc(msg, st)
                mr2 : Maybe<&1, MedMsg> <- Chan.recv(MedMsg, reqch)
                owner_loop(r, st_restart(st2), mr2, reqch, stopch, st2)

def owner_loop_start(budget: Nat, +reqch: Chan(MedMsg), +stopch: Chan(Unit), +st: MedState) -> IO(Unit):
  owner_loop(budget, False{}, Some{TickMsg{}}, reqch, stopch, st)

# --- secure bootstrap ---
# Prefer MEDIUM_ADMIN_SECRET from the environment: it is never printed and
# never written to disk by the service. Without it, a secret is generated and
# printed to stdout ONCE — stdout may be captured by the launcher, so treat
# any printed secret as logged and rotate it via POST /v1/keys/:kid/rotate.

def med_init_printed(+secret: String, +keys: Map<&2, Auth>, +st: MedState) -> IO(MedState):
  do IO<MedState>:
    _u : Unit <- IO.print("medium-fresh: generated bootstrap admin key (printed to stdout; treat as logged — set MEDIUM_ADMIN_SECRET to avoid this):\n" ++ secret ++ "\n")
    IO.pure(MedState, st_with_keys(st, keys))

# Bootstrap key persistence (Round 2 item 9 fix): the bootstrap admin key
# used to live only in memory, so after any restart (once API keys existed)
# the MEDIUM_ADMIN_SECRET credential silently returned 401. It is now
# written to the WAL as a normal KEY record (verifier only, never the raw
# secret) so it replays, rotates, and revokes like any other key.
def med_init_boot_warn(ok: Bool) -> IO(Unit):
  match ok:
    case True{}: IO.pure(Unit, Unit{})
    case False{}: IO.print("medium-fresh: WARNING: bootstrap admin key WAL write failed; it will not survive restart\n")

def med_init_gen(+secret: String, +st: MedState) -> IO(MedState):
  +auth : Auth = mk_managed_auth("k_0", secret, "root", "admin")
  do IO<MedState>:
    ok : Bool <- wal_key(auth)
    _u : Unit <- med_init_boot_warn(ok)
    med_init_printed(secret, Map.set(&2, Auth, st_keys(st), auth_key(auth), auth), st)

def med_init_generated(+st: MedState) -> IO(MedState):
  do IO<MedState>:
    now : Nat <- IO.now()
    hex : String <- keygen_secure()
    med_init_gen(keygen_pick(hex, now, 0n), st)

def med_init_env_ready(+secret: String, +st: MedState) -> IO(MedState):
  +auth : Auth = mk_managed_auth("k_0", secret, "root", "admin")
  do IO<MedState>:
    ok : Bool <- wal_key(auth)
    _u : Unit <- med_init_boot_warn(ok)
    IO.pure(MedState, st_with_keys(st, Map.set(&2, Auth, st_keys(st), auth_key(auth), auth)))

def med_init_env_empty(is_empty: Bool, +secret: String, +st: MedState) -> IO(MedState):
  match is_empty:
    case True{}: med_init_generated(st)
    case False{}:
      do IO<MedState>:
        _u : Unit <- IO.print("medium-fresh: using MEDIUM_ADMIN_SECRET from environment (not displayed)\n")
        med_init_env_ready(secret, st)

def med_init_env_secret(mr: Result<&1, &1, U32 & String, String>, +st: MedState) -> IO(MedState):
  match mr:
    case Fail{e}: med_init_generated(st)
    case Done{+secret}: med_init_env_empty(String.is_empty(secret), secret, st)

def med_init_empty(is_empty: Bool, +st: MedState) -> IO(MedState):
  match is_empty:
    case True{}:
      do IO<MedState>:
        mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_ADMIN_SECRET")
        med_init_env_secret(mr, st)
    case False{}:
      do IO<MedState>:
        _u : Unit <- IO.print("medium-fresh: recovered state from snapshot/WAL (keys present, skipping bootstrap)\n")
        IO.pure(MedState, st)

def med_init_replay(+snap: String, +wal: String) -> IO(MedState):
  +st : MedState = wal_replay(wal, wal_replay(snap, med_empty()))
  +st2 : MedState = st_with_snapseq(st, snap_seq_of(snap))
  med_init_empty(Nat.is_eq(Map.size(&2, Auth, st_keys(st2)), 0n), st2)

# --- rate-limit bucket restore across graceful restart (Round 3 item 172) ---
# Mirrors the RL section written by snap_rl_section (med_store.bend) into
# final pre-restart snapshots. Each "RL\t<id>\t<rem>\t<count>" line is
# rebased into the fresh monotonic clock domain:
#   start' = max(0, now + min(rem, window) - window)
# so a restored bucket lives at most one window from boot and can never go
# stale (rem is a duration, immune to host-reboot clock jumps). Malformed
# lines (wrong arity, non-numeric rem/count, non-RL op) are skipped --
# fail-closed: a bad line restores nothing. No-op when the snapshot has no
# RL section (periodic snapshots, pre-item-172 snapshots).

def snap_rl_rebase(+now: Nat, +rem: Nat) -> Nat:
  Nat.sub(Nat.add(now, Nat.min(rem, iprl_window_ms())), iprl_window_ms())

def snap_rl_apply_c(mc: Maybe<&1, Nat>, +now: Nat, +rem: Nat, +k: String, +rl: Map<&2, String>) -> Map<&2, String>:
  match mc:
    case None{}: rl
    case Some{count}: Map.set(&2, String, rl, k, Nat.show(snap_rl_rebase(now, rem)) ++ "," ++ Nat.show(count))

def snap_rl_apply(mr: Maybe<&1, Nat>, mc: Maybe<&1, Nat>, +now: Nat, +k: String, +rl: Map<&2, String>) -> Map<&2, String>:
  match mr:
    case None{}: rl
    case Some{rem}: snap_rl_apply_c(mc, now, rem, k, rl)

def snap_rl_fields3(+rest: List<&2, String>, +now: Nat, +k: String, +rs: String, +rl: Map<&2, String>) -> Map<&2, String>:
  match rest:
    case Nil{}: rl
    case cs <> _t: snap_rl_apply(parse_nat_opt(rs), parse_nat_opt(cs), now, k, rl)

def snap_rl_fields2(+rest: List<&2, String>, +now: Nat, +k: String, +rl: Map<&2, String>) -> Map<&2, String>:
  match rest:
    case Nil{}: rl
    case rs <> rest3: snap_rl_fields3(rest3, now, k, rs, rl)

def snap_rl_fields(+rest: List<&2, String>, +now: Nat, +rl: Map<&2, String>) -> Map<&2, String>:
  match rest:
    case Nil{}: rl
    case k <> rest2: snap_rl_fields2(rest2, now, k, rl)

def snap_rl_dispatch(is_rl: Bool, +rest: List<&2, String>, +now: Nat, +rl: Map<&2, String>) -> Map<&2, String>:
  match is_rl:
    case False{}: rl
    case True{}: snap_rl_fields(rest, now, rl)

def snap_rl_parts(+parts: List<&2, String>, +now: Nat, +rl: Map<&2, String>) -> Map<&2, String>:
  match parts:
    case Nil{}: rl
    case op <> rest: snap_rl_dispatch(String.eq(op, "RL"), rest, now, rl)

def snap_rl_restore_line(+line: String, +now: Nat, +rl: Map<&2, String>) -> Map<&2, String>:
  snap_rl_parts(split_char(line, ch_tab()), now, rl)

def snap_rl_restore_go(+lines: List<&2, String>, +now: Nat, +rl: Map<&2, String>) -> Map<&2, String>:
  match lines:
    case Nil{}: rl
    case h <> t: snap_rl_restore_go(t, now, snap_rl_restore_line(h, now, rl))

def snap_rl_restore(+snap: String, +now: Nat, +st: MedState) -> MedState:
  st_with_rl(st, snap_rl_restore_go(split_char(snap, ch_lf()), now, st_rl(st)))

def med_init_after_boot(+snap: String) -> IO(MedState):
  do IO<MedState>:
    wal : String <- wal_read_all_defended(snap)
    +st : MedState <- med_init_replay(snap, wal)
    # Item 145 fix: amputate a torn segment tail AFTER replay (which already
    # handles it in memory) and BEFORE any wal_write, including the purge
    # preservation write below. Fail-open: the old drop_torn replay behavior
    # still applies if amputation reports failure.
    _t : Bool <- wal_amputate_torn_tail()
    _n : Nat <- wal_purge_boot(st_keys(st), wal_snap_ok(snap))
    # Round 3 item 172: rebase persisted rate-limit buckets (RL section of
    # the final pre-restart snapshot) into the fresh monotonic clock domain.
    # No-op when the snapshot has no RL section.
    now : Nat <- IO.now()
    IO.pure(MedState, snap_rl_restore(snap, now, st))

def med_init_boot_nocover(cover: Bool, +snap: String) -> IO(Bool & MedState):
  match cover:
    case False{}:
      do IO<Bool & MedState>:
        _u : Unit <- IO.print("medium-fresh: FATAL: snapshot missing/invalid and retired WAL segments were purged (see wal/purge.log) or are otherwise unaccounted for; refusing to boot to avoid silent data loss\n")
        IO.pure(Bool & MedState, (False{}, med_empty()))
    case True{}:
      do IO<Bool & MedState>:
        st : MedState <- med_init_after_boot(snap)
        IO.pure(Bool & MedState, (True{}, st))

def med_init_boot_after_go(snap_ok: Bool, +snap: String) -> IO(Bool & MedState):
  match snap_ok:
    case True{}:
      do IO<Bool & MedState>:
        st : MedState <- med_init_after_boot(snap)
        IO.pure(Bool & MedState, (True{}, st))
    case False{}:
      do IO<Bool & MedState>:
        # Round 3 item 182: if the snapshot is gone, every retired WAL
        # segment must still be on disk (archive or active). Otherwise the
        # records are unrecoverable and booting would be silent data loss.
        cover : Bool <- wal_cover_ok()
        med_init_boot_nocover(cover, snap)

# Round 3 item 189: tamper-evident boot gate. snapshot_boot_check (med_store)
# flags a non-empty snapshot file whose trailer is syntactically valid but
# whose record-count binding fails (the item-188 E8 forgery shape); refuse
# loudly rather than serve silent partial state.
def med_init_boot_after_tamper(tampered: Bool, +snap: String) -> IO(Bool & MedState):
  match tampered:
    case True{}:
      do IO<Bool & MedState>:
        _u : Unit <- IO.print("medium-fresh: FATAL: snapshot trailer record-count mismatch (possible tampering or out-of-band truncation); refusing to boot to avoid silent partial state\n")
        IO.pure(Bool & MedState, (False{}, med_empty()))
    case False{}: med_init_boot_after_go(wal_snap_ok(snap), snap)

def med_init_boot_after(+snap: String) -> IO(Bool & MedState):
  do IO<Bool & MedState>:
    tampered : Bool <- snapshot_boot_check()
    med_init_boot_after_tamper(tampered, snap)

# --- single-split boot chain (Round 3 item 196) ---
# Replaces the med_init_boot_after/tamper/go/nocover + med_init_after_boot
# + med_init_replay chain above. The snapshot files are split ONCE by
# snapshot_boot_load (med_store); every step below works from that line
# list instead of re-splitting the full content. Behavior is unchanged
# (see the equivalence notes at snapshot_boot_load in med_store).

def med_init_replay_scan(+lines: List<&2, String>, +wal: String) -> IO(MedState):
  +st : MedState = wal_replay(wal, wal_replay_lines(lines, med_empty()))
  +st2 : MedState = st_with_snapseq(st, snap_lines_seq(lines))
  med_init_empty(Nat.is_eq(Map.size(&2, Auth, st_keys(st2)), 0n), st2)

def snap_rl_restore_lines(+lines: List<&2, String>, +now: Nat, +st: MedState) -> MedState:
  st_with_rl(st, snap_rl_restore_go(lines, now, st_rl(st)))

def med_init_after_boot_scan(+lines: List<&2, String>) -> IO(MedState):
  do IO<MedState>:
    wal : String <- wal_read_all_defended_scan(lines)
    +st : MedState <- med_init_replay_scan(lines, wal)
    # Item 145 fix: amputate a torn segment tail AFTER replay (which already
    # handles it in memory) and BEFORE any wal_write, including the purge
    # preservation write below. Fail-open: the old drop_torn replay behavior
    # still applies if amputation reports failure.
    _t : Bool <- wal_amputate_torn_tail()
    _n : Nat <- wal_purge_boot(st_keys(st), snap_lines_ok(lines))
    # Round 3 item 172: rebase persisted rate-limit buckets (RL section of
    # the final pre-restart snapshot) into the fresh monotonic clock domain.
    # No-op when the snapshot has no RL section.
    now : Nat <- IO.now()
    IO.pure(MedState, snap_rl_restore_lines(lines, now, st))

def med_init_boot_nocover_scan(cover: Bool, +lines: List<&2, String>) -> IO(Bool & MedState):
  match cover:
    case False{}:
      do IO<Bool & MedState>:
        _u : Unit <- IO.print("medium-fresh: FATAL: snapshot missing/invalid and retired WAL segments were purged (see wal/purge.log) or are otherwise unaccounted for; refusing to boot to avoid silent data loss\n")
        IO.pure(Bool & MedState, (False{}, med_empty()))
    case True{}:
      do IO<Bool & MedState>:
        st : MedState <- med_init_after_boot_scan(lines)
        IO.pure(Bool & MedState, (True{}, st))

def med_init_boot_after_go_scan(snap_ok: Bool, +lines: List<&2, String>) -> IO(Bool & MedState):
  match snap_ok:
    case True{}:
      do IO<Bool & MedState>:
        st : MedState <- med_init_after_boot_scan(lines)
        IO.pure(Bool & MedState, (True{}, st))
    case False{}:
      do IO<Bool & MedState>:
        # Round 3 item 182: if the snapshot is gone, every retired WAL
        # segment must still be on disk (archive or active). Otherwise the
        # records are unrecoverable and booting would be silent data loss.
        cover : Bool <- wal_cover_ok()
        med_init_boot_nocover_scan(cover, lines)

def med_init_boot_after_tamper_scan(tampered: Bool, +lines: List<&2, String>) -> IO(Bool & MedState):
  match tampered:
    case True{}:
      do IO<Bool & MedState>:
        _u : Unit <- IO.print("medium-fresh: FATAL: snapshot trailer record-count mismatch (possible tampering or out-of-band truncation); refusing to boot to avoid silent partial state\n")
        IO.pure(Bool & MedState, (False{}, med_empty()))
    case False{}: med_init_boot_after_go_scan(snap_lines_ok(lines), lines)

def med_init_boot_after_scan(ld: List<&2, String> & Bool) -> IO(Bool & MedState):
  (lines, tampered) = ld
  med_init_boot_after_tamper_scan(tampered, lines)

def med_init_boot(ok: Bool) -> IO(Bool & MedState):
  match ok:
    case False{}:
      do IO<Bool & MedState>:
        _u : Unit <- IO.print("medium-fresh: FATAL: WAL unavailable, not starting\n")
        IO.pure(Bool & MedState, (False{}, med_empty()))
    case True{}:
      do IO<Bool & MedState>:
        ld : List<&2, String> & Bool <- snapshot_boot_load()
        med_init_boot_after_scan(ld)

def med_init() -> IO(Bool & MedState):
  do IO<Bool & MedState>:
    b : Bool <- wal_boot()
    med_init_boot(b)

# --- connection cap: token-channel semaphore ---
# At most conn_cap() connections are live at once. The accept loop takes one
# token per accepted socket; the handler wrapper returns it when the handler
# task finishes (every exit path runs through the wrapper). When the pool is
# empty, Chan.recv parks the accept loop — the kernel listen backlog absorbs
# the pressure until a slot frees. Combined with the poll read deadlines, a
# slowloris client cannot hold a slot longer than the idle timeout.

def conn_cl_recv(s2: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +rest: String, +reqch: Chan(MedMsg), +n: Nat, +cl: Nat, +ver: String) -> IO(Maybe<Socket>):
  do IO<Maybe<Socket>>:
    sbr : Socket & String <- recv_body(s2, cl, rest)
    conn_body_done(sbr, method, path, query, headers, cl, reqch, n, ver)

def conn_cl_big(too_big: Bool, s2: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +rest: String, +reqch: Chan(MedMsg), +n: Nat, +cl: Nat, +ver: String) -> IO(Maybe<Socket>):
  match too_big:
    case True{}: IO.bind(Unit, Maybe<Socket>, conn_send_err_m(s2, method, 413, "body_too_large", "Request body exceeds the 65536 byte limit. See GET /help for the API."), _u => IO.pure(Maybe<Socket>, None{}))
    case False{}: conn_cl_recv(s2, method, path, query, headers, rest, reqch, n, cl, ver)

def conn_cl_dec(s2: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +rest: String, +reqch: Chan(MedMsg), +n: Nat, +cl: Nat, +ver: String) -> IO(Maybe<Socket>):
  conn_cl_big(Nat.is_lt(body_max(), cl), s2, method, path, query, headers, rest, reqch, n, cl, ver)

def conn_cl_miss(is_post: Bool, s2: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +rest: String, +reqch: Chan(MedMsg), +n: Nat, +ver: String) -> IO(Maybe<Socket>):
  match is_post:
    case True{}: IO.bind(Unit, Maybe<Socket>, conn_send_err_m(s2, method, 411, "length_required", "POST requires a Content-Length header. See GET /help for the API."), _u => IO.pure(Maybe<Socket>, None{}))
    case False{}: conn_cl_dec(s2, method, path, query, headers, rest, reqch, n, 0n, ver)

def conn_cl(s2: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +rest: String, +reqch: Chan(MedMsg), +n: Nat, spec: BodySpec, is_post: Bool, +ver: String) -> IO(Maybe<Socket>):
  match spec:
    case CLMissing{}: conn_cl_miss(is_post, s2, method, path, query, headers, rest, reqch, n, ver)
    case CLBad{}: IO.bind(Unit, Maybe<Socket>, conn_send_err_m(s2, method, 400, "bad_request", "Malformed Content-Length. Must be a non-negative decimal integer, exactly once."), _u => IO.pure(Maybe<Socket>, None{}))
    case CLOk{cl}: conn_cl_dec(s2, method, path, query, headers, rest, reqch, n, cl, ver)

def conn_hs_bad(many: Bool, s2: Socket, +method: String) -> IO(Maybe<Socket>):
  match many:
    case True{}: IO.bind(Unit, Maybe<Socket>, conn_send_err_m(s2, method, 431, "header_fields_too_large", "Too many header fields. See GET /help for the API."), _u => IO.pure(Maybe<Socket>, None{}))
    case False{}: IO.bind(Unit, Maybe<Socket>, conn_send_err_m(s2, method, 400, "bad_request", "Malformed header field. See GET /help for the API."), _u => IO.pure(Maybe<Socket>, None{}))

def conn_hs_ok(ok: Bool, many: Bool, s2: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +rest: String, +reqch: Chan(MedMsg), +n: Nat, spec: BodySpec, +ver: String) -> IO(Maybe<Socket>):
  match ok:
    case True{}: conn_cl(s2, method, path, query, headers, rest, reqch, n, spec, String.eq(method, "POST"), ver)
    case False{}: conn_hs_bad(many, s2, method)

def conn_hs_st(+hstatus: U32, s2: Socket, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +rest: String, +reqch: Chan(MedMsg), +n: Nat, spec: BodySpec, +ver: String) -> IO(Maybe<Socket>):
  conn_hs_ok(U32.is_eq(hstatus, 0), U32.is_eq(hstatus, 1), s2, method, path, query, headers, rest, reqch, n, spec, ver)

def conn_headers(s2: Socket, +method: String, +path: String, +query: String, hp: Map<&2, String> & U32, +rest: String, +reqch: Chan(MedMsg), +n: Nat, spec: BodySpec, +ver: String) -> IO(Maybe<Socket>):
  (headers, hstatus) = hp
  conn_hs_st(hstatus, s2, method, path, query, headers, rest, reqch, n, spec, ver)

def conn_head_hr_pq_te(te_bad: Bool, s2: Socket, +method: String, +path: String, +query: String, +t: List<&2, String>, +rest: String, +reqch: Chan(MedMsg), +n: Nat, +ver: String) -> IO(Maybe<Socket>):
  match te_bad:
    case True{}: IO.bind(Unit, Maybe<Socket>, conn_send_err_m(s2, method, 400, "transfer_encoding_unsupported", "This service does not decode Transfer-Encoding. Send a Content-Length header instead. See GET /help for the API."), _u => IO.pure(Maybe<Socket>, None{}))
    case False{}: conn_headers(s2, method, path, query, parse_headers(t), rest, reqch, n, get_cl_spec(t), ver)

def conn_head_hr_pq(s2: Socket, +method: String, pq: String & String, +t: List<&2, String>, +rest: String, +reqch: Chan(MedMsg), +n: Nat, +ver: String) -> IO(Maybe<Socket>):
  (path, query) = pq
  conn_head_hr_pq_te(te_unsupported(t), s2, method, path, query, t, rest, reqch, n, ver)

def conn_head_hr(s2: Socket, +hr: HeadRes, +t: List<&2, String>, +rest: String, +reqch: Chan(MedMsg), +n: Nat) -> IO(Maybe<Socket>):
  match hr:
    case MkHr{method, path, ver}: conn_head_hr_pq(s2, method, split_path_query(path), t, rest, reqch, n, ver)

def conn_head(s2: Socket, mpr: Maybe<&1, HeadRes>, +tok: String, +t: List<&2, String>, +rest: String, +reqch: Chan(MedMsg), +n: Nat) -> IO(Maybe<Socket>):
  match mpr:
    case None{}: IO.bind(Unit, Maybe<Socket>, conn_send_err_m(s2, tok, 400, "bad_request", "Malformed request line. See GET /help for the API."), _u => IO.pure(Maybe<Socket>, None{}))
    case Some{hr}: conn_head_hr(s2, hr, t, rest, reqch, n)

def conn_rl_too(too_long: Bool, s2: Socket, +rl: String, +t: List<&2, String>, +rest: String, +reqch: Chan(MedMsg), +n: Nat) -> IO(Maybe<Socket>):
  match too_long:
    case True{}: IO.bind(Unit, Maybe<Socket>, conn_send_err_m(s2, head_method_token(rl), 414, "uri_too_long", "Request line exceeds the 4096 byte limit."), _u => IO.pure(Maybe<Socket>, None{}))
    case False{}: conn_head(s2, parse_req_line(rl), head_method_token(rl), t, rest, reqch, n)

def conn_rl_len(s2: Socket, +rl: String, +t: List<&2, String>, +rest: String, +reqch: Chan(MedMsg), +n: Nat) -> IO(Maybe<Socket>):
  conn_rl_too(Nat.is_lt(req_line_max(), utf8_byte_len(rl)), s2, rl, t, rest, reqch, n)

def conn_lines(+lines: List<&2, String>, s2: Socket, +rest: String, +reqch: Chan(MedMsg), +n: Nat) -> IO(Maybe<Socket>):
  match lines:
    case Nil{}: IO.bind(Unit, Maybe<Socket>, conn_send_err(s2, 400, "bad_request", "Empty request. See GET /help for the API."), _u => IO.pure(Maybe<Socket>, None{}))
    case h <> t: conn_rl_len(s2, strip_cr(h), t, rest, reqch, n)

def conn_hg_ok(ok: Bool, s2: Socket, +head: String, +rest: String, +code: U32, +reqch: Chan(MedMsg), +n: Nat) -> IO(Maybe<Socket>):
  match ok:
    case True{}: conn_lines(String.split(head, ch_lf()), s2, rest, reqch, n)
    case False{}: IO.bind(Unit, Maybe<Socket>, conn_send_err_m(s2, head_method_token(head), code, conn_hg_err_msg(code), conn_hg_err_hint(code)), _u => IO.pure(Maybe<Socket>, None{}))

def conn_got_hg(s2: Socket, +hg: HGot, +reqch: Chan(MedMsg), +n: Nat) -> IO(Maybe<Socket>):
  match hg:
    case MkHg{head, rest, ok, code}: conn_hg_ok(ok, s2, head, rest, code, reqch, n)

def conn_got(shr: Socket & HGot, +reqch: Chan(MedMsg), +n: Nat) -> IO(Maybe<Socket>):
  (s2, +hg) = shr
  conn_got_hg(s2, hg, reqch, n)

# Forked per connection. ALL blocking socket reads (head assembly AND body)
# happen here, so a slow client stalls only its own task. The owner never
# blocks on a socket.
#
# One-shot request handler: processes exactly ONE request on the socket and
# returns the socket (Some) if keep-alive was agreed and the write succeeded,
# or None if the connection should close. The loop lives in conn_loop below.
def conn_handler_n(sock: Socket, +reqch: Chan(MedMsg), +n: Nat) -> IO(Maybe<Socket>):
  do IO<Maybe<Socket>>:
    shr : Socket & HGot <- recv_head(sock)
    ms : Maybe<Socket> <- conn_got(shr, reqch, n)
    IO.pure(Maybe<Socket>, ms)

# Check if the stopch is closed (shutdown in progress). Non-recursive helper.
# Returns True if closed, False if open (token is cycled back).
def stopch_poll_res(sc: Maybe<&1, Unit>, +stopch: Chan(Unit)) -> IO(Bool):
  match sc:
    case None{}: IO.pure(Bool, True{})
    case Some{_u}:
      do IO<Bool>:
        _sb : Bool <- Chan.send(Unit, stopch, Unit{})
        IO.pure(Bool, False{})

def stopch_closed(+stopch: Chan(Unit)) -> IO(Bool):
  do IO<Bool>:
    sc : Maybe<&1, Unit> <- Chan.recv(Unit, stopch)
    stopch_poll_res(sc, stopch)

# Branch on the shutdown flag. Non-recursive: either closes the socket
# (shutdown) or processes one request. The stopch check prevents a handler
# from parking in recv_head after shutdown was initiated (item 183: the
# shutdown_wake handler would park and trigger "bend: deadlock" on exit).
def conn_step_go(closed: Bool, sock: Socket, +reqch: Chan(MedMsg), +n: Nat) -> IO(Maybe<Socket>):
  match closed:
    case True{}:
      do IO<Maybe<Socket>>:
        _c : Unit <- Socket.close(sock)
        IO.pure(Maybe<Socket>, None{})
    case False{}: conn_handler_n(sock, reqch, n)

# Processes one request if ms is Some{sock}; passes through None unchanged.
# Checks stopch BEFORE parking in recv_head: if shutdown was initiated,
# closes the socket and returns None instead of blocking (item 183).
# NON-RECURSIVE helper — the loop driver is conn_loop below.
def conn_step(ms: Maybe<Socket>, +reqch: Chan(MedMsg), +stopch: Chan(Unit), n: Nat) -> IO(Maybe<Socket>):
  match ms:
    case None{}: IO.pure(Maybe<Socket>, None{})
    case Some{sock}:
      do IO<Maybe<Socket>>:
        closed : Bool <- stopch_closed(stopch)
        conn_step_go(closed, sock, reqch, n)

# Handles the fuel-exhausted case: close the socket if live, return the
# token. NON-RECURSIVE helper.
def conn_loop_end(ms: Maybe<Socket>, +semch: Chan(Unit)) -> IO(Unit):
  match ms:
    case None{}:
      do IO<Unit>:
        _b : Bool <- Chan.send(Unit, semch, Unit{})
        IO.pure(Unit, Unit{})
    case Some{sock}:
      do IO<Unit>:
        _c : Unit <- Socket.close(sock)
        _b : Bool <- Chan.send(Unit, semch, Unit{})
        IO.pure(Unit, Unit{})

# Round 3 item 183 (HTTP keep-alive): the per-connection loop with explicit
# fuel. The recursion is DIRECT (conn_loop calls conn_loop) with
# structurally decreasing fuel — Bend forbids the mutual-recursion /
# function-value-passing shape. fuel starts at ka_max_reqs() (100); each
# request consumes one. At 0 the socket is closed (the 100th request already
# got Connection: close via conn_ka_want's n+1 cap). n counts requests served
# (0-based) for the keep-alive want decision. The Maybe<Socket> (None =
# writer closed, Some = keep-alive) is threaded through conn_step; the match
# on it happens in the non-recursive helpers, never after a bind.
def conn_loop(fuel: Nat, ms: Maybe<Socket>, +reqch: Chan(MedMsg), +semch: Chan(Unit), +stopch: Chan(Unit), +n: Nat) -> IO(Unit):
  match fuel:
    case 0n: conn_loop_end(ms, semch)
    case 1n+f:
      do IO<Unit>:
        ms2 : Maybe<Socket> <- conn_step(ms, reqch, stopch, n)
        conn_loop(f, ms2, reqch, semch, stopch, Nat.add(n, 1n))

# --- serialized state owner ---


def conn_cap_nat() -> Nat:
  Nat.mul(32n, 32n)

def sem_fill_go(rem: Nat, +ch: Chan(Unit)) -> IO(Chan(Unit)):
  match rem:
    case 0n: IO.pure(Chan(Unit), ch)
    case 1n+r:
      do IO<Chan(Unit)>:
        _b : Bool <- Chan.send(Unit, ch, Unit{})
        sem_fill_go(r, ch)

def sem_new() -> IO(Chan(Unit)):
  do IO<Chan(Unit)>:
    +ch : Chan(Unit) <- Chan.new(Unit, U32.from_nat(conn_cap_nat()))
    sem_fill_go(conn_cap_nat(), ch)

def conn_handler_wrapped(sock: Socket, +reqch: Chan(MedMsg), +semch: Chan(Unit), +stopch: Chan(Unit)) -> IO(Unit):
  conn_loop(ka_max_reqs(), Some{sock}, reqch, semch, stopch, 0n)

# Round 3 item 23: the accept loop used to run on a fixed 1,000,000-connection
# fuel, independent of the owner's request budget — with MEDIUM_REQ_BUDGET
# above 1M the accept loop halted first and drove an undocumented graceful
# shutdown. The fuel is now max(budget, 1M): the accept loop can never die
# before the owner budget in normal operation, so the request budget stays
# the single lifecycle control. The 1M floor preserves existing behavior
# under the default budget.
def accept_fuel_floor() -> Nat:
  Nat.mul(Nat.mul(10n, 100n), Nat.mul(10n, 100n))

def accept_fuel_for(+budget: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(budget, accept_fuel_floor()), accept_fuel_floor(), budget)

# Terminal accept stop: close the request channel so the owner drains and
# finishes. Non-recursive helper (accept_loop itself is the only recursion).
def accept_halt(+reqch: Chan(MedMsg), +msg: String) -> IO(Unit):
  do IO<Unit>:
    _u : Unit <- IO.print("medium-fresh: " ++ msg ++ ", stop accepting\n")
    _c : Unit <- Chan.close(MedMsg, reqch)
    IO.pure(Unit, Unit{})

# Accept loop with graceful-shutdown support (Round 3 item 19).
# sta threads (stop-token, (conn-token, listener/accept-result)).
# The stop token is cycled every iteration: recv it, immediately send it
# back, so each iteration observes the channel state exactly once. The
# stopch recv happens AFTER TCP.accept returns: once the owner closes the
# channel, no further accept may park — the next iteration sees sc=None and
# halts. (Checking before the accept would leave a parking accept after
# the close observation -> deadlock.)
def accept_loop(fuel: Nat, sta: Maybe<&1, Unit> & (Maybe<&1, Unit> & (Listener & Result<&1, &1, U32 & String, Socket>)), +semch: Chan(Unit), +reqch: Chan(MedMsg), +stopch: Chan(Unit)) -> IO(Unit):
  match fuel:
    case 0n: accept_halt(reqch, "accept budget exhausted")
    case 1n+f:
      (sc, sta2) = sta
      match sc:
        case None{}: accept_halt(reqch, "graceful shutdown requested")
        case Some{_u}:
          (tok, ar) = sta2
          match tok:
            case None{}:
              IO.print("medium-fresh: connection pool shut down, stop accepting\n")
            case Some{_u2}:
              (l2, ares) = ar
              match ares:
                case Fail{error}:
                  do IO<Unit>:
                    ar2 : Listener & Result<&1, &1, U32 & String, Socket> <- TCP.accept(l2)
                    sc2 : Maybe<&1, Unit> <- Chan.recv(Unit, stopch)
                    _sb : Bool <- Chan.send(Unit, stopch, Unit{})
                    accept_loop(f, (sc2, (Some{Unit{}}, ar2)), semch, reqch, stopch)
                case Done{sock}:
                  do IO<Unit>:
                    _u3 : Unit <- IO.spawn(Unit, conn_handler_wrapped(sock, reqch, semch, stopch))
                    ar3 : Listener & Result<&1, &1, U32 & String, Socket> <- TCP.accept(l2)
                    tok3 : Maybe<&1, Unit> <- Chan.recv(Unit, semch)
                    sc2 : Maybe<&1, Unit> <- Chan.recv(Unit, stopch)
                    _sb : Bool <- Chan.send(Unit, stopch, Unit{})
                    accept_loop(f, (sc2, (tok3, ar3)), semch, reqch, stopch)

def accept_loop_task(l: Listener, +budget: Nat, +reqch: Chan(MedMsg), +semch: Chan(Unit), +stopch: Chan(Unit)) -> IO(Unit):
  do IO<Unit>:
    sc : Maybe<&1, Unit> <- Chan.recv(Unit, stopch)
    _sb : Bool <- Chan.send(Unit, stopch, Unit{})
    tok : Maybe<&1, Unit> <- Chan.recv(Unit, semch)
    ar : Listener & Result<&1, &1, U32 & String, Socket> <- TCP.accept(l)
    accept_loop(accept_fuel_for(budget), (sc, (tok, ar)), semch, reqch, stopch)

def main_listen_ok(l: Listener, +st: MedState, +budget: Nat) -> IO(Unit):
  do IO<Unit>:
    +reqch : Chan(MedMsg) <- Chan.new(MedMsg, 256)
    +semch : Chan(Unit) <- sem_new()
    +stopch : Chan(Unit) <- Chan.new(Unit, U32.from_nat(1n))
    _b : Bool <- Chan.send(Unit, stopch, Unit{})
    _u : Unit <- IO.print("medium-fresh: request budget " ++ Nat.show(budget) ++ " (MEDIUM_REQ_BUDGET)\n")
    _o : Unit <- IO.spawn(Unit, owner_loop_start(budget, reqch, stopch, st))
    accept_loop_task(l, budget, reqch, semch, stopch)

# On bind failure no tasks are spawned, so main simply returns and the
# process exits cleanly (Round 2 item 12: previously the owner was spawned
# before the listen, and a failed bind left it parked on an empty channel
# forever -> "bend: deadlock" instead of a clean exit).
def main_listen_res(budget: Nat, lr: Result<&1, &1, U32 & String, Listener>, +st: MedState) -> IO(Unit):
  match lr:
    case Fail{error}: IO.print("medium-fresh: listen failed, exiting\n")
    case Done{l}: main_listen_ok(l, st, budget)

# A failed WAL boot is fatal: main returns without listening (same clean
# exit as a failed bind), instead of serving a state that cannot be
# persisted.
def main_boot_ok(budget: Nat, ok: Bool, +st: MedState) -> IO(Unit):
  match ok:
    case False{}: IO.print("medium-fresh: startup aborted (WAL unavailable)\n")
    case True{}:
      do IO<Unit>:
        lr : Result<&1, &1, U32 & String, Listener> <- TCP.listen("127.0.0.1", 18081)
        main_listen_res(budget, lr, st)

def main_boot(budget: Nat, bs: Bool & MedState) -> IO(Unit):
  (bok, st) = bs
  main_boot_ok(budget, bok, st)

def main_with_rrl(+rrl: Nat, bs: Bool & MedState) -> Bool & MedState:
  (bok, st) = bs
  (bok, st_with_rrl(st, rrl))

def main_with_krl(+krl: Nat, bs: Bool & MedState) -> Bool & MedState:
  (bok, st) = bs
  (bok, st_with_krl(st, krl))

def main_go(+rrl: Nat, +krl: Nat, +budget: Nat, bs: Bool & MedState) -> IO(Unit):
  do IO<Unit>:
    _v : Unit <- IO.print("medium-fresh: restart rate limit " ++ Nat.show(rrl) ++ "/60s per credential (MEDIUM_RESTART_RL)\n")
    _w : Unit <- IO.print("medium-fresh: key-management rate limit " ++ Nat.show(krl) ++ "/60s per credential (MEDIUM_KEY_RL)\n")
    main_boot(budget, main_with_krl(krl, main_with_rrl(rrl, bs)))

def main() -> IO(Unit):
  do IO<Unit>:
    _u : Unit <- IO.print("medium-fresh: starting on :18081\n")
    budget : Nat <- read_request_budget()
    rrl : Nat <- read_restart_rl()
    krl : Nat <- read_key_rl()
    bs : Bool & MedState <- med_init()
    main_go(rrl, krl, budget, bs)
