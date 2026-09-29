# med_auth.bend — fresh Medium service, part 5: auth with stable kid.
# Two key kinds:
#   env keys: BOCHT_API_KEYS entries "name:tenant:role". kid = name.
#             Looked up directly by name.
#   managed keys: created via the API. The keys map stores ONLY the
#             verifier "v1$<64 hex>" (never the secret). kid = "k_<n>".
#             A presented Bearer secret is hashed to its verifier for lookup.
# A presented verifier is NEVER accepted as a credential.

# --- "Bearer <key>" extraction ---

def bearer_key_go(ok: Bool, +v: String) -> Maybe<&1, String>:
  match ok:
    case True{}: Some{String.trim(String.drop(v, 7n))}
    case False{}: None{}

def bearer_key(+v: String) -> Maybe<&1, String>:
  bearer_key_go(String.eq(String.to_lower(String.take(v, 7n)), "bearer "), v)

# --- strict verifier check: "v1$" + exactly 64 hex chars ---

def auth_is_verifier_hex(+cs: List<&2, Char>, +n: Nat) -> Bool:
  match cs:
    case Nil{}: Nat.is_eq(n, 64n)
    case h <> t: Bool.pick(Bool, is_lower_hex(h), auth_is_verifier_hex(t, Nat.add(n, 1n)), False{})

def auth_is_verifier(+s: String) -> Bool:
  Bool.pick(Bool, String.starts_with(s, "v1$"),
    auth_is_verifier_hex(String.to_list(String.drop(s, 3n)), 0n),
    False{})

def verifier_of(+secret: String) -> String:
  "v1$" ++ sha256_hex(secret)

# --- validity: revocation + expiry ---

def auth_valid_not_expired(not_expired: Bool, +kid: String, +k: String, +t: String, +r: String, +e: Nat) -> Maybe<&1, Auth>:
  match not_expired:
    case True{}: Some{MkAuth{kid, k, t, r, e, False{}}}
    case False{}: None{}

def auth_valid_expiry(no_expiry: Bool, +now: Nat, +kid: String, +k: String, +t: String, +r: String, +e: Nat) -> Maybe<&1, Auth>:
  match no_expiry:
    case True{}: Some{MkAuth{kid, k, t, r, e, False{}}}
    case False{}: auth_valid_not_expired(Nat.is_lt(now, e), kid, k, t, r, e)

def auth_valid_revoked(revoked: Bool, +now: Nat, +kid: String, +k: String, +t: String, +r: String, +e: Nat) -> Maybe<&1, Auth>:
  match revoked:
    case True{}: None{}
    case False{}: auth_valid_expiry(Nat.is_eq(e, 0n), now, kid, k, t, r, e)

def auth_valid_now(+now: Nat, +a: Auth) -> Maybe<&1, Auth>:
  match a:
    case MkAuth{kid, k, t, r, e, rv}:
      auth_valid_revoked(rv, now, kid, k, t, r, e)

def key_lookup_val_empty(is_empty: Bool, +now: Nat, +a: Auth) -> Maybe<&1, Auth>:
  match is_empty:
    case True{}: None{}
    case False{}: auth_valid_now(now, a)

def key_lookup_val_valid(now: Nat, mv: Map<&2, Auth> & Auth) -> Maybe<&1, Auth>:
  (m2, +a) = mv
  key_lookup_val_empty(String.is_empty(auth_key(a)), now, a)

def key_lookup_valid(+ks: Map<&2, Auth>, +key: String, +now: Nat) -> Maybe<&1, Auth>:
  key_lookup_val_valid(now, Map.get(Auth, MkAuth{"", "", "", "", 0n, False{}}, ks, key))

# --- authorize: env key direct, else managed secret via verifier ---

def auth_token_direct(mdirect: Maybe<&1, Auth>, +k: String, +keys: Map<&2, Auth>, +now: Nat) -> Maybe<&1, Auth>:
  match mdirect:
    case Some{a}: Some{a}
    case None{}: key_lookup_valid(keys, verifier_of(k), now)

def auth_token_check(is_v: Bool, +k: String, +keys: Map<&2, Auth>, +now: Nat) -> Maybe<&1, Auth>:
  match is_v:
    case True{}: None{}
    case False{}: auth_token_direct(key_lookup_valid(keys, k, now), k, keys, now)

def auth_token_lookup(+k: String, +keys: Map<&2, Auth>, +now: Nat) -> Maybe<&1, Auth>:
  auth_token_check(auth_is_verifier(k), k, keys, now)

def auth_token_valid(mk: Maybe<&1, String>, +keys: Map<&2, Auth>, +now: Nat) -> Maybe<&1, Auth>:
  match mk:
    case None{}: None{}
    case Some{k}: auth_token_lookup(k, keys, now)

def auth_bearer_ev(is_empty: Bool, +v: String, +keys: Map<&2, Auth>, +now: Nat) -> Maybe<&1, Auth>:
  match is_empty:
    case True{}: None{}
    case False{}: auth_token_valid(bearer_key(v), keys, now)

def authorize_valid(+headers: Map<&2, String>, +keys: Map<&2, Auth>, +now: Nat) -> Maybe<&1, Auth>:
  auth_bearer_ev(String.is_empty(find_header(headers, "authorization")), find_header(headers, "authorization"), keys, now)

# --- env parsing: "key:tenant:role,key:tenant:role" (kid = key) ---

def valid_role(+r: String) -> Bool:
  Bool.or(String.eq(r, "viewer"),
  Bool.or(String.eq(r, "member"), String.eq(r, "admin")))

def parse_ke_valid(ok: Bool, +k: String, +t: String, +r: String) -> Maybe<&1, Auth>:
  match ok:
    case True{}: Some{MkAuth{k, k, t, r, 0n, False{}}}
    case False{}: None{}

def parse_ke_done(+t3: List<&2, String>, +k: String, +t: String, +r: String) -> Maybe<&1, Auth>:
  match t3:
    case Nil{}: parse_ke_valid(Bool.and(Bool.not(String.is_empty(k)), Bool.and(Bool.not(String.is_empty(t)), valid_role(r))), k, t, r)
    case _ <> _: None{}

def parse_ke_rest(+t2: List<&2, String>, +k: String, +t: String) -> Maybe<&1, Auth>:
  match t2:
    case Nil{}: None{}
    case r <> t3: parse_ke_done(t3, k, t, r)

def parse_ke_parts2(+t: List<&2, String>, +k: String) -> Maybe<&1, Auth>:
  match t:
    case Nil{}: None{}
    case tn <> t2: parse_ke_rest(t2, k, tn)

def parse_ke_parts(+ps: List<&2, String>) -> Maybe<&1, Auth>:
  match ps:
    case Nil{}: None{}
    case k <> t: parse_ke_parts2(t, k)

def parse_key_entry(+e: String) -> Maybe<&1, Auth>:
  parse_ke_parts(split_char(e, Char.from_u32(58)))

def maybe_cons_key(mk: Maybe<&1, Auth>, +acc: Map<&2, Auth>) -> Map<&2, Auth>:
  match mk:
    case None{}: acc
    case Some{+k}: Map.set(&2, Auth, acc, auth_key(k), k)

def pk_loop(+es: List<&2, String>, +acc: Map<&2, Auth>) -> Map<&2, Auth>:
  match es:
    case Nil{}: acc
    case h <> t: pk_loop(t, maybe_cons_key(parse_key_entry(h), acc))

def parse_keys(+env: String) -> Map<&2, Auth>:
  pk_loop(split_char(env, Char.from_u32(44)), Map.new(&2, Auth))

# --- fixed-window rate limiting: rl maps lookup-key -> "window_start,count" ---

def rl_nat_go(+cs: List<&2, Char>, +acc: Nat) -> Nat:
  match cs:
    case Nil{}: acc
    case c <> t: Bool.pick(Nat, is_digit(c), rl_nat_go(t, Nat.add(Nat.mul(acc, 10n), dig_val(c))), acc)

def rl_nat(+s: String) -> Nat:
  rl_nat_go(String.to_list(s), 0n)

def rl_parse_at(mpos: Maybe<&1, Nat>, +cur: String) -> Nat & Nat:
  match mpos:
    case None{}: (0n, 0n)
    case Some{p}:
      +pp : Nat = p
      +cc : String = cur
      (rl_nat(String.take(cc, pp)), rl_nat(String.drop(cc, Nat.add(pp, 1n))))

def rl_parse(+cur: String) -> Nat & Nat:
  rl_parse_at(find_char(cur, Char.from_u32(44)), cur)

def check_rl_hit(under: Bool, +m2: Map<&2, String>, +key: String, +start: Nat, +count: Nat) -> Map<&2, String> & Bool:
  match under:
    case True{}: (Map.set(&2, String, m2, key, Nat.show(start) ++ "," ++ Nat.show(Nat.add(count, 1n))), True{})
    case False{}: (m2, False{})

def check_rl_win(in_win: Bool, +m2: Map<&2, String>, +key: String, now: Nat, +start: Nat, +count: Nat, limit: Nat) -> Map<&2, String> & Bool:
  match in_win:
    case True{}: check_rl_hit(Nat.is_lt(count, limit), m2, key, start, count)
    case False{}: (Map.set(&2, String, m2, key, Nat.show(now) ++ ",1"), True{})

def check_rl_parse(sc: Nat & Nat, +m2: Map<&2, String>, +key: String, +now: Nat, limit: Nat, window: Nat) -> Map<&2, String> & Bool:
  (+start, count) = sc
  check_rl_win(Nat.is_lt(Nat.sub(now, start), window), m2, key, now, start, count, limit)

def check_rl_cur(is_new: Bool, +m2: Map<&2, String>, +key: String, +cur: String, now: Nat, limit: Nat, window: Nat) -> Map<&2, String> & Bool:
  match is_new:
    case True{}: (Map.set(&2, String, m2, key, Nat.show(now) ++ ",1"), True{})
    case False{}: check_rl_parse(rl_parse(cur), m2, key, now, limit, window)

def check_rl_entry(got: Map<&2, String> & String, +key: String, now: Nat, limit: Nat, window: Nat) -> Map<&2, String> & Bool:
  (m2, +cur) = got
  check_rl_cur(String.is_empty(cur), m2, key, cur, now, limit, window)

def check_rl(+rl: Map<&2, String>, +key: String, now: Nat, limit: Nat, window: Nat) -> Map<&2, String> & Bool:
  check_rl_entry(Map.get(String, "", rl, key), key, now, limit, window)

# --- rate-limit map pruning (Round 2 items 9-10) ---
# check_rl refreshes an entry's window on each hit, but entries for IPs /
# credentials that never return are never removed: the rl map would grow by
# up to 3 entries per distinct client forever. rl_maybe_prune sweeps entries
# whose window has fully elapsed once the map exceeds rl_prune_at() entries,
# bounding memory to O(clients active within the window).
# Item 10: the sweep itself is O(map) with per-entry string parsing, so
# running it on EVERY request once the map is large turns the defense into a
# DoS amplifier (O(n) owner work per request under high-cardinality load).
# The sweep is now time-gated: at most one sweep per window (60s), tracked
# in st_rlprune. Memory between sweeps is bounded by (requests in one
# window) x 3 entries; prune cost is amortized to one O(n) pass per minute.
# Item 131: the gated full-map sweep still blocked the single-threaded owner
# for O(n) on the triggering request (~40ms at 4k entries, ~45ms at 7k,
# measured on r39), and any client can trigger it once per 60s after spraying
# enough distinct keys. The sweep is now INCREMENTAL: each eligible request
# sweeps at most rl_sweep_budget() entries, resuming from the st.rlcur
# cursor. When the cursor passes the end of the map the pass is complete:
# the cursor resets to 0 and rlprune is set to now, closing the 60s gate
# until the next pass. The memory bound is unchanged: a pass always
# terminates (each request inserts only a handful of entries, far below the
# per-pass budget), and every entry is re-examined on each pass, so
# fully-elapsed windows are deleted and the map stays O(clients active
# within the window).
# Item 133: the O(n) Map.size call in rl_maybe_prune ran on EVERY request
# (Bend is strict, so the size was computed before the gate check) — a
# 0.25us/entry per-request tax (item 132, R^2=0.980). The size is only
# evaluated when it can change the outcome: (a) a pass is already in
# progress (cur >= 1) -> active regardless of size, skip it; (b) the 60s
# gate is closed -> due is false regardless of size, skip it. Only when no
# pass is in progress AND the gate is open do we pay for Map.size — at most
# one O(n) size check per 60s. When the gate is open but the map is below
# threshold we close the gate (last=now): rechecking sooner is pointless
# (per-window growth is bounded) and this keeps the check at 60s cadence
# instead of per-request. Pass starts stay <= 1 per 60s; the memory bound
# is unchanged. Residual: rl_prune_pass still builds Map.to_list once per
# request while a pass is in progress (~n/256 requests per 60s) — bounded,
# far below the old full-sweep stall.
def rl_entry_expired_go(sc: Nat & Nat, +now: Nat, +window: Nat) -> Bool:
  (+start, count) = sc
  Nat.is_ge(Nat.sub(now, start), window)

def rl_entry_expired(+v: String, +now: Nat, +window: Nat) -> Bool:
  rl_entry_expired_go(rl_parse(v), now, window)

def rl_prune_go(+kvs: List<&2, Sigma<&2, &2, String, _ => String>>, +m: Map<&2, String>, +now: Nat, +window: Nat) -> Map<&2, String>:
  match kvs:
    case Nil{}: m
    case h <> t:
      (k, v) = h
      rl_prune_go(t, Bool.pick(Map<&2, String>, rl_entry_expired(v, now, window), Map.del(&2, String, m, k), m), now, window)

def rl_prune_at() -> Nat:
  Nat.mul(40n, 100n)

def rl_sweep_budget() -> Nat:
  256n

def rl_list_len(+kvs: List<&2, Sigma<&2, &2, String, _ => String>>) -> Nat:
  match kvs:
    case Nil{}: 0n
    case _ <> t: Nat.add(1n, rl_list_len(t))

def rl_drop(+n: Nat, +kvs: List<&2, Sigma<&2, &2, String, _ => String>>) -> List<&2, Sigma<&2, &2, String, _ => String>>:
  match n:
    case 0n: kvs
    case 1n+m:
      match kvs:
        case Nil{}: Nil{}
        case _ <> t: rl_drop(m, t)

def rl_take(+n: Nat, +kvs: List<&2, Sigma<&2, &2, String, _ => String>>) -> List<&2, Sigma<&2, &2, String, _ => String>>:
  match n:
    case 0n: Nil{}
    case 1n+m:
      match kvs:
        case Nil{}: Nil{}
        case h <> t: h <> rl_take(m, t)

# One incremental sweep pass: sweep at most rl_sweep_budget() entries
# starting at the cursor. Returns (new_map, (new_last, new_cur)).
def rl_prune_pass_go(done: Bool, +cur: Nat, +kvs: List<&2, Sigma<&2, &2, String, _ => String>>, +m: Map<&2, String>, +now: Nat, +window: Nat, +last: Nat) -> Map<&2, String> & Nat & Nat:
  match done:
    case True{}:
      +seg : List<&2, Sigma<&2, &2, String, _ => String>> = rl_take(rl_sweep_budget(), rl_drop(cur, kvs))
      (rl_prune_go(seg, m, now, window), (now, 0n))
    case False{}:
      +seg : List<&2, Sigma<&2, &2, String, _ => String>> = rl_take(rl_sweep_budget(), rl_drop(cur, kvs))
      (rl_prune_go(seg, m, now, window), (last, Nat.add(cur, rl_sweep_budget())))

def rl_prune_pass(+cur: Nat, +m: Map<&2, String>, +now: Nat, +window: Nat, +last: Nat) -> Map<&2, String> & Nat & Nat:
  +kvs : List<&2, Sigma<&2, &2, String, _ => String>> = Map.to_list(&2, String, m)
  +n : Nat = rl_list_len(kvs)
  rl_prune_pass_go(Nat.is_ge(Nat.add(cur, rl_sweep_budget()), n), cur, kvs, m, now, window, last)

# Item 133: the O(n) Map.size check now runs only when it can change the
# outcome — no pass in progress (cur >= 1 short-circuits) AND the 60s gate
# open. At most one O(n) size check per 60s; a below-threshold check closes
# the gate (last=now). Def order matters: callees must precede callers.
def rl_maybe_prune_open(size_big: Bool, +m: Map<&2, String>, +now: Nat, +window: Nat, +last: Nat, +cur: Nat) -> Map<&2, String> & Nat & Nat:
  match size_big:
    case True{}: rl_prune_pass(0n, m, now, window, last)
    case False{}: (m, (now, cur))

def rl_maybe_prune_gate(time_ok: Bool, +m: Map<&2, String>, +now: Nat, +window: Nat, +last: Nat, +cur: Nat) -> Map<&2, String> & Nat & Nat:
  match time_ok:
    case True{}: rl_maybe_prune_open(Nat.is_ge(Map.size(&2, String, m), rl_prune_at()), m, now, window, last, cur)
    case False{}: (m, (last, cur))

def rl_maybe_prune_cur(in_progress: Bool, +m: Map<&2, String>, +now: Nat, +window: Nat, +last: Nat, +cur: Nat) -> Map<&2, String> & Nat & Nat:
  match in_progress:
    case True{}: rl_prune_pass(cur, m, now, window, last)
    case False{}: rl_maybe_prune_gate(Nat.is_ge(Nat.sub(now, last), window), m, now, window, last, cur)

def rl_maybe_prune(+m: Map<&2, String>, +now: Nat, +window: Nat, +last: Nat, +cur: Nat) -> Map<&2, String> & Nat & Nat:
  rl_maybe_prune_cur(Nat.is_ge(cur, 1n), m, now, window, last, cur)

def rl_prune_active(due: Bool, +cur: Nat) -> Bool:
  # (item 133: superseded by rl_maybe_prune_cur/gate/open, which evaluate the
  # O(n) Map.size only when no pass is in progress and the 60s gate is open.
  # Kept for API stability; no longer on the per-request path.)
  Bool.or(due, Nat.is_ge(cur, 1n))

# --- key serialization (WAL): kid \t verifier-or-name \t tenant \t role \t expires \t revoked ---

def apikey_rev_show(revoked: Bool) -> String:
  match revoked:
    case True{}: "1"
    case False{}: "0"

def apikey_serialize(+a: Auth) -> String:
  match a:
    case MkAuth{kid, k, t, r, e, rv}:
      kid ++ s_tab() ++ k ++ s_tab() ++ t ++ s_tab() ++ r ++ s_tab() ++ Nat.show(e) ++ s_tab() ++ apikey_rev_show(rv)

def apikey_deser_rv0(is_zero: Bool, +kid: String, +k: String, +t: String, +r: String, +en: Nat) -> Maybe<&1, Auth>:
  match is_zero:
    case True{}: Some{MkAuth{kid, k, t, r, en, False{}}}
    case False{}: None{}

def apikey_deser_rv(is_one: Bool, is_zero: Bool, +kid: String, +k: String, +t: String, +r: String, +en: Nat) -> Maybe<&1, Auth>:
  match is_one:
    case True{}: Some{MkAuth{kid, k, t, r, en, True{}}}
    case False{}: apikey_deser_rv0(is_zero, kid, k, t, r, en)

def apikey_deser_mk_go(men: Maybe<&1, Nat>, +kid: String, +k: String, +t: String, +r: String, +rv: String) -> Maybe<&1, Auth>:
  match men:
    case None{}: None{}
    case Some{en}: apikey_deser_rv(String.eq(rv, "1"), String.eq(rv, "0"), kid, k, t, r, en)

def apikey_deser_mk(+kid: String, +k: String, +t: String, +r: String, +e: String, +rv: String) -> Maybe<&1, Auth>:
  apikey_deser_mk_go(parse_nat_opt(e), kid, k, t, r, rv)

def apikey_deser_rest(+parts: List<&2, String>, +kid: String, +k: String, +t: String, +r: String) -> Maybe<&1, Auth>:
  match parts:
    case Nil{}: None{}
    case e <> t2:
      match t2:
        case Nil{}: None{}
        case rv <> t3:
          match t3:
            case Nil{}: apikey_deser_mk(kid, k, t, r, e, rv)
            case _ <> _: None{}

def apikey_deser_parts(+parts: List<&2, String>) -> Maybe<&1, Auth>:
  match parts:
    case Nil{}: None{}
    case kid <> t:
      match t:
        case Nil{}: None{}
        case k <> t2:
          match t2:
            case Nil{}: None{}
            case tn <> t3:
              match t3:
                case Nil{}: None{}
                case r <> t4: apikey_deser_rest(t4, kid, k, tn, r)

def apikey_deserialize(+s: String) -> Maybe<&1, Auth>:
  apikey_deser_parts(split_char(s, ch_tab()))
