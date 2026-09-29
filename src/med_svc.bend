# med_svc.bend — fresh Medium service, part 8: HTTP route handlers.
# Every handler runs in the serialized owner task.
# Mutations WAL-append BEFORE replying; secrets are never logged or stored.
# (Bend 2.x has no higher-order functions, so auth gates are explicit.)

# --- send helpers ---
# Owner-side responses are handed to forked writer tasks (med_net.bend):
# the serialized owner NEVER blocks on a socket write. State is WAL-committed
# before the write is handed off, so fire-and-forget here preserves the
# commit-before-reply ordering.

def send_raw(sock: Socket, +text: String) -> IO(Unit):
  do IO<Unit>:
    _u : Unit <- IO.spawn(Unit, writer_task(sock, text))
    IO.pure(Unit, Unit{})


# Round 3 item 183 (HTTP keep-alive): _ka variants thread the handler's
# keep-alive decision to the writer. The non-ka variants above are kept for
# deny paths (rate limiting) and handler-side errors, which always close.
def send_raw_ka(sock: Socket, +text: String, +ka: Ka) -> IO(Unit):
  do IO<Unit>:
    _u : Unit <- IO.spawn(Unit, writer_task_ka(sock, text, ka))
    IO.pure(Unit, Unit{})


def send_json(sock: Socket, +st: MedState, +status: U32, +body: String) -> IO(MedState):
  do IO<MedState>:
    _u : Unit <- send_raw(sock, http_resp(status, body, False{}))
    IO.pure(MedState, st)


def send_json_ka(sock: Socket, +st: MedState, +ka: Ka, +status: U32, +body: String) -> IO(MedState):
  do IO<MedState>:
    _u : Unit <- send_raw_ka(sock, http_resp(status, body, ka_want(ka)), ka)
    IO.pure(MedState, st)


def send_err(sock: Socket, +st: MedState, +status: U32, +code: String) -> IO(MedState):
  # Round 3 item 40: unify the error-body contract. Owner-level errors used to
  # emit the bare {"error":"<code>"} shape while handler/connection-level
  # errors (conn_send_err -> http_err) emit the full err_body_json schema
  # ({"error","code","_hint","_links"}). Two schemas for one API is a contract
  # bug: clients cannot rely on a stable error shape. Now every error body
  # uses the single self-documenting schema (med_parse.bend err_body_json).
  send_json(sock, st, status, err_body_json(status, code, "See GET /help for the API."))


def send_err_ka(sock: Socket, +st: MedState, +ka: Ka, +status: U32, +code: String) -> IO(MedState):
  send_json_ka(sock, st, ka, status, err_body_json(status, code, "See GET /help for the API."))


def send_ok(sock: Socket, +st: MedState, +status: U32, +body: String) -> IO(MedState):
  send_json(sock, st, status, body)


def send_ok_ka(sock: Socket, +st: MedState, +ka: Ka, +status: U32, +body: String) -> IO(MedState):
  send_json_ka(sock, st, ka, status, body)


# Item 104: this service defines no HEAD routes; answer 405 with headers
# ONLY — RFC 9110 S9.3.2 forbids a message body on HEAD responses.
# Content-Length carries the would-be body length (S8.6-permitted).
def send_head_405(sock: Socket, +st: MedState) -> IO(MedState):
  do IO<MedState>:
    _u : Unit <- send_raw(sock, http_err_head(405, "method_not_allowed", "See GET /help for the API.", False{}))
    IO.pure(MedState, st)


def send_head_405_ka(sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  do IO<MedState>:
    _u : Unit <- send_raw_ka(sock, http_err_head(405, "method_not_allowed", "See GET /help for the API.", ka_want(ka)), ka)
    IO.pure(MedState, st)


# --- key generation (urandom) ---

def bytes_to_hex_go(+cs: List<&2, Char>) -> String:
  match cs:
    case Nil{}: ""
    case c <> t:
      +b : U32 = Char.to_u32(c)
      String.from_list(hex_dig(U32.and(U32.shrn(b, 4n), 15)) <> hex_dig(U32.and(b, 15)) <> Nil{}) ++ bytes_to_hex_go(t)


def bytes_to_hex(+s: String) -> String:
  bytes_to_hex_go(String.to_list(s))


def keygen_urandom_done(rr: File & Result<&1, &1, U32 & String, String>) -> IO(String):
  (f2, res) = rr
  match res:
    case Fail{e}:
      do IO<String>:
        _c : Unit <- File.close(f2)
        IO.pure(String, "")
    case Done{bytes}:
      do IO<String>:
        _c : Unit <- File.close(f2)
        IO.pure(String, bytes_to_hex(bytes))


def keygen_urandom_open(r: Result<&1, &1, U32 & String, File>) -> IO(String):
  match r:
    case Fail{e}: IO.pure(String, "")
    case Done{f}:
      do IO<String>:
        rr : File & Result<&1, &1, U32 & String, String> <- File.read(f, 32)
        keygen_urandom_done(rr)


def keygen_secure() -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, File> <- File.open("/dev/urandom", "r")
    keygen_urandom_open(r)


def keygen_fallback(+now: Nat, +seq: Nat) -> String:
  "bk_" ++ sha256_hex(Nat.show(now) ++ ":" ++ Nat.show(seq))


def keygen_pick_go(is_enough: Bool, +hex: String, +now: Nat, +seq: Nat) -> String:
  match is_enough:
    case True{}: "bk_" ++ hex
    case False{}: keygen_fallback(now, seq)


def keygen_pick(+hex: String, +now: Nat, +seq: Nat) -> String:
  keygen_pick_go(Nat.is_lt(32n, String.length(hex)), hex, now, seq)


# --- auth gates (explicit, no HOFs) ---

def is_member(+a: Auth) -> Bool:
  Bool.or(String.eq(auth_role(a), "member"), String.eq(auth_role(a), "admin"))


def is_admin(+a: Auth) -> Bool:
  String.eq(auth_role(a), "admin")


def auth_of(+headers: Map<&2, String>, +st: MedState) -> IO(Maybe<&1, Auth>):
  do IO<Maybe<&1, Auth>>:
    now : Nat <- IO.now()
    IO.pure(Maybe<&1, Auth>, authorize_valid(headers, st_keys(st), now))


# --- users ---

def user_key(+tenant: String, +id: String) -> String:
  "u:" ++ tenant ++ ":" ++ id


def user_serialize(+name: String, +bio: String) -> String:
  json_esc(name) ++ s_tab() ++ json_esc(bio)


def user_deser_go(mpos: Maybe<&1, Nat>, +v: String) -> String & String:
  match mpos:
    case None{}: (v, "")
    case Some{p}:
      +pp : Nat = p
      +vv : String = v
      (String.take(vv, pp), String.drop(vv, Nat.add(pp, 1n)))


def user_deser(+v: String) -> String & String:
  user_deser_go(find_char(v, ch_tab()), v)


def user_to_json_go(nb: String & String, +id: String) -> String:
  (name, bio) = nb
  "{\"id\":\"" ++ json_esc(id) ++ "\",\"name\":\"" ++ name ++ "\",\"bio\":\"" ++ bio ++ "\"}"


def user_to_json(+id: String, +v: String) -> String:
  user_to_json_go(user_deser(v), id)


# --- subscriber wakeup (called after mutations emit events) ---

def last_evt_tenant_go(+log: List<&2, Evt>) -> String:
  match log:
    case Nil{}: ""
    case h <> _: evt_tenant(h)


def last_evt_tenant(+st: MedState) -> String:
  last_evt_tenant_go(st_evlog(st))


def wake_body(+sub: PendSub, +st: MedState) -> String:
  "{\"events\":[" ++ join_str(evt_filter(st_evlog(st), pend_tenant(sub), pend_cursor(sub)), ",") ++ "],\"cursor\":" ++ Nat.show(evt_max_seq(st_evlog(st), pend_cursor(sub))) ++ evt_trunc_flag(st_evlog(st), pend_cursor(sub)) ++ "}"


def wake_one_go(msock: Maybe<&1, Socket>, +sub: PendSub, +st: MedState) -> IO(MedState):
  match msock:
    case None{}: IO.pure(MedState, st)
    case Some{sock}: send_ok(sock, st, 200, wake_body(sub, st))


def wake_one(+sub: PendSub, +st: MedState) -> IO(MedState):
  do IO<MedState>:
    msock : Maybe<&1, Socket> <- Chan.recv(Socket, pend_sch(sub))
    wake_one_go(msock, sub, st)


def wake_go(+subs: List<&2, PendSub>, +st: MedState) -> IO(MedState):
  match subs:
    case Nil{}: IO.pure(MedState, st)
    case h <> t:
      do IO<MedState>:
        st2 : MedState <- wake_one(h, st)
        wake_go(t, st2)


# Helpers for closing expired parked subs (item 127: moved up from the
# poll-path section — Bend requires defs to precede use, and the wake path
# now needs close_expired_go too).
def maybe_close_socket(msock: Maybe<&1, Socket>) -> IO(Unit):
  match msock:
    case None{}: IO.pure(Unit, Unit{})
    case Some{sock}:
      do IO<Unit>:
        _u : Unit <- Socket.close(sock)
        IO.pure(Unit, Unit{})


def close_expired_go(+subs: List<&2, PendSub>, +st: MedState) -> IO(MedState):
  match subs:
    case Nil{}: IO.pure(MedState, st)
    case h <> t:
      do IO<MedState>:
        msock : Maybe<&1, Socket> <- Chan.recv(Socket, pend_sch(h))
        _u : Unit <- maybe_close_socket(msock)
        close_expired_go(t, st)


# Wake path enforces the same lazy expiry the poll path does (item 127):
# expired parked subs are closed (zero-byte FIN), not woken. Previously the
# wake path never checked expiry, so subs arbitrarily past the 25s window
# were still woken on the next mutation.
def wake_tenant_subs_expired(kept: List<&2, PendSub> & List<&2, PendSub>, +pend: List<&2, PendSub>, +st: MedState, +tenant: String) -> IO(MedState):
  match kept:
    case (keep, expired):
      do IO<MedState>:
        st2 : MedState <- close_expired_go(expired, st_with_pend(st, pend_without_tenant(pend, tenant)))
        wake_go(keep, st2)


def wake_tenant_subs_go(+pend: List<&2, PendSub>, +st: MedState, +tenant: String) -> IO(MedState):
  do IO<MedState>:
    +now : Nat <- IO.now()
    wake_tenant_subs_expired(pend_expire_collect(pend_for_tenant(pend, tenant), now, Nil{}, Nil{}), pend, st, tenant)


def wake_tenant_subs(+st: MedState, +tenant: String) -> IO(MedState):
  wake_tenant_subs_go(st_pend(st), st, tenant)


def send_ok_wake_go(+st: MedState) -> IO(MedState):
  wake_tenant_subs(st, last_evt_tenant(st))


def send_ok_wake(sock: Socket, +st: MedState, status: U32, +body: String, +ka: Ka) -> IO(MedState):
  do IO<MedState>:
    st2 : MedState <- send_ok_ka(sock, st, ka, status, body)
    send_ok_wake_go(st2)


def post_users_commit2(ok: Bool, +id: String, sock: Socket, +st: MedState, +st_new: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: send_ok_wake(sock, st_new, 201, "{\"id\":\"" ++ json_esc(id) ++ "\"}", ka)
    case False{}: send_err_ka(sock, st, ka, 500, "wal_write_failed")


def post_users_wal(+name: String, +bio: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  +id : String = "u" ++ Nat.show(st_seq(st))
  +st2 : MedState = st_with_seq(st_with_db(st, Map.set(&2, String, st_db(st), user_key(auth_tenant(a), id), user_serialize(name, bio))), Nat.add(st_seq(st), 1n))
  +st3 : MedState = evt_emit(st2, auth_tenant(a), "user.created", "{\"id\":\"" ++ json_esc(id) ++ "\"}")
  do IO<MedState>:
    # Single fsync'd write carries the user record, the new sequence number,
    # AND the commit event (EVT line): no crash window can leave a durable
    # user without its event or vice versa.
    ok : Bool <- wal_setseq_evt(user_key(auth_tenant(a), id), user_serialize(name, bio), st_seq(st3), evt_head_opt(st_evlog(st3)))
    post_users_commit2(ok, id, sock, st, st3, ka)


def post_users_valid(ok: Bool, +name: String, +bio: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: post_users_wal(name, bio, a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 400, "invalid_name")


def post_users_create(+name: String, +bio: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  post_users_valid(valid_name(name), name, bio, a, sock, st, ka)


def get_user_empty(empty: Bool, +v: String, +id: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match empty:
    case True{}: send_err_ka(sock, st, ka, 404, "not_found")
    case False{}: send_ok_ka(sock, st, ka, 200, user_to_json(id, v))


def get_user_go(+v: String, +id: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  get_user_empty(String.is_empty(v), v, id, sock, st, ka)


def get_user(+a: Auth, sock: Socket, +st: MedState, +id: String, +ka: Ka) -> IO(MedState):
  get_user_go(db_get(st_db(st), user_key(auth_tenant(a), id)), id, sock, st, ka)


# --- publication membership (pure helpers; precede article code) ---

def pub_key(+tenant: String, +id: String) -> String:
  "p:" ++ tenant ++ ":" ++ id


# pm:<tenant>:<pub>:<kid> -> role (writer|editor). Only the pub owner or a
# tenant admin can manage members. Members (or owner) can post articles to pub.

def pm_key(+tenant: String, +pub: String, +kid: String) -> String:
  "pm:" ++ tenant ++ ":" ++ pub ++ ":" ++ kid


def pm_get(+st: MedState, +tenant: String, +pub: String, +kid: String) -> String:
  db_get(st_db(st), pm_key(tenant, pub, kid))


def pub_owner_from_parts(+parts: List<&2, String>) -> String:
  match parts:
    case Nil{}: ""
    case h <> _: h


def pub_owner_of(+st: MedState, +tenant: String, +pid: String) -> String:
  pub_owner_from_parts(split_char(db_get(st_db(st), pub_key(tenant, pid)), ch_tab()))


def can_manage_pub(+a: Auth, +st: MedState, +pid: String) -> Bool:
  Bool.or(is_admin(a),
    String.eq(pub_owner_of(st, auth_tenant(a), pid), auth_kid(a)))


def can_post_to_pub(+a: Auth, +st: MedState, +pid: String) -> Bool:
  Bool.or(can_manage_pub(a, st, pid),
    Bool.not(String.is_empty(pm_get(st, auth_tenant(a), pid, auth_kid(a)))))


def valid_pm_role(+r: String) -> Bool:
  Bool.or(String.eq(r, "writer"), String.eq(r, "editor"))

# --- articles ---

def article_key(+tenant: String, +id: String) -> String:
  "a:" ++ tenant ++ ":" ++ id


def article_serialize(+author: String, +title: String, +body: String, +pub: String, +created: Nat) -> String:
  json_esc(author) ++ s_tab() ++ json_esc(title) ++ s_tab() ++ json_esc(body) ++ s_tab() ++ json_esc(pub) ++ s_tab() ++ Nat.show(created)


def article_to_json_go5(+created: String, +id: String, +author: String, +title: String, +body: String, +pub: String) -> String:
  "{\"id\":\"" ++ json_esc(id) ++ "\",\"author\":\"" ++ author ++ "\",\"title\":\"" ++ title ++ "\",\"body\":\"" ++ body ++ "\",\"pub\":\"" ++ pub ++ "\",\"created\":" ++ created ++ "}"


def article_to_json_go4(+t4: List<&2, String>, +id: String, +author: String, +title: String, +body: String, +pub: String) -> String:
  match t4:
    case Nil{}: "{\"id\":\"" ++ json_esc(id) ++ "\"}"
    case created <> _: article_to_json_go5(created, id, author, title, body, pub)


def article_to_json_go3(+t3: List<&2, String>, +id: String, +author: String, +title: String, +body: String) -> String:
  match t3:
    case Nil{}: "{\"id\":\"" ++ json_esc(id) ++ "\"}"
    case pub <> t4: article_to_json_go4(t4, id, author, title, body, pub)


def article_to_json_go2(+t2: List<&2, String>, +id: String, +author: String, +title: String) -> String:
  match t2:
    case Nil{}: "{\"id\":\"" ++ json_esc(id) ++ "\"}"
    case body <> t3: article_to_json_go3(t3, id, author, title, body)


def article_to_json_go(+parts: List<&2, String>, +id: String) -> String:
  match parts:
    case Nil{}: "{\"id\":\"" ++ json_esc(id) ++ "\"}"
    case author <> t:
      match t:
        case Nil{}: "{\"id\":\"" ++ json_esc(id) ++ "\"}"
        case title <> t2: article_to_json_go2(t2, id, author, title)


def article_to_json(+id: String, +v: String) -> String:
  article_to_json_go(split_char(v, ch_tab()), id)


def post_articles_commit2(ok: Bool, +id: String, sock: Socket, +st: MedState, +st_new: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: send_ok_wake(sock, st_new, 201, "{\"id\":\"" ++ json_esc(id) ++ "\"}", ka)
    case False{}: send_err_ka(sock, st, ka, 500, "wal_write_failed")


def post_articles_wal2(+now: Nat, +title: String, +tbody: String, +pub: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  +id : String = "a" ++ Nat.show(st_seq(st))
  +st2 : MedState = st_with_seq(st_with_db(st, Map.set(&2, String, st_db(st), article_key(auth_tenant(a), id), article_serialize(auth_kid(a), title, tbody, pub, now))), Nat.add(st_seq(st), 1n))
  +st3 : MedState = evt_emit(st2, auth_tenant(a), "article.created", "{\"id\":\"" ++ json_esc(id) ++ "\"}")
  do IO<MedState>:
    # Single fsync'd write carries the article, the new sequence number,
    # AND the commit event (EVT line).
    ok : Bool <- wal_setseq_evt(article_key(auth_tenant(a), id), article_serialize(auth_kid(a), title, tbody, pub, now), st_seq(st3), evt_head_opt(st_evlog(st3)))
    post_articles_commit2(ok, id, sock, st, st3, ka)


def post_articles_wal(+title: String, +tbody: String, +pub: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  do IO<MedState>:
    now : Nat <- IO.now()
    post_articles_wal2(now, title, tbody, pub, a, sock, st, ka)


def post_articles_pub_ok(ok: Bool, +title: String, +tbody: String, +pub: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: post_articles_wal(title, tbody, pub, a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 403, "not_pub_member")


def post_articles_pub_missing(missing: Bool, +title: String, +tbody: String, +pub: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match missing:
    case True{}: send_err_ka(sock, st, ka, 404, "pub_not_found")
    case False{}: post_articles_pub_ok(can_post_to_pub(a, st, pub), title, tbody, pub, a, sock, st, ka)

def post_articles_pub_check_go(is_empty: Bool, +title: String, +tbody: String, +pub: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match is_empty:
    case True{}: post_articles_wal(title, tbody, pub, a, sock, st, ka)
    case False{}: post_articles_pub_missing(String.is_empty(db_get(st_db(st), pub_key(auth_tenant(a), pub))), title, tbody, pub, a, sock, st, ka)


def post_articles_pub_check(+title: String, +tbody: String, +pub: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  post_articles_pub_check_go(String.is_empty(pub), title, tbody, pub, a, sock, st, ka)


def post_articles_valid(ok: Bool, +title: String, +tbody: String, +pub: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: post_articles_pub_check(title, tbody, pub, a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 400, "invalid_title")


def post_articles_create(+title: String, +tbody: String, +pub: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  post_articles_valid(valid_title(title), title, tbody, pub, a, sock, st, ka)


def get_article_empty(empty: Bool, +v: String, +id: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match empty:
    case True{}: send_err_ka(sock, st, ka, 404, "not_found")
    case False{}: send_ok_ka(sock, st, ka, 200, article_to_json(id, v))


def get_article_go(+v: String, +id: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  get_article_empty(String.is_empty(v), v, id, sock, st, ka)


def get_article(+a: Auth, sock: Socket, +st: MedState, +id: String, +ka: Ka) -> IO(MedState):
  get_article_go(db_get(st_db(st), article_key(auth_tenant(a), id)), id, sock, st, ka)


# --- publications ---


def pub_serialize(+owner: String, +name: String, +desc: String) -> String:
  json_esc(owner) ++ s_tab() ++ json_esc(name) ++ s_tab() ++ json_esc(desc)


def pub_to_json_go(+parts: List<&2, String>, +id: String) -> String:
  match parts:
    case Nil{}: "{\"id\":\"" ++ json_esc(id) ++ "\"}"
    case owner <> t:
      match t:
        case Nil{}: "{\"id\":\"" ++ json_esc(id) ++ "\"}"
        case name <> t2:
          match t2:
            case Nil{}: "{\"id\":\"" ++ json_esc(id) ++ "\"}"
            case desc <> _: "{\"id\":\"" ++ json_esc(id) ++ "\",\"owner\":\"" ++ owner ++ "\",\"name\":\"" ++ name ++ "\",\"desc\":\"" ++ desc ++ "\"}"


def pub_to_json(+id: String, +v: String) -> String:
  pub_to_json_go(split_char(v, ch_tab()), id)


def get_pub_empty(empty: Bool, +v: String, +id: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match empty:
    case True{}: send_err_ka(sock, st, ka, 404, "not_found")
    case False{}: send_ok_ka(sock, st, ka, 200, pub_to_json(id, v))


def get_pub_go(+v: String, +id: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  get_pub_empty(String.is_empty(v), v, id, sock, st, ka)


def get_pub(+a: Auth, sock: Socket, +st: MedState, +id: String, +ka: Ka) -> IO(MedState):
  get_pub_go(db_get(st_db(st), pub_key(auth_tenant(a), id)), id, sock, st, ka)



def post_pubs_commit2(ok: Bool, +id: String, sock: Socket, +st: MedState, +st_new: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: send_ok_wake(sock, st_new, 201, "{\"id\":\"" ++ json_esc(id) ++ "\"}", ka)
    case False{}: send_err_ka(sock, st, ka, 500, "wal_write_failed")


def post_pubs_wal(+name: String, +desc: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  +id : String = "p" ++ Nat.show(st_seq(st))
  +st2 : MedState = st_with_seq(st_with_db(st, Map.set(&2, String, st_db(st), pub_key(auth_tenant(a), id), pub_serialize(auth_kid(a), name, desc))), Nat.add(st_seq(st), 1n))
  +st3 : MedState = evt_emit(st2, auth_tenant(a), "pub.created", "{\"id\":\"" ++ json_esc(id) ++ "\"}")
  do IO<MedState>:
    # Single fsync'd write carries the publication, the new sequence number,
    # AND the commit event (EVT line).
    ok : Bool <- wal_setseq_evt(pub_key(auth_tenant(a), id), pub_serialize(auth_kid(a), name, desc), st_seq(st3), evt_head_opt(st_evlog(st3)))
    post_pubs_commit2(ok, id, sock, st, st3, ka)


def post_pubs_valid(ok: Bool, +name: String, +desc: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: post_pubs_wal(name, desc, a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 400, "invalid_name")


def post_pubs_create(+name: String, +desc: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  post_pubs_valid(valid_name(name), name, desc, a, sock, st, ka)


# --- claps ---

def clap_key(+tenant: String, +aid: String, +kid: String) -> String:
  "c:" ++ tenant ++ ":" ++ aid ++ ":" ++ kid


def post_clap_cur_go(mn: Maybe<&1, Nat>) -> Nat:
  match mn:
    case None{}: 0n
    case Some{n}: n


def post_clap_cur(+cur: String) -> Nat:
  post_clap_cur_go(parse_nat_opt(cur))


def post_clap_wal_ok2(ok: Bool, +total: Nat, +a: Auth, sock: Socket, +st: MedState, +st3: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: send_ok_wake(sock, st3, 200, "{\"total\":" ++ Nat.show(total) ++ "}", ka)
    case False{}: send_err_ka(sock, st, ka, 500, "wal_write_failed")


def post_clap_wal(+n: Nat, +a: Auth, sock: Socket, +st: MedState, +aid: String, +ka: Ka) -> IO(MedState):
  +ck : String = clap_key(auth_tenant(a), aid, auth_kid(a))
  +total : Nat = Nat.add(post_clap_cur(db_get(st_db(st), ck)), n)
  +st2 : MedState = st_with_db(st, Map.set(&2, String, st_db(st), ck, Nat.show(total)))
  +st3 : MedState = evt_emit(st2, auth_tenant(a), "article.clapped", "{\"id\":\"" ++ json_esc(aid) ++ "\",\"total\":" ++ Nat.show(total) ++ "}")
  do IO<MedState>:
    # Single fsync'd write carries the clap count AND the commit event (EVT
    # line). st3 (which holds the event) is kept only if the write succeeds,
    # so a failed WAL write leaves no event behind.
    ok : Bool <- wal_set_evt(ck, Nat.show(total), evt_head_opt(st_evlog(st3)))
    post_clap_wal_ok2(ok, total, a, sock, st, st3, ka)


# Item-114 fix (item-109 phantom class): a count=0 clap changes nothing
# (total+0 = total), so it must not emit an event, write WAL, or wake
# parked subscribers. post_clap_noop answers 200 with the current total via
# plain send_ok; post_clap_do_go dispatches after the 404 existence check.
def post_clap_noop(+a: Auth, sock: Socket, +st: MedState, +aid: String, +ka: Ka) -> IO(MedState):
  +total : Nat = post_clap_cur(db_get(st_db(st), clap_key(auth_tenant(a), aid, auth_kid(a))))
  send_ok_ka(sock, st, ka, 200, "{\"total\":" ++ Nat.show(total) ++ "}")


def post_clap_do_go(zero: Bool, +n: Nat, +a: Auth, sock: Socket, +st: MedState, +aid: String, +ka: Ka) -> IO(MedState):
  match zero:
    case True{}: post_clap_noop(a, sock, st, aid, ka)
    case False{}: post_clap_wal(n, a, sock, st, aid, ka)


def post_clap_exists(missing: Bool, +n: Nat, +a: Auth, sock: Socket, +st: MedState, +aid: String, +ka: Ka) -> IO(MedState):
  match missing:
    case True{}: send_err_ka(sock, st, ka, 404, "article_not_found")
    case False{}: post_clap_do_go(Nat.is_lt(n, 1n), n, a, sock, st, aid, ka)


def post_clap_do(+n: Nat, +a: Auth, sock: Socket, +st: MedState, +aid: String, +ka: Ka) -> IO(MedState):
  post_clap_exists(String.is_empty(db_get(st_db(st), article_key(auth_tenant(a), aid))), n, a, sock, st, aid, ka)


def post_clap_bounded(ok: Bool, +n: Nat, +a: Auth, sock: Socket, +st: MedState, +aid: String, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: post_clap_do(n, a, sock, st, aid, ka)
    case False{}: send_err_ka(sock, st, ka, 400, "count_too_large")


def post_clap_count_go(+n: Nat, +a: Auth, sock: Socket, +st: MedState, +aid: String, +ka: Ka) -> IO(MedState):
  post_clap_bounded(Nat.is_lt(n, 51n), n, a, sock, st, aid, ka)


def post_clap_count(mn: Maybe<&1, Nat>, +a: Auth, sock: Socket, +st: MedState, +aid: String, +ka: Ka) -> IO(MedState):
  match mn:
    case None{}: send_err_ka(sock, st, ka, 400, "invalid_count")
    case Some{n}: post_clap_count_go(n, a, sock, st, aid, ka)


# --- key management (admin only) ---

def post_keys_commit2(ok: Bool, +secret: String, +auth: Auth, sock: Socket, +st: MedState, +st_new: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: send_ok_ka(sock, st_new, ka, 201, "{\"kid\":\"" ++ json_esc(auth_kid(auth)) ++ "\",\"key\":\"" ++ json_esc(secret) ++ "\",\"tenant\":\"" ++ json_esc(auth_tenant(auth)) ++ "\",\"role\":\"" ++ json_esc(auth_role(auth)) ++ "\"}")
    case False{}: send_err_ka(sock, st, ka, 500, "wal_write_failed")


def mk_managed_auth(+kid: String, +secret: String, +tenant: String, +role: String) -> Auth:
  MkAuth{kid, verifier_of(secret), tenant, role, 0n, False{}}


def post_keys_gen2(+secret: String, +tenant: String, +role: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  +kid : String = "k_" ++ Nat.show(st_seq(st))
  +auth : Auth = mk_managed_auth(kid, secret, tenant, role)
  +st2 : MedState = st_with_seq(st_with_keys(st, Map.set(&2, Auth, st_keys(st), auth_key(auth), auth)), Nat.add(st_seq(st), 1n))
  do IO<MedState>:
    # Single fsync'd line carries the key record AND the new sequence number.
    ok : Bool <- wal_keyseq(auth, st_seq(st2))
    post_keys_commit2(ok, secret, auth, sock, st, st2, ka)


def post_keys_gen(+tenant: String, +role: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  do IO<MedState>:
    now : Nat <- IO.now()
    hex : String <- keygen_secure()
    post_keys_gen2(keygen_pick(hex, now, st_seq(st)), tenant, role, a, sock, st, ka)


def key_by_kid_go(+kvs: List<&2, Sigma<&2, &2, String, _ => Auth>>, +kid: String) -> Maybe<&1, Auth>:
  match kvs:
    case Nil{}: None{}
    case h <> t:
      (k, +av) = h
      Bool.pick(Maybe<&1, Auth>, String.eq(auth_kid(av), kid), Some{av}, key_by_kid_go(t, kid))


def key_by_kid(+keys: Map<&2, Auth>, +kid: String) -> Maybe<&1, Auth>:
  key_by_kid_go(Map.to_list(&2, Auth, keys), kid)


# Round 3 item 86: rotate must not resurrect revoked keys. Revocation is a
# terminal security control, but mk_rotated_auth cleared the revoked flag,
# so rotating a revoked kid silently reactivated it with a new secret.
# The active-only lookup makes rotate treat revoked kids as not found
# (404 key_not_found), exactly like kids that never existed. Revoke
# keeps the plain key_by_kid lookup (re-revoking stays idempotent 200).
def key_by_kid_active_go(+kvs: List<&2, Sigma<&2, &2, String, _ => Auth>>, +kid: String) -> Maybe<&1, Auth>:
  match kvs:
    case Nil{}: None{}
    case h <> t:
      (k, +av) = h
      Bool.pick(Maybe<&1, Auth>, Bool.and(String.eq(auth_kid(av), kid), Bool.not(auth_revoked(av))), Some{av}, key_by_kid_active_go(t, kid))


def key_by_kid_active(+keys: Map<&2, Auth>, +kid: String) -> Maybe<&1, Auth>:
  key_by_kid_active_go(Map.to_list(&2, Auth, keys), kid)


def post_keys_rotate_commit(+secret: String, +old: Auth, +new: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  +st2 : MedState = st_with_keys(st, Map.set(&2, Auth, Map.del(&2, Auth, st_keys(st), auth_key(old)), auth_key(new), new))
  send_ok_ka(sock, st2, ka, 200, "{\"kid\":\"" ++ json_esc(auth_kid(new)) ++ "\",\"key\":\"" ++ json_esc(secret) ++ "\"}")


def post_keys_rotate_wal_ok(ok: Bool, +secret: String, +old: Auth, +new: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: post_keys_rotate_commit(secret, old, new, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 500, "wal_write_failed")


def mk_rotated_auth(+old: Auth, +secret: String) -> Auth:
  MkAuth{auth_kid(old), verifier_of(secret), auth_tenant(old), auth_role(old), auth_expires(old), False{}}


def post_keys_rotate_gen2(+secret: String, +old: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  +new : Auth = mk_rotated_auth(old, secret)
  do IO<MedState>:
    ok : Bool <- wal_keyrot(auth_key(old), new)
    post_keys_rotate_wal_ok(ok, secret, old, new, sock, st, ka)


def post_keys_rotate_gen(+old: Auth, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  do IO<MedState>:
    now : Nat <- IO.now()
    hex : String <- keygen_secure()
    post_keys_rotate_gen2(keygen_pick(hex, now, st_seq(st)), old, sock, st, ka)


def post_keys_revoke_commit(+new: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  +st2 : MedState = st_with_keys(st, Map.set(&2, Auth, st_keys(st), auth_key(new), new))
  send_ok_ka(sock, st2, ka, 200, "{\"kid\":\"" ++ json_esc(auth_kid(new)) ++ "\",\"revoked\":true}")


def post_keys_revoke_wal_ok(ok: Bool, +new: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: post_keys_revoke_commit(new, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 500, "wal_write_failed")


def mk_revoked_auth(+old: Auth) -> Auth:
  MkAuth{auth_kid(old), auth_key(old), auth_tenant(old), auth_role(old), auth_expires(old), True{}}


def post_keys_revoke_do(+old: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  +new : Auth = mk_revoked_auth(old)
  do IO<MedState>:
    ok : Bool <- wal_key(new)
    post_keys_revoke_wal_ok(ok, new, sock, st, ka)


def auth_to_json(+a: Auth) -> String:
  "{\"kid\":\"" ++ json_esc(auth_kid(a)) ++ "\",\"tenant\":\"" ++ json_esc(auth_tenant(a)) ++ "\",\"role\":\"" ++ json_esc(auth_role(a)) ++ "\",\"revoked\":" ++ jbool(auth_revoked(a)) ++ "}"


def key_list_go(+kvs: List<&2, Sigma<&2, &2, String, _ => Auth>>, +tenant: String, +acc: List<&2, String>) -> List<&2, String>:
  match kvs:
    case Nil{}: acc
    case h <> t:
      (k, +av) = h
      key_list_go(t, tenant, Bool.pick(List<&2, String>, String.eq(auth_tenant(av), tenant), auth_to_json(av) <> acc, acc))


def get_keys_list2(+kvs: List<&2, Sigma<&2, &2, String, _ => Auth>>, +tenant: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  send_ok_ka(sock, st, ka, 200, "{\"keys\":[" ++ join_str(key_list_go(kvs, tenant, Nil{}), ",") ++ "]}")


def get_keys_list(+a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  get_keys_list2(Map.to_list(&2, Auth, st_keys(st)), auth_tenant(a), sock, st, ka)


# --- events endpoint ---

def get_events_park2(+ch: Chan(Socket), +cursor: Nat, +a: Auth, sock: Socket, +st: MedState, +now: Nat, +ka: Ka) -> IO(MedState):
  do IO<MedState>:
    _b : Bool <- Chan.send(Socket, ch, sock)
    _p : Unit <- ka_park_close(ka)
    IO.pure(MedState, pend_add(st, MkPend{ch, auth_tenant(a), cursor, now}))


def get_events_park_go(tenant_ok: Bool, global_ok: Bool, +st: MedState, +cursor: Nat, +a: Auth, sock: Socket, +now: Nat, +ka: Ka) -> IO(MedState):
  match tenant_ok:
    case True{}:
      match global_ok:
        case True{}:
          do IO<MedState>:
            ch : Chan(Socket) <- Chan.new(Socket, 1)
            get_events_park2(ch, cursor, a, sock, st, now, ka)
        case False{}: send_err_ka(sock, st, ka, 503, "too_many_subscribers")
    case False{}: send_err_ka(sock, st, ka, 503, "too_many_subscribers_tenant")


def get_events_park_checked(+st: MedState, +cursor: Nat, +a: Auth, sock: Socket, +now: Nat, +ka: Ka) -> IO(MedState):
  get_events_park_go(Nat.is_lt(pend_len(pend_for_tenant(st_pend(st), auth_tenant(a))), pend_cap_tenant()), Nat.is_lt(pend_len(st_pend(st)), pend_cap()), st, cursor, a, sock, now, ka)


def get_events_park_expired(kept: List<&2, PendSub> & List<&2, PendSub>, +st: MedState, +cursor: Nat, +a: Auth, sock: Socket, +now: Nat, +ka: Ka) -> IO(MedState):
  match kept:
    case (keep, expired):
      do IO<MedState>:
        st2 : MedState <- close_expired_go(expired, st_with_pend(st, keep))
        get_events_park_checked(st2, cursor, a, sock, now, ka)


def get_events_park(+cursor: Nat, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  do IO<MedState>:
    +now : Nat <- IO.now()
    get_events_park_expired(pend_expire_collect(st_pend(st), now, Nil{}, Nil{}), st, cursor, a, sock, now, ka)


# A fully-evicted poll (empty filter, cursor older than the ring floor) must NOT
# park: the client would hang until a lazy 25s expiry sweep and never learn it
# was truncated (item 162). Return the truncation signal immediately instead;
# the client advances its cursor to the ring max and resumes normal long-poll.
# Fresh cursors (cursor >= floor) still park.
def get_events_send_empty(truncated: Bool, +cursor: Nat, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match truncated:
    case True{}: send_ok_ka(sock, st, ka, 200, "{\"events\":[],\"cursor\":" ++ Nat.show(evt_max_seq(st_evlog(st), cursor)) ++ ",\"truncated\":true}")
    case False{}: get_events_park(cursor, a, sock, st, ka)


def get_events_send(+evs: List<&2, String>, +cursor: Nat, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match evs:
    case Nil{}: get_events_send_empty(Nat.is_lt(cursor, evt_oldest_seq(st_evlog(st))), cursor, a, sock, st, ka)
    case _ <> _: send_ok_ka(sock, st, ka, 200, "{\"events\":[" ++ join_str(evs, ",") ++ "],\"cursor\":" ++ Nat.show(evt_max_seq(st_evlog(st), cursor)) ++ evt_trunc_flag(st_evlog(st), cursor) ++ "}")


def get_events_at(+cursor: Nat, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  get_events_send(evt_filter(st_evlog(st), auth_tenant(a), cursor), cursor, a, sock, st, ka)


# --- subscriber wakeup (called after mutations emit events) ---

# --- explicit auth-gated entry points ---
# Ordered leaf-first (Bend requires defs to precede use).

def g_post_users_body(mname: Maybe<&1, String>, mbio: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match mname:
    case None{}: send_err_ka(sock, st, ka, 400, "missing_name")
    case Some{name}:
      match mbio:
        case None{}: post_users_create(name, "", a, sock, st, ka)
        case Some{bio}: post_users_create(name, bio, a, sock, st, ka)


def g_post_users_role(ok: Bool, +a: Auth, sock: Socket, +st: MedState, +body: String, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: g_post_users_body(jf_field(body, "name"), jf_field(body, "bio"), a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 403, "forbidden")


def g_post_users_go(+a: Auth, sock: Socket, +st: MedState, +body: String, +ka: Ka) -> IO(MedState):
  g_post_users_role(is_member(a), a, sock, st, body, ka)


def g_post_users(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +body: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: g_post_users_go(a, sock, st, body, ka)


def g_get_user(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +id: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: get_user(a, sock, st, id, ka)


def g_post_articles_body(mtitle: Maybe<&1, String>, mbody: Maybe<&1, String>, mpub: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match mtitle:
    case None{}: send_err_ka(sock, st, ka, 400, "missing_title")
    case Some{title}:
      match mbody:
        case None{}: send_err_ka(sock, st, ka, 400, "missing_body")
        case Some{tbody}:
          match mpub:
            case None{}: post_articles_create(title, tbody, "", a, sock, st, ka)
            case Some{pub}: post_articles_create(title, tbody, pub, a, sock, st, ka)


def g_post_articles_role(ok: Bool, +a: Auth, sock: Socket, +st: MedState, +body: String, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: g_post_articles_body(jf_field(body, "title"), jf_field(body, "body"), jf_field(body, "pub"), a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 403, "forbidden")


def g_post_articles_go(+a: Auth, sock: Socket, +st: MedState, +body: String, +ka: Ka) -> IO(MedState):
  g_post_articles_role(is_member(a), a, sock, st, body, ka)


def g_post_articles(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +body: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: g_post_articles_go(a, sock, st, body, ka)


def g_get_article(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +id: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: get_article(a, sock, st, id, ka)


def g_get_pub(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +id: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: get_pub(a, sock, st, id, ka)


def g_get_keys_go(+a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  get_keys_list(a, sock, st, ka)


def g_get_keys_role(ok: Bool, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: g_get_keys_go(a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 403, "forbidden")


def g_get_keys_go2(+a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  g_get_keys_role(is_admin(a), a, sock, st, ka)


def g_get_keys(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: g_get_keys_go2(a, sock, st, ka)


def g_post_pubs_body(mname: Maybe<&1, String>, mdesc: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match mname:
    case None{}: send_err_ka(sock, st, ka, 400, "missing_name")
    case Some{name}:
      match mdesc:
        case None{}: post_pubs_create(name, "", a, sock, st, ka)
        case Some{desc}: post_pubs_create(name, desc, a, sock, st, ka)


def g_post_pubs_role(ok: Bool, +a: Auth, sock: Socket, +st: MedState, +body: String, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: g_post_pubs_body(jf_field(body, "name"), jf_field(body, "desc"), a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 403, "forbidden")


def g_post_pubs_go(+a: Auth, sock: Socket, +st: MedState, +body: String, +ka: Ka) -> IO(MedState):
  g_post_pubs_role(is_member(a), a, sock, st, body, ka)


def g_post_pubs(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +body: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: g_post_pubs_go(a, sock, st, body, ka)



def post_pm_wal_ok(ok: Bool, sock: Socket, +st: MedState, +st3: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: send_ok_wake(sock, st3, 200, "{\"ok\":true}", ka)
    case False{}: send_err_ka(sock, st, ka, 500, "wal_write_failed")


def pm_evt_name(is_new: Bool) -> String:
  match is_new:
    case True{}: "pub.member.added"
    case False{}: "pub.member.updated"

# Item 109: an identical re-add (kid already holds exactly this role) is a
# state no-op -> idempotent 200 {"ok":true} with NO event, NO WAL write, and
# NO parked-subscriber wake. (Item-105-class phantom: the old code ran the
# changed path unconditionally, evt_emit'ing pub.member.updated +
# wal_set_evt and waking parked subs with a no-change event.)
def post_pm_commit_noop(sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  send_ok_ka(sock, st, ka, 200, "{\"ok\":true}")


def post_pm_commit_changed(+tenant: String, +pid: String, +kid: String, +role: String, +old: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  +st2 : MedState = st_with_db(st, Map.set(&2, String, st_db(st), pm_key(tenant, pid, kid), role))
  +st3 : MedState = evt_emit(st2, tenant, pm_evt_name(String.is_empty(old)), "{\"pub\":\"" ++ json_esc(pid) ++ "\",\"kid\":\"" ++ json_esc(kid) ++ "\",\"role\":\"" ++ json_esc(role) ++ "\"}")
  do IO<MedState>:
    # Single fsync'd line carries the membership record AND its commit
    # event (SETV record): no crash window can leave a durable membership
    # without its event or vice versa. Parked subscribers are woken.
    ok : Bool <- wal_set_evt(pm_key(tenant, pid, kid), role, evt_head_opt(st_evlog(st3)))
    post_pm_wal_ok(ok, sock, st, st3, ka)


def post_pm_commit_same(same: Bool, +tenant: String, +pid: String, +kid: String, +role: String, +old: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match same:
    case True{}: post_pm_commit_noop(sock, st, ka)
    case False{}: post_pm_commit_changed(tenant, pid, kid, role, old, sock, st, ka)


def post_pm_commit(+tenant: String, +pid: String, +kid: String, +role: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  +old : String = db_get(st_db(st), pm_key(tenant, pid, kid))
  post_pm_commit_same(String.eq(old, role), tenant, pid, kid, role, old, sock, st, ka)


def post_pm_manage(can: Bool, +tenant: String, +pid: String, +kid: String, +role: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match can:
    case True{}: post_pm_commit(tenant, pid, kid, role, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 403, "forbidden")


def post_pm_role_ok(ok: Bool, +a: Auth, +pid: String, +kid: String, +role: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: post_pm_manage(can_manage_pub(a, st, pid), auth_tenant(a), pid, kid, role, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 400, "invalid_role")


def post_pm_tenant_ok(ok: Bool, +a: Auth, +pid: String, +kid: String, +role: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: post_pm_role_ok(valid_pm_role(role), a, pid, kid, role, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 404, "unknown_key")


def post_pm_key_check(mt: Maybe<&1, Auth>, +a: Auth, +pid: String, +kid: String, +role: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match mt:
    case None{}: send_err_ka(sock, st, ka, 404, "unknown_key")
    case Some{t}: post_pm_tenant_ok(String.eq(auth_tenant(t), auth_tenant(a)), a, pid, kid, role, sock, st, ka)


def post_pm_pub_exists(exists: Bool, +a: Auth, +pid: String, +kid: String, +role: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match exists:
    case True{}: post_pm_key_check(key_by_kid(st_keys(st), kid), a, pid, kid, role, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 404, "pub_not_found")


def post_pm_fields(mkid: Maybe<&1, String>, mrole: Maybe<&1, String>, +a: Auth, +pid: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match mkid:
    case None{}: send_err_ka(sock, st, ka, 400, "missing_kid")
    case Some{kid}:
      match mrole:
        case None{}: send_err_ka(sock, st, ka, 400, "missing_role")
        case Some{role}: post_pm_pub_exists(db_has(st_db(st), pub_key(auth_tenant(a), pid)), a, pid, kid, role, sock, st, ka)


def g_post_pm_go(+a: Auth, sock: Socket, +st: MedState, +pid: String, +body: String, +ka: Ka) -> IO(MedState):
  post_pm_fields(jf_field(body, "kid"), jf_field(body, "role"), a, pid, sock, st, ka)


def g_post_pm(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +pid: String, +body: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: g_post_pm_go(a, sock, st, pid, body, ka)


def delete_pm_wal_ok(ok: Bool, sock: Socket, +st: MedState, +st3: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: send_ok_wake(sock, st3, 200, "{\"ok\":true}", ka)
    case False{}: send_err_ka(sock, st, ka, 500, "wal_write_failed")


def delete_pm_commit(+tenant: String, +pid: String, +kid: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  +st2 : MedState = st_with_db(st, Map.del(&2, String, st_db(st), pm_key(tenant, pid, kid)))
  +st3 : MedState = evt_emit(st2, tenant, "pub.member.removed", "{\"pub\":\"" ++ json_esc(pid) ++ "\",\"kid\":\"" ++ json_esc(kid) ++ "\"}")
  do IO<MedState>:
    # Single fsync'd line carries the membership deletion AND its commit
    # event (DELV record). Parked subscribers are woken.
    ok : Bool <- wal_del_evt(pm_key(tenant, pid, kid), evt_head_opt(st_evlog(st3)))
    delete_pm_wal_ok(ok, sock, st, st3, ka)


# Round 3 item 105: deleting a non-member must not emit a phantom event.
# delete_pm_commit used to fire pub.member.removed unconditionally whenever the
# caller could manage the pub; Map.del on a missing key is a state no-op, but
# evt_emit still wrote a DELV + pub.member.removed pair to WAL, so a repeated
# DELETE minted duplicate removed events (and burned a seq) for a membership
# that never existed. Now membership is checked first: 404 member_not_found,
# no event, no WAL write.
def delete_pm_member_exists(exists: Bool, +tenant: String, +pid: String, +kid: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match exists:
    case True{}: delete_pm_commit(tenant, pid, kid, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 404, "member_not_found")

def delete_pm_can_manage(can: Bool, +a: Auth, +pid: String, +kid: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match can:
    case True{}: delete_pm_member_exists(db_has(st_db(st), pm_key(auth_tenant(a), pid, kid)), auth_tenant(a), pid, kid, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 403, "forbidden")


def delete_pm_pub_exists(exists: Bool, +a: Auth, +pid: String, +kid: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match exists:
    case True{}: delete_pm_can_manage(can_manage_pub(a, st, pid), a, pid, kid, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 404, "pub_not_found")

def g_delete_pm_go(+a: Auth, sock: Socket, +st: MedState, +pid: String, +kid: String, +ka: Ka) -> IO(MedState):
  delete_pm_pub_exists(db_has(st_db(st), pub_key(auth_tenant(a), pid)), a, pid, kid, sock, st, ka)


def g_delete_pm_auth(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +pid: String, +kid: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: g_delete_pm_go(a, sock, st, pid, kid, ka)


def g_delete_pm(+headers: Map<&2, String>, sock: Socket, +st: MedState, +pid: String, +kid: String, +ka: Ka) -> IO(MedState):
  do IO<MedState>:
    ma : Maybe<&1, Auth> <- auth_of(headers, st)
    g_delete_pm_auth(ma, sock, st, pid, kid, ka)


def pm_json(+k: String, +v: String, +prefix: String) -> String:
  "{\"kid\":\"" ++ json_esc(String.drop(k, String.length(prefix))) ++ "\",\"role\":\"" ++ json_esc(v) ++ "\"}"


def pm_list_go(+kvs: List<&2, Sigma<&2, &2, String, _ => String>>, +prefix: String, +acc: List<&2, String>) -> List<&2, String>:
  match kvs:
    case Nil{}: acc
    case h <> t:
      (k, v) = h
      pm_list_go(t, prefix, Bool.pick(List<&2, String>, String.starts_with(k, prefix), pm_json(k, v, prefix) <> acc, acc))


# Member-list visibility policy (Round 2 item 9): any authenticated user of
# the tenant may list members of an existing publication in the same tenant.
# Cross-tenant listing is impossible by construction (all keys are
# tenant-prefixed, so another tenant's pub id resolves to nothing here);
# a nonexistent publication returns 404 rather than an empty list.
def g_get_pm_list2(missing: Bool, +a: Auth, sock: Socket, +st: MedState, +pid: String, +ka: Ka) -> IO(MedState):
  match missing:
    case True{}: send_err_ka(sock, st, ka, 404, "pub_not_found")
    case False{}:
      send_ok_ka(sock, st, ka, 200, "{\"members\":[" ++ join_str(pm_list_go(Map.to_list(&2, String, st_db(st)), "pm:" ++ auth_tenant(a) ++ ":" ++ pid ++ ":", Nil{}), ",") ++ "]}")

def g_get_pm_list(+a: Auth, sock: Socket, +st: MedState, +pid: String, +ka: Ka) -> IO(MedState):
  g_get_pm_list2(String.is_empty(db_get(st_db(st), pub_key(auth_tenant(a), pid))), a, sock, st, pid, ka)


def g_get_pm(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +pid: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: g_get_pm_list(a, sock, st, pid, ka)


def g_post_clap_body(mcount: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +aid: String, +ka: Ka) -> IO(MedState):
  match mcount:
    case None{}: post_clap_do(1n, a, sock, st, aid, ka)
    case Some{cs}: post_clap_count(parse_nat_opt(cs), a, sock, st, aid, ka)


# Item 31: the clap path accepted structurally-invalid bodies that every
# other endpoint rejects. jf_field_any applies the item-26 jf_body_closed
# gate (None on unclosed), but here None meant "default to 1 clap", so
# {"count":3 (unclosed) silently became +1 instead of 400ing. A non-blank
# body that is not closed is now 400 invalid_body; blank bodies keep the
# default-1 behavior; closed bodies are unchanged. Item 33: the gate is
# jf_body_ok (also rejects trailing commas before the final '}').
def g_post_clap_blank(blank: Bool, +a: Auth, sock: Socket, +st: MedState, +aid: String, +ka: Ka) -> IO(MedState):
  match blank:
    case True{}: g_post_clap_body(None{}, a, sock, st, aid, ka)
    case False{}: send_err_ka(sock, st, ka, 400, "invalid_body")

def g_post_clap_closed(closed: Bool, blank: Bool, +a: Auth, sock: Socket, +st: MedState, +aid: String, +body: String, +ka: Ka) -> IO(MedState):
  match closed:
    case True{}: g_post_clap_body(jf_field_any(body, "count"), a, sock, st, aid, ka)
    case False{}: g_post_clap_blank(blank, a, sock, st, aid, ka)


# Item 33: this gate is now jf_body_ok (item-26 jf_body_closed PLUS the
# item-33 no-trailing-comma check), so {"count":3,} is 400 invalid_body here
# too; blank-body default-+1 behavior unchanged.
def g_post_clap_role(ok: Bool, +a: Auth, sock: Socket, +st: MedState, +aid: String, +body: String, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: g_post_clap_closed(jf_body_ok(body), String.is_empty(String.trim(body)), a, sock, st, aid, body, ka)
    case False{}: send_err_ka(sock, st, ka, 403, "forbidden")


def g_post_clap_go(+a: Auth, sock: Socket, +st: MedState, +aid: String, +body: String, +ka: Ka) -> IO(MedState):
  g_post_clap_role(is_member(a), a, sock, st, aid, body, ka)


def g_post_clap(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +aid: String, +body: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: g_post_clap_go(a, sock, st, aid, body, ka)


def g_post_keys_valid(ok: Bool, +tenant: String, +role: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: post_keys_gen(tenant, role, a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 400, "invalid_role")


def g_post_keys_valid_go(+tenant: String, +role: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  g_post_keys_valid(valid_role(role), tenant, role, a, sock, st, ka)


# Tenant scoping for key management (Round 2 item 9): the bootstrap admin
# (tenant "root") is the tenant-provisioning path and may mint keys in any
# tenant; every other admin is confined to its own tenant. Tenant names are
# validated so tabs/newlines cannot corrupt the tab-separated WAL records.
def is_root_admin(+a: Auth) -> Bool:
  String.eq(auth_tenant(a), "root")

def g_post_keys_tenant_ok(ok: Bool, +tenant: String, +role: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: g_post_keys_valid_go(tenant, role, a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 403, "cross_tenant")

def g_post_keys_tenant(+tenant: String, +role: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  g_post_keys_tenant_ok(Bool.or(is_root_admin(a), String.eq(tenant, auth_tenant(a))), tenant, role, a, sock, st, ka)

def g_post_keys_tenant_valid(ok: Bool, +tenant: String, +role: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: g_post_keys_tenant(tenant, role, a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 400, "invalid_tenant")

def g_post_keys_tenant_valid_go(+tenant: String, +role: String, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  g_post_keys_tenant_valid(valid_tenant(tenant), tenant, role, a, sock, st, ka)

def g_post_keys_body(mtenant: Maybe<&1, String>, mrole: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match mtenant:
    case None{}: send_err_ka(sock, st, ka, 400, "missing_tenant")
    case Some{tenant}:
      match mrole:
        case None{}: send_err_ka(sock, st, ka, 400, "missing_role")
        case Some{role}: g_post_keys_tenant_valid_go(tenant, role, a, sock, st, ka)


def g_post_keys_role(ok: Bool, +a: Auth, sock: Socket, +st: MedState, +body: String, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: g_post_keys_body(jf_field(body, "tenant"), jf_field(body, "role"), a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 403, "forbidden")


def g_post_keys_go(+a: Auth, sock: Socket, +st: MedState, +body: String, +ka: Ka) -> IO(MedState):
  g_post_keys_role(is_admin(a), a, sock, st, body, ka)


def g_post_keys(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +body: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: g_post_keys_go(a, sock, st, body, ka)


def g_rotate_tenant_ok(ok: Bool, +old: Auth, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: post_keys_rotate_gen(old, a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 404, "key_not_found")

def g_rotate_tenant(+old: Auth, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  g_rotate_tenant_ok(Bool.or(is_root_admin(a), String.eq(auth_tenant(old), auth_tenant(a))), old, a, sock, st, ka)

def g_rotate_go(mk: Maybe<&1, Auth>, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match mk:
    case None{}: send_err_ka(sock, st, ka, 404, "key_not_found")
    case Some{old}: g_rotate_tenant(old, a, sock, st, ka)


def g_rotate_role(ok: Bool, +a: Auth, sock: Socket, +st: MedState, +kid: String, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: g_rotate_go(key_by_kid_active(st_keys(st), kid), a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 403, "forbidden")


def g_rotate_go2(+a: Auth, sock: Socket, +st: MedState, +kid: String, +ka: Ka) -> IO(MedState):
  g_rotate_role(is_admin(a), a, sock, st, kid, ka)


def g_rotate(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +kid: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: g_rotate_go2(a, sock, st, kid, ka)


def g_revoke_tenant_ok(ok: Bool, +old: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: post_keys_revoke_do(old, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 404, "key_not_found")

def g_revoke_tenant(+old: Auth, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  g_revoke_tenant_ok(Bool.or(is_root_admin(a), String.eq(auth_tenant(old), auth_tenant(a))), old, sock, st, ka)

def g_revoke_go(mk: Maybe<&1, Auth>, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match mk:
    case None{}: send_err_ka(sock, st, ka, 404, "key_not_found")
    case Some{old}: g_revoke_tenant(old, a, sock, st, ka)


def g_revoke_role(ok: Bool, +a: Auth, sock: Socket, +st: MedState, +kid: String, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: g_revoke_go(key_by_kid(st_keys(st), kid), a, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 403, "forbidden")


def g_revoke_go2(+a: Auth, sock: Socket, +st: MedState, +kid: String, +ka: Ka) -> IO(MedState):
  g_revoke_role(is_admin(a), a, sock, st, kid, ka)


def g_revoke(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +kid: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: g_revoke_go2(a, sock, st, kid, ka)


def q_cursor(+q: String) -> Maybe<&1, String>:
  q_val(q, "cursor")


def g_events_go(mcursor: Maybe<&1, Nat>, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match mcursor:
    case None{}: get_events_at(0n, a, sock, st, ka)
    case Some{c}: get_events_at(c, a, sock, st, ka)


def g_events_go2(mcs: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match mcs:
    case None{}: get_events_at(0n, a, sock, st, ka)
    case Some{cs}: g_events_go(parse_nat_opt(cs), a, sock, st, ka)


def g_events(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +query: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: g_events_go2(q_cursor(query), a, sock, st, ka)


# --- graceful restart control (Round 3 item 19, admin only) ---
# Schedules a graceful restart: the owner drains in-flight requests, writes
# a final snapshot, and the process exits 0 (a supervisor restarts it; WAL
# replay + snapshot make the restart fast and lossless). Responds 202 to the
# caller first — the restart happens after this response is flushed.
#
# Restart waker: after this handler sets the flag and returns 202, the owner
# parks in Chan.recv and would never observe the flag. A loopback GET
# /health (cheap, unauthenticated) unparks it; the next loop iteration sees
# st_restart and shuts down. The response is discarded; the handler's write
# to the closed socket is harmless.
def restart_waker_sent(sr: Socket & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (sock, _r) = sr
  do IO<Unit>:
    _c : Unit <- Socket.close(sock)
    IO.pure(Unit, Unit{})

def restart_waker_send(sock: Socket) -> IO(Unit):
  do IO<Unit>:
    sr : Socket & Result<&1, &1, U32 & String, Unit> <- Net.send_timeout(sock, "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", 5000)
    restart_waker_sent(sr)

def restart_waker_got(cr: Result<&1, &1, U32 & String, Socket>) -> IO(Unit):
  match cr:
    case Fail{_e}: IO.pure(Unit, Unit{})
    case Done{sock}: restart_waker_send(sock)

def restart_waker() -> IO(Unit):
  do IO<Unit>:
    cr : Result<&1, &1, U32 & String, Socket> <- TCP.connect("127.0.0.1", 18081)
    restart_waker_got(cr)

# Override a Ka to force connection close (e.g., server is restarting).
# The backch is preserved so the handler's recv gets None (closed) instead
# of blocking forever (item 183 deadlock fix).
def ka_close(+ka: Ka) -> Ka:
  match ka:
    case Ka{want, backch}: Ka{False{}, backch}

def g_restart_go(ok: Bool, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}:
      do IO<MedState>:
        # Restart always closes the connection: override keep-alive want to
        # False so the handler's backch is closed and it does not park
        # waiting for a socket that will never come (item 183 deadlock fix).
        st2 : MedState <- send_ok_ka(sock, st_with_restart(st, True{}), ka_close(ka), 202, "{\"status\":\"restart_scheduled\"}")
        _u : Unit <- IO.spawn(Unit, restart_waker())
        IO.pure(MedState, st2)
    case False{}: send_err_ka(sock, st, ka, 403, "forbidden")

def g_restart(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: g_restart_go(is_admin(a), sock, st, ka)


# --- endpoint registry (single source of truth for /help, /schema AND routing) ---
# If you add a route, add it here; help_json/schema_json derive from this, and
# route(ka) dispatches through it. `hid` selects the handler in route_dispatch;
# `prefix` must stay False on every route (item 18 fix): all routes match by
# exact segment count; non-empty trailing segments 404. The old prefix mode
# (True = extra trailing segments ignored) was a bug — it silently served
# wrong resources on unregistered paths. Bare trailing slash still normalizes
# because path_segs drops empty segments.

type RouteDef is Data:
  MkRoute{method: String, path: String, auth: Bool, desc: String, hid: Nat, prefix: Bool}


def route_method(+r: RouteDef) -> String:
  match r:
    case MkRoute{method, path, auth, desc, hid, prefix}: method


def route_path(+r: RouteDef) -> String:
  match r:
    case MkRoute{method, path, auth, desc, hid, prefix}: path


def route_auth(+r: RouteDef) -> Bool:
  match r:
    case MkRoute{method, path, auth, desc, hid, prefix}: auth


def route_desc(+r: RouteDef) -> String:
  match r:
    case MkRoute{method, path, auth, desc, hid, prefix}: desc


def route_hid(+r: RouteDef) -> Nat:
  match r:
    case MkRoute{method, path, auth, desc, hid, prefix}: hid


def route_prefix(+r: RouteDef) -> Bool:
  match r:
    case MkRoute{method, path, auth, desc, hid, prefix}: prefix


# =====================================================================
# MCP workstream (2026-09-29): MCP Streamable HTTP mini-CMS/blog.
# POST /mcp speaks JSON-RPC 2.0 over the existing Bearer auth:
#   initialize, notifications/initialized, tools/list, tools/call
# with seven blog_* tools. Posts reuse the map/WAL/snapshot store
# ("bp:<tenant>:<id>" keys, tab-separated values); every mutation is
# WAL-persisted before it is acknowledged. Additive: no existing
# route, helper, or behavior was changed.
# NOTE (Bend 2.0.32): defs are ordered callees-before-callers (no
# forward references, no mutual recursion); each loop is a single
# self-recursive def.
# =====================================================================

# --- leaf predicates ---

def mcp_is_open(+u: U32) -> Bool:
  Bool.or(U32.is_eq(u, 123), U32.is_eq(u, 91))

def mcp_is_close(+u: U32) -> Bool:
  Bool.or(U32.is_eq(u, 125), U32.is_eq(u, 93))

def mcp_is_quote(+u: U32) -> Bool:
  U32.is_eq(u, 34)

def mcp_is_bs(+u: U32) -> Bool:
  U32.is_eq(u, 92)

def mcp_nil() -> List<&2, Char>:
  Nil{}

def mcp_nil_str() -> List<&2, String>:
  Nil{}

# tag charset: alnum + space/dash/underscore (tabs/control chars would
# corrupt the tab-separated record; quotes/backslashes would break the
# stored JSON array)
def mcp_tag_char(+u: U32) -> Bool:
  Bool.or(is_alnum(u), Bool.or(U32.is_eq(u, 32), Bool.or(U32.is_eq(u, 45), U32.is_eq(u, 95))))

def mcp_is_tws(+u: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(u, 32), U32.is_eq(u, 9)), Bool.or(U32.is_eq(u, 10), U32.is_eq(u, 13)))

def mcp_status_ok(+s: String) -> Bool:
  Bool.or(String.eq(s, "all"), Bool.or(String.eq(s, "draft"), String.eq(s, "published")))

# --- JSON-RPC plumbing ---

# Echo the request id preserving its JSON type: quoted strings stay
# quoted, raw tokens (numbers, true/false/null) pass through, a missing
# id becomes null.
def mcp_id_any(mi: Maybe<&1, String>) -> String:
  match mi:
    case None{}: "null"
    case Some{t}: t

def mcp_id_json_go(mid: Maybe<&1, String>, +body: String) -> String:
  match mid:
    case Some{s}: jstr(s)
    case None{}: mcp_id_any(jf_field_any(body, "id"))

def mcp_id_json(+body: String) -> String:
  mcp_id_json_go(jf_field(body, "id"), body)

def mcp_ok(+idj: String, +result: String) -> String:
  "{\"jsonrpc\":\"2.0\",\"id\":" ++ idj ++ ",\"result\":" ++ result ++ "}"

# code is the magnitude; JSON-RPC error codes are negative.
def mcp_err(+idj: String, +code: String, +msg: String) -> String:
  "{\"jsonrpc\":\"2.0\",\"id\":" ++ idj ++ ",\"error\":{\"code\":-" ++ code ++ ",\"message\":" ++ jstr(msg) ++ "}}"

def mcp_tool_ok(+text: String) -> String:
  "{\"content\":[{\"type\":\"text\",\"text\":" ++ jstr(text) ++ "}],\"isError\":false}"

def mcp_tool_err(+text: String) -> String:
  "{\"content\":[{\"type\":\"text\",\"text\":" ++ jstr(text) ++ "}],\"isError\":true}"

# --- balanced {...} / [...] capture (string-aware, LINEAR) ---
# Captures the balanced value of a top-level key, brackets included, so
# a nested object (e.g. params.arguments) can be searched at depth 1
# with jf_field. stt: 0 = normal, 1 = in string, 2 = escape.
# { and [ share one depth counter, sound for well-formed JSON.
#
# LINEARITY (native hang fix, 2026-09-29): Bend evaluates function
# arguments strictly, so a Bool.pick with recursive calls in two or
# more branches evaluates ALL of them (3^n blowup here -> the
# tools/call hang). The rule, matching jf_scan/jf_skip_ws: a
# single self-recursive def where each step computes the next state
# with PURE (non-recursive) helpers and issues EXACTLY ONE recursive
# call; every other branch is a cheap terminal. mcp_bal_go below does
# O(1) work per char -> O(n) total.

# char class: 0=open({[), 1=close(}]), 2=quote, 3=backslash, 4=other
def mcp_cls(+u: U32) -> Nat:
  Bool.pick(Nat, mcp_is_open(u), 0n,
    Bool.pick(Nat, mcp_is_close(u), 1n,
      Bool.pick(Nat, mcp_is_quote(u), 2n,
        Bool.pick(Nat, mcp_is_bs(u), 3n, 4n))))

# capture is done: close bracket at depth 1 outside strings
def mcp_bal_done(+cls: Nat, +stt: Nat, +depth: Nat) -> Bool:
  Bool.and(Bool.and(Nat.is_eq(cls, 1n), Nat.is_eq(stt, 0n)), Nat.is_eq(depth, 1n))

# next depth: open outside strings deepens; close outside strings
# shallows (the depth-1 close never recurses: it is "done" above, so
# Nat.sub can never underflow here; Bend Nat.sub truncates anyway)
def mcp_bal_depth(+cls: Nat, +stt: Nat, +depth: Nat) -> Nat:
  Bool.pick(Nat, Bool.and(Nat.is_eq(cls, 0n), Nat.is_eq(stt, 0n)), Nat.add(depth, 1n),
    Bool.pick(Nat, Bool.and(Nat.is_eq(cls, 1n), Nat.is_eq(stt, 0n)), Nat.sub(depth, 1n),
      depth))

# next string state
def mcp_bal_stt(+cls: Nat, +stt: Nat) -> Nat:
  Bool.pick(Nat, Bool.and(Nat.is_eq(stt, 0n), Nat.is_eq(cls, 2n)), 1n,
    Bool.pick(Nat, Bool.and(Nat.is_eq(stt, 1n), Nat.is_eq(cls, 2n)), 0n,
      Bool.pick(Nat, Bool.and(Nat.is_eq(stt, 1n), Nat.is_eq(cls, 3n)), 2n,
        Bool.pick(Nat, Nat.is_eq(stt, 2n), 1n, stt))))

# Returns the captured chars REVERSED (one List.reverse at the single
# caller); the Some branch is an O(1) cons, keeping every level O(1).
def mcp_bal_go(+cs: List<&2, Char>, +depth: Nat, +stt: Nat, +acc: List<&2, Char>) -> Maybe<&1, List<&2, Char>>:
  match cs:
    case Nil{}: None{}
    case h <> t:
      +cls : Nat = mcp_cls(Char.to_u32(h))
      +d2 : Nat = mcp_bal_depth(cls, stt, depth)
      +s2 : Nat = mcp_bal_stt(cls, stt)
      Bool.pick(Maybe<&1, List<&2, Char>>, mcp_bal_done(cls, stt, depth),
        Some{h <> acc},
        mcp_bal_go(t, d2, s2, h <> acc))

# chars after the colon of a top-level "key" (whitespace-skipped)
def mcp_colon_chars(+body: String, +key: String, +p: Nat) -> Maybe<&1, List<&2, Char>>:
  +b : String = body
  +n : String = key
  +pp : Nat = p
  jf_expect_colon(jf_skip_ws(String.to_list(String.drop(b, Nat.add(pp, Nat.add(String.length(n), 2n))))))

def mcp_after_colon_go(mpos: Maybe<&1, Nat>, +body: String, +key: String) -> Maybe<&1, List<&2, Char>>:
  match mpos:
    case None{}: None{}
    case Some{p}: mcp_colon_chars(body, key, p)

def mcp_after_colon(+body: String, +key: String) -> Maybe<&1, List<&2, Char>>:
  mcp_after_colon_go(jf_find_key(body, key), body, key)

# capture the balanced {...} / [...] value of a top-level key
def mcp_subval_str(mcs: Maybe<&1, List<&2, Char>>) -> Maybe<&1, String>:
  match mcs:
    case None{}: None{}
    case Some{cs}: Some{String.from_list(List.reverse(&2, Char, cs))}

def mcp_subval_open(is_o: Bool, +h: Char, +t: List<&2, Char>) -> Maybe<&1, String>:
  match is_o:
    case True{}: mcp_subval_str(mcp_bal_go(t, 1n, 0n, h <> mcp_nil()))
    case False{}: None{}

def mcp_subval_after(+cs: List<&2, Char>) -> Maybe<&1, String>:
  match cs:
    case Nil{}: None{}
    case h <> t: mcp_subval_open(mcp_is_open(Char.to_u32(h)), h, t)

def mcp_subval_go(mcs: Maybe<&1, List<&2, Char>>) -> Maybe<&1, String>:
  match mcs:
    case None{}: None{}
    case Some{cs}: mcp_subval_after(cs)

def mcp_subval(+body: String, +key: String) -> Maybe<&1, String>:
  mcp_subval_go(mcp_after_colon(body, key))

# --- value-kind probe (pure; distinguishes missing/object/array/other)
# 0 = key missing (or no colon), 1 = value starts with '{', 2 = value
# starts with '[', 3 = any other present value. Lets callers tell
# "absent" apart from "present but the wrong JSON shape".
def mcp_kind_head(+cs: List<&2, Char>) -> Nat:
  match cs:
    case Nil{}: 3n
    case h <> _:
      +u : U32 = Char.to_u32(h)
      Bool.pick(Nat, U32.is_eq(u, 123), 1n,
        Bool.pick(Nat, U32.is_eq(u, 91), 2n, 3n))

def mcp_kind_go(mcs: Maybe<&1, List<&2, Char>>) -> Nat:
  match mcs:
    case None{}: 0n
    case Some{cs}: mcp_kind_head(cs)

def mcp_val_kind(+body: String, +key: String) -> Nat:
  mcp_kind_go(mcp_after_colon(body, key))

# --- tags validation (single-pass state machine, LINEAR) ---
# States: 0 = start (expect [), 1 = expect string or ], 2 = in string,
# 3 = after string (expect , or ]), 4 = after comma (expect string),
# 5 = end (only whitespace). n counts tag chars (1-64).
#
# LINEARITY (same native hang fix as mcp_bal_go): the transition is
# PURE (mcp_tags_bad/nst/nn: no recursion anywhere) and mcp_tags_vgo
# issues exactly one recursive call per char; the mismatch branch is
# the cheap terminal False{}.

# char class: 0=ws, 1=quote, 2='[', 3=']', 4=',', 5=tag-char, 6=other
def mcp_tag_cls(+u: U32) -> Nat:
  Bool.pick(Nat, mcp_is_tws(u), 0n,
    Bool.pick(Nat, mcp_is_quote(u), 1n,
      Bool.pick(Nat, U32.is_eq(u, 91), 2n,
        Bool.pick(Nat, U32.is_eq(u, 93), 3n,
          Bool.pick(Nat, U32.is_eq(u, 44), 4n,
            Bool.pick(Nat, mcp_tag_char(u), 5n, 6n))))))

# is this (state, char-class) a rejecting transition?
def mcp_tags_bad(+st: Nat, +cls: Nat, +n: Nat) -> Bool:
  Bool.pick(Bool, Nat.is_eq(st, 0n), Bool.not(Bool.or(Nat.is_eq(cls, 0n), Nat.is_eq(cls, 2n))),
    Bool.pick(Bool, Nat.is_eq(st, 1n), Bool.not(Bool.or(Bool.or(Nat.is_eq(cls, 0n), Nat.is_eq(cls, 1n)), Nat.is_eq(cls, 3n))),
      Bool.pick(Bool, Nat.is_eq(st, 2n), Bool.not(Bool.or(Bool.and(Nat.is_eq(cls, 1n), Nat.is_ge(n, 1n)), Bool.and(Nat.is_eq(cls, 5n), Nat.is_lt(n, 64n)))),
        Bool.pick(Bool, Nat.is_eq(st, 3n), Bool.not(Bool.or(Bool.or(Nat.is_eq(cls, 0n), Nat.is_eq(cls, 4n)), Nat.is_eq(cls, 3n))),
          Bool.pick(Bool, Nat.is_eq(st, 4n), Bool.not(Bool.or(Nat.is_eq(cls, 0n), Nat.is_eq(cls, 1n))),
            Bool.not(Nat.is_eq(cls, 0n)))))))

# next state (only consulted when not bad)
def mcp_tags_nst(+st: Nat, +cls: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_eq(st, 0n), Bool.pick(Nat, Nat.is_eq(cls, 2n), 1n, 0n),
    Bool.pick(Nat, Nat.is_eq(st, 1n), Bool.pick(Nat, Nat.is_eq(cls, 1n), 2n, Bool.pick(Nat, Nat.is_eq(cls, 3n), 5n, 1n)),
      Bool.pick(Nat, Nat.is_eq(st, 2n), Bool.pick(Nat, Nat.is_eq(cls, 1n), 3n, 2n),
        Bool.pick(Nat, Nat.is_eq(st, 3n), Bool.pick(Nat, Nat.is_eq(cls, 4n), 4n, Bool.pick(Nat, Nat.is_eq(cls, 3n), 5n, 3n)),
          Bool.pick(Nat, Nat.is_eq(st, 4n), Bool.pick(Nat, Nat.is_eq(cls, 1n), 2n, 4n),
            5n)))))

# next tag-char count: in-string tag char extends, an opening quote
# resets, anything else keeps
def mcp_tags_nn(+st: Nat, +cls: Nat, +n: Nat) -> Nat:
  Bool.pick(Nat, Bool.and(Nat.is_eq(st, 2n), Nat.is_eq(cls, 5n)), Nat.add(n, 1n),
    Bool.pick(Nat, Bool.and(Nat.is_eq(cls, 1n), Bool.or(Nat.is_eq(st, 1n), Nat.is_eq(st, 4n))), 0n,
      n))

def mcp_tags_vgo(+cs: List<&2, Char>, +st: Nat, +n: Nat) -> Bool:
  match cs:
    case Nil{}: Nat.is_eq(st, 5n)
    case h <> t:
      +cls : Nat = mcp_tag_cls(Char.to_u32(h))
      Bool.pick(Bool, mcp_tags_bad(st, cls, n),
        False{},
        mcp_tags_vgo(t, mcp_tags_nst(st, cls), mcp_tags_nn(st, cls, n)))

def mcp_tags_ok(+cs: List<&2, Char>) -> Bool:
  mcp_tags_vgo(cs, 0n, 0n)

# --- blog post storage ("bp:<tenant>:<id>" keys) ---
# value: author \t title \t body \t tags-json \t status \t created \t updated
# title/body/author are json_esc'd (article pattern); tags-json is a
# validated JSON array; status is draft|published; times are ms Nats.

def bpost_key(+tenant: String, +id: String) -> String:
  "bp:" ++ tenant ++ ":" ++ id

def bpost_prefix(+tenant: String) -> String:
  "bp:" ++ tenant ++ ":"

# join pre-escaped fields with tabs
def bpost_join(+author_e: String, +title_e: String, +body_e: String, +tags: String, +status: String, +created: String, +updated: String) -> String:
  author_e ++ s_tab() ++ title_e ++ s_tab() ++ body_e ++ s_tab() ++ tags ++ s_tab() ++ status ++ s_tab() ++ created ++ s_tab() ++ updated

# serialize raw fields (escapes text fields)
def bpost_serialize(+author: String, +title: String, +tbody: String, +tags: String, +status: String, +created: Nat, +updated: Nat) -> String:
  bpost_join(json_esc(author), json_esc(title), json_esc(tbody), tags, status, Nat.show(created), Nat.show(updated))

def bpost_nth(+xs: List<&2, String>, +n: Nat) -> String:
  match xs:
    case Nil{}: ""
    case h <> t:
      Bool.pick(String, Nat.is_eq(n, 0n),
        h,
        bpost_nth(t, Nat.sub(n, 1n)))

# stored text fields are already json_esc'd: embed directly (article pattern)
def bpost_to_json_p(+parts: List<&2, String>, +id: String) -> String:
  "{\"id\":" ++ jstr(id)
  ++ ",\"author\":\"" ++ bpost_nth(parts, 0n) ++ "\""
  ++ ",\"title\":\"" ++ bpost_nth(parts, 1n) ++ "\""
  ++ ",\"body\":\"" ++ bpost_nth(parts, 2n) ++ "\""
  ++ ",\"tags\":" ++ bpost_nth(parts, 3n)
  ++ ",\"status\":\"" ++ bpost_nth(parts, 4n) ++ "\""
  ++ ",\"created_at\":" ++ bpost_nth(parts, 5n)
  ++ ",\"updated_at\":" ++ bpost_nth(parts, 6n)
  ++ "}"

def bpost_to_json(+id: String, +v: String) -> String:
  bpost_to_json_p(split_char(v, ch_tab()), id)

def bpost_status_of(+v: String) -> String:
  bpost_nth(split_char(v, ch_tab()), 4n)

def bpost_id_of(+k: String, +prefix: String) -> String:
  String.drop(k, String.length(prefix))

# --- blog post listing (tenant-scoped, draft/published filter) ---

def bpost_list_pick3(keep: Bool, +yes: List<&2, String>, +no: List<&2, String>) -> List<&2, String>:
  match keep:
    case True{}: yes
    case False{}: no

def bpost_list_pick2(+st: String, +want: String, +yes: List<&2, String>, +no: List<&2, String>) -> List<&2, String>:
  bpost_list_pick3(Bool.or(String.eq(want, "all"), String.eq(st, want)), yes, no)

def bpost_list_pick(keep: Bool, +k: String, +v: String, +prefix: String, +want: String, +acc: List<&2, String>) -> List<&2, String>:
  match keep:
    case False{}: acc
    case True{}: bpost_list_pick2(bpost_status_of(v), want, bpost_to_json(bpost_id_of(k, prefix), v) <> acc, acc)

def bpost_list_go(+kvs: List<&2, Sigma<&2, &2, String, _ => String>>, +prefix: String, +want: String, +acc: List<&2, String>) -> List<&2, String>:
  match kvs:
    case Nil{}: acc
    case h <> t:
      (k, v) = h
      bpost_list_go(t, prefix, want, bpost_list_pick(String.starts_with(k, prefix), k, v, prefix, want, acc))

def bpost_join_rest(+xs: List<&2, String>) -> String:
  match xs:
    case Nil{}: ""
    case h <> t: "," ++ h ++ bpost_join_rest(t)

def bpost_join_go(+xs: List<&2, String>) -> String:
  match xs:
    case Nil{}: ""
    case h <> t: h ++ bpost_join_rest(t)

def bpost_list(+kvs: List<&2, Sigma<&2, &2, String, _ => String>>, +prefix: String, +want: String) -> String:
  "{\"posts\":[" ++ bpost_join_go(List.reverse(&2, String, bpost_list_go(kvs, prefix, want, mcp_nil_str()))) ++ "]}"

# --- static protocol payloads ---

def mcp_init_json() -> String:
  "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"bocht-fresh-blog\",\"version\":\"0.1.0\"}}"

def mcp_tools_json() -> String:
  "{\"tools\":["
  ++ "{\"name\":\"blog_create_post\",\"description\":\"Create a new blog post (starts as a draft).\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"title\",\"body\"]}}"
  ++ ",{\"name\":\"blog_list_posts\",\"description\":\"List blog posts, optionally filtered by status.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"status\":{\"type\":\"string\",\"enum\":[\"draft\",\"published\",\"all\"]}}}}"
  ++ ",{\"name\":\"blog_get_post\",\"description\":\"Get a single blog post by id.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}}"
  ++ ",{\"name\":\"blog_update_post\",\"description\":\"Update a blog post's title, body and/or tags.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"id\"]}}"
  ++ ",{\"name\":\"blog_publish_post\",\"description\":\"Publish a draft blog post.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}}"
  ++ ",{\"name\":\"blog_unpublish_post\",\"description\":\"Move a published blog post back to draft.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}}"
  ++ ",{\"name\":\"blog_delete_post\",\"description\":\"Delete a blog post.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}}"
  ++ "]}"

# --- blog_create_post (chain: done <- wal <- do <- tags <- go5..go <- entry) ---

def mcp_tc_create_done(ok: Bool, +id: String, +tenant: String, sock: Socket, +st: MedState, +st3: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: send_ok_wake(sock, st3, 200, mcp_ok(idj, mcp_tool_ok(bpost_to_json(id, db_get(st_db(st3), bpost_key(tenant, id))))), ka)
    case False{}: send_err_ka(sock, st, ka, 500, "wal_write_failed")

def mcp_tc_create_wal(+now: Nat, +title: String, +tbody: String, +tags: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  +id : String = "p" ++ Nat.show(st_seq(st))
  +tenant : String = auth_tenant(a)
  +kid : String = auth_kid(a)
  +st2 : MedState = st_with_seq(st_with_db(st, Map.set(&2, String, st_db(st), bpost_key(tenant, id), bpost_serialize(kid, title, tbody, tags, "draft", now, now))), Nat.add(st_seq(st), 1n))
  +st3 : MedState = evt_emit(st2, tenant, "blog.post.created", "{\"id\":" ++ jstr(id) ++ "}")
  do IO<MedState>:
    ok : Bool <- wal_setseq_evt(bpost_key(tenant, id), bpost_serialize(kid, title, tbody, tags, "draft", now, now), st_seq(st3), evt_head_opt(st_evlog(st3)))
    mcp_tc_create_done(ok, id, tenant, sock, st, st3, idj, ka)

def mcp_tc_create_do(+title: String, +tbody: String, +tags: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  do IO<MedState>:
    now : Nat <- IO.now()
    mcp_tc_create_wal(now, title, tbody, tags, a, sock, st, idj, ka)

def mcp_tc_create_tags(tags_ok: Bool, +title: String, +tbody: String, +tags: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match tags_ok:
    case False{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "invalid tags: must be a JSON array of strings"))
    case True{}: mcp_tc_create_do(title, tbody, tags, a, sock, st, idj, ka)

# +tags is reusable: validates AND passes along (avoids linear double-use)
def mcp_tc_create_vtags(+tags: String, +title: String, +tbody: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_create_tags(mcp_tags_ok(String.to_list(tags)), title, tbody, tags, a, sock, st, idj, ka)

def mcp_tc_create_go5(+title: String, +tbody: String, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mtags:
    case None{}: mcp_tc_create_do(title, tbody, "[]", a, sock, st, idj, ka)
    case Some{tags}: mcp_tc_create_vtags(tags, title, tbody, a, sock, st, idj, ka)

def mcp_tc_create_go4(title_ok: Bool, +title: String, +tbody: String, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match title_ok:
    case False{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "invalid title: 1-200 printable chars"))
    case True{}: mcp_tc_create_go5(title, tbody, mtags, a, sock, st, idj, ka)

def mcp_tc_create_go3(+title: String, +tbody: String, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_create_go4(valid_title(title), title, tbody, mtags, a, sock, st, idj, ka)

def mcp_tc_create_go2(+title: String, mbody: Maybe<&1, String>, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mbody:
    case None{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "missing required argument: body"))
    case Some{tbody}: mcp_tc_create_go3(title, tbody, mtags, a, sock, st, idj, ka)

def mcp_tc_create_go(mtitle: Maybe<&1, String>, mbody: Maybe<&1, String>, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mtitle:
    case None{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "missing required argument: title"))
    case Some{title}: mcp_tc_create_go2(title, mbody, mtags, a, sock, st, idj, ka)

# tags arrives as raw JSON array text (mcp_subval); absent -> [],
# present-but-not-an-array -> invalid params, unbalanced -> invalid.
def mcp_tc_create_cap(mcap: Maybe<&1, String>, mtitle: Maybe<&1, String>, mbody: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mcap:
    case None{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "invalid tags: must be a JSON array of strings"))
    case Some{tags}: mcp_tc_create_go(mtitle, mbody, Some{tags}, a, sock, st, idj, ka)

def mcp_tc_create_tk(+kind: Nat, +args: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match kind:
    case 0n: mcp_tc_create_go(jf_field(args, "title"), jf_field(args, "body"), None{}, a, sock, st, idj, ka)
    case 2n: mcp_tc_create_cap(mcp_subval(args, "tags"), jf_field(args, "title"), jf_field(args, "body"), a, sock, st, idj, ka)
    case _: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "invalid tags: must be a JSON array of strings"))

def mcp_tc_create(+args: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_create_tk(mcp_val_kind(args, "tags"), args, a, sock, st, idj, ka)

# --- blog_list_posts ---

def mcp_tc_list_do(+want: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  send_ok_ka(sock, st, ka, 200, mcp_ok(idj, mcp_tool_ok(bpost_list(Map.to_list(&2, String, st_db(st)), bpost_prefix(auth_tenant(a)), want))))

def mcp_tc_list_check(ok: Bool, +s: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match ok:
    case False{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "invalid status: want draft|published|all"))
    case True{}: mcp_tc_list_do(s, a, sock, st, idj, ka)

# +s is reusable: validates AND passes along
def mcp_tc_list_with_status(+s: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_list_check(mcp_status_ok(s), s, a, sock, st, idj, ka)

def mcp_tc_list_go(mstatus: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mstatus:
    case None{}: mcp_tc_list_do("all", a, sock, st, idj, ka)
    case Some{s}: mcp_tc_list_with_status(s, a, sock, st, idj, ka)

def mcp_tc_list(+args: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_list_go(jf_field(args, "status"), a, sock, st, idj, ka)

# --- blog_get_post ---

def mcp_tc_get_found(found: Bool, +id: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match found:
    case False{}: send_ok_ka(sock, st, ka, 200, mcp_ok(idj, mcp_tool_err("{\"error\":\"not_found\",\"id\":" ++ jstr(id) ++ "}")))
    case True{}: send_ok_ka(sock, st, ka, 200, mcp_ok(idj, mcp_tool_ok(bpost_to_json(id, db_get(st_db(st), bpost_key(auth_tenant(a), id))))))

def mcp_tc_get_do(+id: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_get_found(db_has(st_db(st), bpost_key(auth_tenant(a), id)), id, a, sock, st, idj, ka)

def mcp_tc_get_go(mid: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mid:
    case None{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "missing required argument: id"))
    case Some{id}: mcp_tc_get_do(id, a, sock, st, idj, ka)

def mcp_tc_get(+args: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_get_go(jf_field(args, "id"), a, sock, st, idj, ka)

# --- blog_update_post helpers ---

def mcp_pick_esc(mv: Maybe<&1, String>, +old: String) -> String:
  match mv:
    case None{}: old
    case Some{v}: json_esc(v)

def mcp_pick_raw(mv: Maybe<&1, String>, +old: String) -> String:
  match mv:
    case None{}: old
    case Some{v}: v

# --- blog_update_post (chain: done <- wal <- do <- tags <- title <- args <- found <- go <- entry) ---

def mcp_tc_update_done(ok: Bool, +id: String, +tenant: String, sock: Socket, +st: MedState, +st3: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: send_ok_wake(sock, st3, 200, mcp_ok(idj, mcp_tool_ok(bpost_to_json(id, db_get(st_db(st3), bpost_key(tenant, id))))), ka)
    case False{}: send_err_ka(sock, st, ka, 500, "wal_write_failed")

def mcp_tc_update_wal(+now: Nat, +id: String, mtitle: Maybe<&1, String>, mbody: Maybe<&1, String>, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  +tenant : String = auth_tenant(a)
  +key : String = bpost_key(tenant, id)
  +parts : List<&2, String> = split_char(db_get(st_db(st), key), ch_tab())
  +val : String = bpost_join(bpost_nth(parts, 0n), mcp_pick_esc(mtitle, bpost_nth(parts, 1n)), mcp_pick_esc(mbody, bpost_nth(parts, 2n)), mcp_pick_raw(mtags, bpost_nth(parts, 3n)), bpost_nth(parts, 4n), bpost_nth(parts, 5n), Nat.show(now))
  +st2 : MedState = st_with_db(st, Map.set(&2, String, st_db(st), key, val))
  +st3 : MedState = evt_emit(st2, tenant, "blog.post.updated", "{\"id\":" ++ jstr(id) ++ "}")
  do IO<MedState>:
    ok : Bool <- wal_set_evt(key, val, evt_head_opt(st_evlog(st3)))
    mcp_tc_update_done(ok, id, tenant, sock, st, st3, idj, ka)

def mcp_tc_update_do(+id: String, mtitle: Maybe<&1, String>, mbody: Maybe<&1, String>, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  do IO<MedState>:
    now : Nat <- IO.now()
    mcp_tc_update_wal(now, id, mtitle, mbody, mtags, a, sock, st, idj, ka)

def mcp_tc_update_tags(ok: Bool, +id: String, mtitle: Maybe<&1, String>, mbody: Maybe<&1, String>, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match ok:
    case False{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "invalid tags: must be a JSON array of strings"))
    case True{}: mcp_tc_update_do(id, mtitle, mbody, mtags, a, sock, st, idj, ka)

# +tags is reusable: validates AND rewraps (avoids linear double-use)
def mcp_tc_update_vtags(+tags: String, +id: String, mtitle: Maybe<&1, String>, mbody: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_update_tags(mcp_tags_ok(String.to_list(tags)), id, mtitle, mbody, Some{tags}, a, sock, st, idj, ka)

def mcp_tc_update_tags_dispatch(mtags: Maybe<&1, String>, +id: String, mtitle: Maybe<&1, String>, mbody: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mtags:
    case None{}: mcp_tc_update_tags(True{}, id, mtitle, mbody, None{}, a, sock, st, idj, ka)
    case Some{tags}: mcp_tc_update_vtags(tags, id, mtitle, mbody, a, sock, st, idj, ka)

def mcp_tc_update_title(ok: Bool, +id: String, mtitle: Maybe<&1, String>, mbody: Maybe<&1, String>, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match ok:
    case False{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "invalid title: 1-200 printable chars"))
    case True{}: mcp_tc_update_tags_dispatch(mtags, id, mtitle, mbody, a, sock, st, idj, ka)

# +title is reusable: validates AND rewraps (avoids linear double-use)
def mcp_tc_update_with_title(+title: String, +id: String, mbody: Maybe<&1, String>, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_update_title(valid_title(title), id, Some{title}, mbody, mtags, a, sock, st, idj, ka)

def mcp_tc_update_args_title(mtitle: Maybe<&1, String>, +id: String, mbody: Maybe<&1, String>, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mtitle:
    case None{}: mcp_tc_update_title(True{}, id, None{}, mbody, mtags, a, sock, st, idj, ka)
    case Some{title}: mcp_tc_update_with_title(title, id, mbody, mtags, a, sock, st, idj, ka)

def mcp_tc_update_args(+id: String, mtitle: Maybe<&1, String>, mbody: Maybe<&1, String>, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_update_args_title(mtitle, id, mbody, mtags, a, sock, st, idj, ka)

def mcp_tc_update_found(found: Bool, +id: String, mtitle: Maybe<&1, String>, mbody: Maybe<&1, String>, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match found:
    case False{}: send_ok_ka(sock, st, ka, 200, mcp_ok(idj, mcp_tool_err("{\"error\":\"not_found\",\"id\":" ++ jstr(id) ++ "}")))
    case True{}: mcp_tc_update_args(id, mtitle, mbody, mtags, a, sock, st, idj, ka)

# +id is reusable: db_has check AND pass along
def mcp_tc_update_with_id(+id: String, mtitle: Maybe<&1, String>, mbody: Maybe<&1, String>, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_update_found(db_has(st_db(st), bpost_key(auth_tenant(a), id)), id, mtitle, mbody, mtags, a, sock, st, idj, ka)

def mcp_tc_update_go(mid: Maybe<&1, String>, mtitle: Maybe<&1, String>, mbody: Maybe<&1, String>, mtags: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mid:
    case None{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "missing required argument: id"))
    case Some{id}: mcp_tc_update_with_id(id, mtitle, mbody, mtags, a, sock, st, idj, ka)

def mcp_tc_update_cap(mcap: Maybe<&1, String>, mid: Maybe<&1, String>, mtitle: Maybe<&1, String>, mbody: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mcap:
    case None{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "invalid tags: must be a JSON array of strings"))
    case Some{tags}: mcp_tc_update_go(mid, mtitle, mbody, Some{tags}, a, sock, st, idj, ka)

def mcp_tc_update_tk(+kind: Nat, +args: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match kind:
    case 0n: mcp_tc_update_go(jf_field(args, "id"), jf_field(args, "title"), jf_field(args, "body"), None{}, a, sock, st, idj, ka)
    case 2n: mcp_tc_update_cap(mcp_subval(args, "tags"), jf_field(args, "id"), jf_field(args, "title"), jf_field(args, "body"), a, sock, st, idj, ka)
    case _: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "invalid tags: must be a JSON array of strings"))

def mcp_tc_update(+args: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_update_tk(mcp_val_kind(args, "tags"), args, a, sock, st, idj, ka)

# --- blog_publish_post / blog_unpublish_post ---

def mcp_tc_pub_done(ok: Bool, +id: String, +tenant: String, sock: Socket, +st: MedState, +st3: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: send_ok_wake(sock, st3, 200, mcp_ok(idj, mcp_tool_ok(bpost_to_json(id, db_get(st_db(st3), bpost_key(tenant, id))))), ka)
    case False{}: send_err_ka(sock, st, ka, 500, "wal_write_failed")

def mcp_tc_pub_wal(+now: Nat, +id: String, +status: String, +evt: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  +tenant : String = auth_tenant(a)
  +key : String = bpost_key(tenant, id)
  +parts : List<&2, String> = split_char(db_get(st_db(st), key), ch_tab())
  +val : String = bpost_join(bpost_nth(parts, 0n), bpost_nth(parts, 1n), bpost_nth(parts, 2n), bpost_nth(parts, 3n), status, bpost_nth(parts, 5n), Nat.show(now))
  +st2 : MedState = st_with_db(st, Map.set(&2, String, st_db(st), key, val))
  +st3 : MedState = evt_emit(st2, tenant, evt, "{\"id\":" ++ jstr(id) ++ "}")
  do IO<MedState>:
    ok : Bool <- wal_set_evt(key, val, evt_head_opt(st_evlog(st3)))
    mcp_tc_pub_done(ok, id, tenant, sock, st, st3, idj, ka)

def mcp_tc_pub_do(+id: String, +status: String, +evt: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  do IO<MedState>:
    now : Nat <- IO.now()
    mcp_tc_pub_wal(now, id, status, evt, a, sock, st, idj, ka)

def mcp_tc_pub_found(found: Bool, +id: String, +status: String, +evt: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match found:
    case False{}: send_ok_ka(sock, st, ka, 200, mcp_ok(idj, mcp_tool_err("{\"error\":\"not_found\",\"id\":" ++ jstr(id) ++ "}")))
    case True{}: mcp_tc_pub_do(id, status, evt, a, sock, st, idj, ka)

# +id is reusable: db_has check AND pass along
def mcp_tc_pub_with_id(+id: String, +status: String, +evt: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_pub_found(db_has(st_db(st), bpost_key(auth_tenant(a), id)), id, status, evt, a, sock, st, idj, ka)

def mcp_tc_pub_go(mid: Maybe<&1, String>, +status: String, +evt: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mid:
    case None{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "missing required argument: id"))
    case Some{id}: mcp_tc_pub_with_id(id, status, evt, a, sock, st, idj, ka)

def mcp_tc_publish(+args: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_pub_go(jf_field(args, "id"), "published", "blog.post.published", a, sock, st, idj, ka)

def mcp_tc_unpublish(+args: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_pub_go(jf_field(args, "id"), "draft", "blog.post.unpublished", a, sock, st, idj, ka)

# --- blog_delete_post ---

def mcp_tc_delete_done(ok: Bool, +id: String, sock: Socket, +st: MedState, +st3: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match ok:
    case True{}: send_ok_wake(sock, st3, 200, mcp_ok(idj, mcp_tool_ok("{\"deleted\":true,\"id\":" ++ jstr(id) ++ "}")), ka)
    case False{}: send_err_ka(sock, st, ka, 500, "wal_write_failed")

def mcp_tc_delete_do(+id: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  +tenant : String = auth_tenant(a)
  +key : String = bpost_key(tenant, id)
  +st2 : MedState = st_with_db(st, Map.del(&2, String, st_db(st), key))
  +st3 : MedState = evt_emit(st2, tenant, "blog.post.deleted", "{\"id\":" ++ jstr(id) ++ "}")
  do IO<MedState>:
    ok : Bool <- wal_del_evt(key, evt_head_opt(st_evlog(st3)))
    mcp_tc_delete_done(ok, id, sock, st, st3, idj, ka)

def mcp_tc_delete_found(found: Bool, +id: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match found:
    case False{}: send_ok_ka(sock, st, ka, 200, mcp_ok(idj, mcp_tool_err("{\"error\":\"not_found\",\"id\":" ++ jstr(id) ++ "}")))
    case True{}: mcp_tc_delete_do(id, a, sock, st, idj, ka)

# +id is reusable: db_has check AND pass along
def mcp_tc_delete_with_id(+id: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_delete_found(db_has(st_db(st), bpost_key(auth_tenant(a), id)), id, a, sock, st, idj, ka)

def mcp_tc_delete_go(mid: Maybe<&1, String>, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mid:
    case None{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "missing required argument: id"))
    case Some{id}: mcp_tc_delete_with_id(id, a, sock, st, idj, ka)

def mcp_tc_delete(+args: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tc_delete_go(jf_field(args, "id"), a, sock, st, idj, ka)

# --- tools/call name dispatch (name -> Nat id, then match) ---

def mcp_tool_call_unknown(+name: String, +idj: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  send_ok_ka(sock, st, ka, 200, mcp_ok(idj, mcp_tool_err("{\"error\":\"unknown_tool\",\"name\":" ++ jstr(name) ++ "}")))

def mcp_tool_name_id(+name: String) -> Nat:
  Bool.pick(Nat, String.eq(name, "blog_create_post"), 0n,
    Bool.pick(Nat, String.eq(name, "blog_list_posts"), 1n,
      Bool.pick(Nat, String.eq(name, "blog_get_post"), 2n,
        Bool.pick(Nat, String.eq(name, "blog_update_post"), 3n,
          Bool.pick(Nat, String.eq(name, "blog_publish_post"), 4n,
            Bool.pick(Nat, String.eq(name, "blog_unpublish_post"), 5n,
              Bool.pick(Nat, String.eq(name, "blog_delete_post"), 6n, 7n)))))))

def mcp_tool_call_by_id(+tid: Nat, +name: String, +args: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match tid:
    case 0n: mcp_tc_create(args, a, sock, st, idj, ka)
    case 1n: mcp_tc_list(args, a, sock, st, idj, ka)
    case 2n: mcp_tc_get(args, a, sock, st, idj, ka)
    case 3n: mcp_tc_update(args, a, sock, st, idj, ka)
    case 4n: mcp_tc_publish(args, a, sock, st, idj, ka)
    case 5n: mcp_tc_unpublish(args, a, sock, st, idj, ka)
    case 6n: mcp_tc_delete(args, a, sock, st, idj, ka)
    case _: mcp_tool_call_unknown(name, idj, sock, st, ka)

def mcp_tool_call(+name: String, +args: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_tool_call_by_id(mcp_tool_name_id(name), name, args, a, sock, st, idj, ka)

# --- tools/call argument extraction ---
# params must be a nested object; within it, "name" is a direct field
# and "arguments" must be a nested object. Anything else (missing,
# string, array, number, unbalanced) is -32602 invalid params.

def mcp_do_call_args2(margs: Maybe<&1, String>, +name: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match margs:
    case None{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "invalid params: arguments must be a well-formed object"))
    case Some{args}: mcp_tool_call(name, args, a, sock, st, idj, ka)

def mcp_do_call_args_kind(+kind: Nat, +params: String, +name: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match kind:
    case 1n: mcp_do_call_args2(mcp_subval(params, "arguments"), name, a, sock, st, idj, ka)
    case _: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "invalid params: arguments must be an object"))

def mcp_do_call_name(mname: Maybe<&1, String>, +params: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mname:
    case None{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "missing tool name"))
    case Some{name}:
      +ps : String = params
      +nm : String = name
      mcp_do_call_args_kind(mcp_val_kind(ps, "arguments"), ps, nm, a, sock, st, idj, ka)

def mcp_do_call_pobj(mparams: Maybe<&1, String>, +body: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mparams:
    case None{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "invalid params: params must be a well-formed object"))
    case Some{params}:
      +ps : String = params
      mcp_do_call_name(jf_field(ps, "name"), ps, a, sock, st, idj, ka)

def mcp_do_call_params(+kind: Nat, +body: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match kind:
    case 1n: mcp_do_call_pobj(mcp_subval(body, "params"), body, a, sock, st, idj, ka)
    case _: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "invalid params: params must be an object"))

def mcp_do_call(+body: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_do_call_params(mcp_val_kind(body, "params"), body, a, sock, st, idj, ka)

# --- method dispatch (method -> Nat id, then match) ---

def mcp_method_id(+m: String) -> Nat:
  Bool.pick(Nat, String.eq(m, "initialize"), 0n,
    Bool.pick(Nat, String.eq(m, "notifications/initialized"), 1n,
      Bool.pick(Nat, String.eq(m, "tools/list"), 2n,
        Bool.pick(Nat, String.eq(m, "tools/call"), 3n, 4n))))

def mcp_check_version(ver_ok: Bool, +body: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match ver_ok:
    case False{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32602", "unsupported protocol version"))
    case True{}: send_ok_ka(sock, st, ka, 200, mcp_ok(idj, mcp_init_json()))

# client-declared protocolVersion is optional; when present it must be
# a supported 2025-* or 2026-* date (major 2024-* rejected as obsolete).
def mcp_is_v2(+v: String) -> Bool:
  Bool.or(String.starts_with(v, "2025-"), String.starts_with(v, "2026-"))

def mcp_ver_ok(mv: Maybe<&1, String>) -> Bool:
  match mv:
    case None{}: True{}
    case Some{v}: mcp_is_v2(v)

# initialize reads protocolVersion from the actual params OBJECT, not
# by whole-body search. params absent -> version optional (pass);
# params present but not an object -> -32600.
def mcp_init_pobj(mparams: Maybe<&1, String>, +body: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mparams:
    case None{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32600", "invalid request: params must be a well-formed object"))
    case Some{params}: mcp_check_version(mcp_ver_ok(jf_field(params, "protocolVersion")), body, a, sock, st, idj, ka)

def mcp_init_params(+kind: Nat, +body: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match kind:
    case 0n: mcp_check_version(True{}, body, a, sock, st, idj, ka)
    case 1n: mcp_init_pobj(mcp_subval(body, "params"), body, a, sock, st, idj, ka)
    case _: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32600", "invalid request: params must be an object"))

def mcp_dispatch_by_id(+mid: Nat, +m: String, +body: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mid:
    case 0n: mcp_init_params(mcp_val_kind(body, "params"), body, a, sock, st, idj, ka)
    case 1n: send_ok_ka(sock, st, ka, 202, "")
    case 2n: send_ok_ka(sock, st, ka, 200, mcp_ok(idj, mcp_tools_json()))
    case 3n: mcp_do_call(body, a, sock, st, idj, ka)
    case _: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32601", "method not found: " ++ m))

def mcp_handle_method_go(+m: String, +body: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_dispatch_by_id(mcp_method_id(m), m, body, a, sock, st, idj, ka)

def mcp_handle_method(mmethod: Maybe<&1, String>, +body: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match mmethod:
    case None{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32600", "invalid request: missing method"))
    case Some{m}: mcp_handle_method_go(m, body, a, sock, st, idj, ka)

# JSON-RPC envelope: the top-level value must be an object and carry
# "jsonrpc":"2.0"; missing/wrong -> -32600.
def mcp_top_obj_go(+cs: List<&2, Char>) -> Bool:
  match cs:
    case Nil{}: False{}
    case h <> _: U32.is_eq(Char.to_u32(h), 123)

def mcp_top_is_obj(+body: String) -> Bool:
  mcp_top_obj_go(jf_skip_ws(String.to_list(body)))

def mcp_jsonrpc_ok_go(mv: Maybe<&1, String>) -> Bool:
  match mv:
    case None{}: False{}
    case Some{v}: String.eq(v, "2.0")

def mcp_jsonrpc_ok(+body: String) -> Bool:
  mcp_jsonrpc_ok_go(jf_field(body, "jsonrpc"))

def mcp_envelope_ok(+body: String) -> Bool:
  Bool.and(mcp_top_is_obj(body), mcp_jsonrpc_ok(body))

def mcp_handle_env(ok: Bool, +body: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match ok:
    case False{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32600", "invalid request: not a JSON-RPC 2.0 object"))
    case True{}: mcp_handle_method(jf_field(body, "method"), body, a, sock, st, idj, ka)

# not valid JSON at all -> -32700; valid JSON but not a JSON-RPC 2.0
# request object (not an object, no/invalid method, wrong jsonrpc tag,
# non-object params where required) -> -32600
def mcp_handle_parse(ok: Bool, +body: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match ok:
    case False{}: send_ok_ka(sock, st, ka, 200, mcp_err(idj, "32700", "parse error"))
    case True{}: mcp_handle_env(mcp_envelope_ok(body), body, a, sock, st, idj, ka)

def mcp_handle(+body: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  mcp_handle_parse(jf_body_ok(body), body, a, sock, st, idj, ka)

# --- route entry ---

def g_mcp_role(ok: Bool, +body: String, +a: Auth, sock: Socket, +st: MedState, +idj: String, +ka: Ka) -> IO(MedState):
  match ok:
    case False{}: send_err_ka(sock, st, ka, 403, "forbidden")
    case True{}: mcp_handle(body, a, sock, st, idj, ka)

# +a is reusable: role check AND pass along
def g_mcp_auth(+a: Auth, sock: Socket, +st: MedState, +body: String, +ka: Ka) -> IO(MedState):
  g_mcp_role(Bool.or(is_member(a), is_admin(a)), body, a, sock, st, mcp_id_json(body), ka)

def g_mcp(ma: Maybe<&1, Auth>, sock: Socket, +st: MedState, +body: String, +ka: Ka) -> IO(MedState):
  match ma:
    case None{}: send_err_ka(sock, st, ka, 401, "unauthorized")
    case Some{a}: g_mcp_auth(a, sock, st, body, ka)

# Handler id for POST /mcp (registered below; dispatched in route_dispatch).
def hid_mcp() -> Nat:
  19n

# Handler ids (match arms in route_dispatch).
def hid_health() -> Nat: 0n

def hid_help() -> Nat: 1n

def hid_schema() -> Nat: 2n

def hid_post_keys() -> Nat: 3n

def hid_get_keys() -> Nat: 4n

def hid_rotate() -> Nat: 5n

def hid_revoke() -> Nat: 6n

def hid_post_users() -> Nat: 7n

def hid_get_user() -> Nat: 8n

def hid_post_articles() -> Nat: 9n

def hid_get_article() -> Nat: 10n

def hid_post_clap() -> Nat: 11n

def hid_post_pubs() -> Nat: 12n

def hid_get_pub() -> Nat: 13n

def hid_post_pm() -> Nat: 14n

def hid_get_pm() -> Nat: 15n

def hid_delete_pm() -> Nat: 16n

def hid_events() -> Nat: 17n

# Round 3 item 19: graceful-restart control (admin only). Appended last so
# hids 0..17 are unchanged.
def hid_restart() -> Nat: 18n


def registry() -> List<&2, RouteDef>:
  MkRoute{"GET", "/health", False{}, "liveness probe", hid_health(), False{}} <>
  MkRoute{"GET", "/help", False{}, "this endpoint list", hid_help(), False{}} <>
  MkRoute{"GET", "/schema", False{}, "OpenAPI schema", hid_schema(), False{}} <>
  MkRoute{"POST", "/v1/keys", True{}, "create API key (admin)", hid_post_keys(), False{}} <>
  MkRoute{"GET", "/v1/keys", True{}, "list API keys (admin, tenant-scoped)", hid_get_keys(), False{}} <>
  MkRoute{"POST", "/v1/keys/:kid/rotate", True{}, "rotate an API key", hid_rotate(), False{}} <>
  MkRoute{"POST", "/v1/keys/:kid/revoke", True{}, "revoke an API key", hid_revoke(), False{}} <>
  MkRoute{"POST", "/v1/users", True{}, "create user", hid_post_users(), False{}} <>
  MkRoute{"GET", "/v1/users/:id", True{}, "get user", hid_get_user(), False{}} <>
  MkRoute{"POST", "/v1/articles", True{}, "create article", hid_post_articles(), False{}} <>
  MkRoute{"GET", "/v1/articles/:id", True{}, "get article", hid_get_article(), False{}} <>
  MkRoute{"POST", "/v1/articles/:id/clap", True{}, "clap for an article", hid_post_clap(), False{}} <>
  MkRoute{"POST", "/v1/pubs", True{}, "create publication", hid_post_pubs(), False{}} <>
  MkRoute{"GET", "/v1/pubs/:id", True{}, "get publication", hid_get_pub(), False{}} <>
  MkRoute{"POST", "/v1/pubs/:id/members", True{}, "add publication member (owner or admin)", hid_post_pm(), False{}} <>
  MkRoute{"GET", "/v1/pubs/:id/members", True{}, "list publication members", hid_get_pm(), False{}} <>
  MkRoute{"DELETE", "/v1/pubs/:id/members/:kid", True{}, "remove publication member (owner or admin)", hid_delete_pm(), False{}} <>
  MkRoute{"GET", "/v1/events", True{}, "poll events (cursor query param; last 1000 retained, truncated:true when cursor predates them)", hid_events(), False{}} <>
  MkRoute{"POST", "/v1/admin/restart", True{}, "schedule graceful restart (admin)", hid_restart(), False{}} <>
  MkRoute{"POST", "/mcp", True{}, "MCP Streamable HTTP: JSON-RPC 2.0 mini-CMS/blog (initialize, tools/list, tools/call)", hid_mcp(), False{}} <>
  Nil{}


def help_entry(+r: RouteDef) -> String:
  "\"" ++ route_method(r) ++ " " ++ route_path(r) ++ "\""


def help_entries_go(+rs: List<&2, RouteDef>, +acc: List<&2, String>) -> List<&2, String>:
  match rs:
    case Nil{}: acc
    case h <> t: help_entry(h) <> help_entries_go(t, acc)


def help_json() -> String:
  "{\"service\":\"medium-fresh\",\"version\":\"0.1.0\",\"endpoints\":[" ++ join_str(help_entries_go(registry(), Nil{}), ",") ++ "]}"


def oapi_seg_go(is_param: Bool, +seg: String) -> String:
  match is_param:
    case True{}: "{" ++ String.drop(seg, 1n) ++ "}"
    case False{}: seg


def oapi_seg(+seg: String) -> String:
  oapi_seg_go(String.starts_with(seg, ":"), seg)


def oapi_segs_go(+segs: List<&2, String>, +acc: String) -> String:
  match segs:
    case Nil{}: acc
    case h <> t: oapi_segs_go(t, acc ++ "/" ++ oapi_seg(h))


def oapi_path(+p: String) -> String:
  oapi_segs_go(path_segs(p), "")


def method_lower_go(is_get: Bool, is_post: Bool, +m: String) -> String:
  match is_get:
    case True{}: "get"
    case False{}:
      match is_post:
        case True{}: "post"
        case False{}: "delete"


def method_lower(+m: String) -> String:
  method_lower_go(String.eq(m, "GET"), String.eq(m, "POST"), m)


def method_entry(+r: RouteDef) -> String:
  "\"" ++ method_lower(route_method(r)) ++ "\":{\"description\":\"" ++ json_esc(route_desc(r)) ++ "\"" ++ Bool.pick(String, route_auth(r), ",\"security\":[{\"bearerAuth\":[]}]", "") ++ "}"


def schema_path_obj(+path: String, +methods: List<&2, String>) -> String:
  "\"" ++ path ++ "\":{" ++ join_str(List.reverse(&2, String, methods), ",") ++ "}"


def methods_for(+rs: List<&2, RouteDef>, +path: String, +acc: List<&2, String>) -> List<&2, String>:
  match rs:
    case Nil{}: List.reverse(&2, String, acc)
    case h <> t:
      methods_for(t, path, Bool.pick(List<&2, String>, String.eq(oapi_path(route_path(h)), path), method_entry(h) <> acc, acc))


def path_seen(+rs: List<&2, RouteDef>, +path: String) -> Bool:
  match rs:
    case Nil{}: False{}
    case h <> t:
      Bool.or(String.eq(oapi_path(route_path(h)), path), path_seen(t, path))


def schema_paths_go(+rs: List<&2, RouteDef>, +seen: List<&2, RouteDef>, +acc: List<&2, String>) -> List<&2, String>:
  match rs:
    case Nil{}: acc
    case h <> t:
      +p : String = oapi_path(route_path(h))
      schema_paths_go(t, h <> seen, Bool.pick(List<&2, String>, path_seen(seen, p), acc, schema_path_obj(p, methods_for(registry(), p, Nil{})) <> acc))


def schema_json(+ka: Ka) -> String:
  "{\"openapi\":\"3.0.0\",\"info\":{\"title\":\"Medium Fresh\",\"version\":\"0.1.0\"},\"paths\":{" ++ join_str(schema_paths_go(registry(), Nil{}, Nil{}), ",") ++ "},\"components\":{\"securitySchemes\":{\"bearerAuth\":{\"type\":\"http\",\"scheme\":\"bearer\",\"bearerFormat\":\"opaque\"}}}}" 

# --- registry-driven dispatch ---
# route(ka) looks the request up in registry() (method + path pattern, first
# match wins) and calls the handler selected by the entry's hid. /help and
# /schema enumerate this same table, so docs and routing cannot diverge.
# Match modes (item 18 fix): every route matches by exact segment count —
# non-empty trailing segments 404. Prefix-style matching was a bug and is
# gone; the Bool field stays in RouteDef only for historical shape, and must
# stay False on every route.
# Recursion discipline (Bend: no mutual recursion, defs precede use): every
# loop is a single self-recursive def; per-element choice uses the Bool.pick /
# maybe_first idiom (cf. key_by_kid_go), which is strict-safe on finite lists.

type RouteHit is Data:
  MkHit{hid: Nat, params: List<&2, String>}

def disp_p1(+params: List<&2, String>) -> String:
  match params:
    case Nil{}: ""
    case h <> _: h

def disp_p2_go(+rest: List<&2, String>, +a: String) -> String & String:
  match rest:
    case Nil{}: ("", "")
    case b <> _: (a, b)

def disp_p2(+params: List<&2, String>) -> String & String:
  match params:
    case Nil{}: ("", "")
    case a <> rest: disp_p2_go(rest, a)

def pat_is_param(+seg: String) -> Bool:
  String.starts_with(seg, ":")

def seg_matches(+ph: String, +rh: String) -> Bool:
  Bool.pick(Bool, String.starts_with(ph, ":"), True{}, String.eq(ph, rh))

def pat_match_end(+prefix: Bool, +req: List<&2, String>, +acc: List<&2, String>) -> Maybe<&1, List<&2, String>>:
  match prefix:
    case True{}: Some{List.reverse(&2, String, acc)}
    case False{}:
      match req:
        case Nil{}: Some{List.reverse(&2, String, acc)}
        case _ <> _: None{}

def pat_match_end2(ok: Bool, +prefix: Bool, +req: List<&2, String>, +acc: List<&2, String>) -> Maybe<&1, List<&2, String>>:
  match ok:
    case False{}: None{}
    case True{}: pat_match_end(prefix, req, acc)

def pat_match_go(+pat: List<&2, String>, +req: List<&2, String>, +acc: List<&2, String>, +ok: Bool, +prefix: Bool) -> Maybe<&1, List<&2, String>>:
  match pat:
    case Nil{}: pat_match_end2(ok, prefix, req, acc)
    case ph <> pt:
      match req:
        case Nil{}: None{}
        case rh <> rt: pat_match_go(pt, rt,
          Bool.pick(List<&2, String>, pat_is_param(ph), rh <> acc, acc),
          Bool.and(ok, seg_matches(ph, rh)), prefix)

def route_try_params(mp: Maybe<&1, List<&2, String>>, +h: RouteDef) -> Maybe<&1, RouteHit>:
  match mp:
    case None{}: None{}
    case Some{params}: Some{MkHit{route_hid(h), params}}

def route_try(+h: RouteDef, +method: String, +segs: List<&2, String>) -> Maybe<&1, RouteHit>:
  Bool.pick(Maybe<&1, RouteHit>, String.eq(route_method(h), method),
    route_try_params(pat_match_go(path_segs(route_path(h)), segs, Nil{}, True{}, route_prefix(h)), h),
    None{})

def maybe_first(a: Maybe<&1, RouteHit>, b: Maybe<&1, RouteHit>) -> Maybe<&1, RouteHit>:
  match a:
    case None{}: b
    case Some{hit}: Some{hit}

def route_find_go(+rs: List<&2, RouteDef>, +method: String, +segs: List<&2, String>) -> Maybe<&1, RouteHit>:
  match rs:
    case Nil{}: None{}
    case h <> t: maybe_first(route_try(h, method, segs), route_find_go(t, method, segs))

def route_dispatch_del2(pp: String & String, +headers: Map<&2, String>, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  (pid, kid) = pp
  g_delete_pm(headers, sock, st, pid, kid, ka)

def route_dispatch_del(+params: List<&2, String>, +headers: Map<&2, String>, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  route_dispatch_del2(disp_p2(params), headers, sock, st, ka)

def route_dispatch(+hid: Nat, +params: List<&2, String>, +query: String, +headers: Map<&2, String>, +body: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match hid:
    case 0n: send_ok_ka(sock, st, ka, 200, "{\"ok\":true}")
    case 1n: send_ok_ka(sock, st, ka, 200, help_json())
    case 2n: send_ok_ka(sock, st, ka, 200, schema_json(ka))
    case 3n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_post_keys(ma, sock, st, body, ka)
    case 4n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_get_keys(ma, sock, st, ka)
    case 5n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_rotate(ma, sock, st, disp_p1(params), ka)
    case 6n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_revoke(ma, sock, st, disp_p1(params), ka)
    case 7n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_post_users(ma, sock, st, body, ka)
    case 8n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_get_user(ma, sock, st, disp_p1(params), ka)
    case 9n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_post_articles(ma, sock, st, body, ka)
    case 10n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_get_article(ma, sock, st, disp_p1(params), ka)
    case 11n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_post_clap(ma, sock, st, disp_p1(params), body, ka)
    case 12n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_post_pubs(ma, sock, st, body, ka)
    case 13n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_get_pub(ma, sock, st, disp_p1(params), ka)
    case 14n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_post_pm(ma, sock, st, disp_p1(params), body, ka)
    case 15n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_get_pm(ma, sock, st, disp_p1(params), ka)
    case 16n: route_dispatch_del(params, headers, sock, st, ka)
    case 17n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_events(ma, sock, st, query, ka)
    case 18n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_restart(ma, sock, st, ka)
    case 19n:
      do IO<MedState>:
        ma : Maybe<&1, Auth> <- auth_of(headers, st)
        g_mcp(ma, sock, st, body, ka)
    case _: send_err_ka(sock, st, ka, 404, "not_found")

def route_found(mr: Maybe<&1, RouteHit>, +query: String, +headers: Map<&2, String>, +body: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match mr:
    case None{}: send_err_ka(sock, st, ka, 404, "not_found")
    case Some{MkHit{hid, params}}: route_dispatch(hid, params, query, headers, body, sock, st, ka)

def route_lookup(+method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  route_found(route_find_go(registry(), method, path_segs(path)), query, headers, body, sock, st, ka)

def route_mok3(is_delete: Bool, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match is_delete:
    case True{}: route_lookup(method, path, query, headers, body, sock, st, ka)
    case False{}: send_err_ka(sock, st, ka, 405, "method_not_allowed")

def route_mok2(is_post: Bool, is_delete: Bool, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match is_post:
    case True{}: route_lookup(method, path, query, headers, body, sock, st, ka)
    case False{}: route_mok3(is_delete, method, path, query, headers, body, sock, st, ka)

def route_mok(is_get: Bool, is_post: Bool, is_delete: Bool, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  match is_get:
    case True{}: route_lookup(method, path, query, headers, body, sock, st, ka)
    case False{}: route_mok2(is_post, is_delete, method, path, query, headers, body, sock, st, ka)

def route_head(is_head: Bool, +method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  # Item 104: HEAD short-circuits to a headers-only 405 (RFC 9110 S9.3.2).
  # Follows the existing route_mok* Bool-first-arg convention (match cannot
  # scrutinize the computed String.eq directly).
  match is_head:
    case True{}: send_head_405_ka(sock, st, ka)
    case False{}: route_mok(String.eq(method, "GET"), String.eq(method, "POST"), String.eq(method, "DELETE"), method, path, query, headers, body, sock, st, ka)

def route(+method: String, +path: String, +query: String, +headers: Map<&2, String>, +body: String, sock: Socket, +st: MedState, +ka: Ka) -> IO(MedState):
  route_head(String.eq(method, "HEAD"), method, path, query, headers, body, sock, st, ka)
