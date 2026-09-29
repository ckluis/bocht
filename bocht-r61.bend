import Base

# med_util.bend — fresh Medium service, part 1: chars, JSON, parsing helpers.
# Pure functions only. Defs precede use. No mutual recursion: every loop is a
# single self-recursive def; computed branch decisions go to NON-recursive
# step helpers that match on Bool PARAMS (match cannot scrutinize computed
# values, and pure code cannot destructure a call result).

# --- single chars ---

def ch_dq() -> Char:
  Char.from_u32(34)

def ch_bs() -> Char:
  Char.from_u32(92)

def ch_lf() -> Char:
  Char.from_u32(10)

def ch_cr() -> Char:
  Char.from_u32(13)

def ch_tab() -> Char:
  Char.from_u32(9)

def s_tab() -> String:
  String.from_list(ch_tab() <> Nil{})

def ch_u() -> Char:
  Char.from_u32(117)

def ch_sp() -> Char:
  Char.from_u32(32)

def ch_dot() -> Char:
  Char.from_u32(46)

def s_dq() -> String:
  String.from_list(ch_dq() <> Nil{})

def s_crlf() -> String:
  String.from_list(ch_cr() <> (ch_lf() <> Nil{}))

# --- JSON string escaping (Bend literals keep backslashes literal) ---

def hex_dig_lt(is_lt: Bool, +v: U32) -> Char:
  match is_lt:
    case True{}: Char.from_u32(U32.add(v, 48))
    case False{}: Char.from_u32(U32.add(U32.sub(v, 10), 97))

def hex_dig(+v: U32) -> Char:
  hex_dig_lt(U32.is_lt(v, 10), v)

def esc_ctrl(+code: U32) -> List<&2, Char>:
  +c : U32 = code
  ch_bs() <> Char.from_u32(117) <> Char.from_u32(48) <> Char.from_u32(48)
    <> hex_dig(U32.div(c, 16)) <> hex_dig(U32.mod(c, 16)) <> Nil{}

def esc_char_ctrl(is_c: Bool, +c: Char) -> List<&2, Char>:
  match is_c:
    case True{}: esc_ctrl(Char.to_u32(c))
    case False{}: c <> Nil{}

def esc_char_bs(is_b: Bool, +c: Char) -> List<&2, Char>:
  match is_b:
    case True{}: ch_bs() <> ch_bs() <> Nil{}
    case False{}: esc_char_ctrl(U32.is_lt(Char.to_u32(c), 32), c)

def esc_char_q(is_q: Bool, +c: Char) -> List<&2, Char>:
  match is_q:
    case True{}: ch_bs() <> ch_dq() <> Nil{}
    case False{}: esc_char_bs(U32.is_eq(Char.to_u32(c), 92), c)

def esc_char(+c: Char) -> List<&2, Char>:
  esc_char_q(U32.is_eq(Char.to_u32(c), 34), c)

def rev_pre(+small: List<&2, Char>, +acc: List<&2, Char>) -> List<&2, Char>:
  match small:
    case Nil{}: acc
    case h <> t: rev_pre(t, h <> acc)

def esc_go(+cs: List<&2, Char>, +acc: List<&2, Char>) -> List<&2, Char>:
  match cs:
    case Nil{}: List.reverse(&2, Char, acc)
    case h <> t: esc_go(t, rev_pre(esc_char(h), acc))

def json_escape(+s: String) -> String:
  String.from_list(esc_go(String.to_list(s), Nil{}))

def jstr(+s: String) -> String:
  s_dq() ++ json_escape(s) ++ s_dq()

def jbool(b: Bool) -> String:
  match b:
    case True{}: "true"
    case False{}: "false"

# --- decimal Nat parsing ---

def dig_val(+c: Char) -> Nat:
  Nat.sub(U32.to_nat(Char.to_u32(c)), 48n)

def is_digit(+c: Char) -> Bool:
  +u : U32 = Char.to_u32(c)
  Bool.and(Bool.not(U32.is_lt(u, 48)), U32.is_lt(u, 58))

def is_hex(+c: Char) -> Bool:
  +u : U32 = Char.to_u32(c)
  Bool.or(is_digit(c),
  Bool.or(Bool.and(Bool.not(U32.is_lt(u, 65)), U32.is_lt(u, 71)),
          Bool.and(Bool.not(U32.is_lt(u, 97)), U32.is_lt(u, 103))))

def is_lower_hex(+c: Char) -> Bool:
  +u : U32 = Char.to_u32(c)
  Bool.or(is_digit(c),
          Bool.and(Bool.not(U32.is_lt(u, 97)), U32.is_lt(u, 103)))

# 2^44 = 17592186044416: saturation cap for untrusted decimal input. The Bend
# native runtime aborts on Nats >= 2^48, so accumulation saturates on VALUE,
# not on digit-string length: once acc >= 2^44 it stays 2^44 (any further
# digit keeps it >= 2^44), and while acc < 2^44, acc*10+9 < 2^44*10+9 < 2^48,
# so the runtime can never see a Nat >= 2^48. Values < 2^44 parse exactly
# regardless of digit count (leading zeros no longer force saturation —
# item 29 fixed the item-28 length-based gate that 413'd legal leading-zero
# Content-Lengths and 400'd leading-zero clap counts). All legitimate values
# (ms timestamps ~1.8e12, seqs, budgets, cursors) are < 2^44 and parse exactly.
def nat_parse_cap() -> Nat:
  Nat.mul(Nat.mul(1024n, 1024n), Nat.mul(1024n, 4096n))

def nat_sat_step_go(is_small: Bool, +acc: Nat, +d: Nat) -> Nat:
  match is_small:
    case True{}: Nat.add(Nat.mul(acc, 10n), d)
    case False{}: nat_parse_cap()

def nat_sat_step(+acc: Nat, +d: Nat) -> Nat:
  nat_sat_step_go(Nat.is_lt(acc, nat_parse_cap()), acc, d)

def parse_nat_go(+cs: List<&2, Char>, +acc: Nat) -> Nat:
  match cs:
    case Nil{}: acc
    case c <> t: parse_nat_go(t, nat_sat_step(acc, dig_val(c)))

def parse_nat(+s: String) -> Nat:
  parse_nat_go(String.to_list(s), 0n)


def all_digits_go(+cs: List<&2, Char>) -> Bool:
  match cs:
    case Nil{}: True{}
    case h <> t: Bool.and(is_digit(h), all_digits_go(t))

def parse_nat_opt_go(ok: Bool, +s: String) -> Maybe<&1, Nat>:
  match ok:
    case True{}: Some{parse_nat(s)}
    case False{}: None{}

def parse_nat_opt(+s: String) -> Maybe<&1, Nat>:
  parse_nat_opt_go(Bool.and(Bool.not(String.is_empty(s)), all_digits_go(String.to_list(s))), s)

# --- find first occurrence of a char ---

def find_char_keep(best: Maybe<&1, Nat>, +pos: Nat) -> Maybe<&1, Nat>:
  match best:
    case None{}: Some{pos}
    case Some{p}: best

def find_char_hit(hit: Bool, +pos: Nat, best: Maybe<&1, Nat>) -> Maybe<&1, Nat>:
  match hit:
    case True{}: find_char_keep(best, pos)
    case False{}: best

def find_char_go(+cs: List<&2, Char>, +pos: Nat, +t: Char, best: Maybe<&1, Nat>) -> Maybe<&1, Nat>:
  match cs:
    case Nil{}: best
    case h <> rest:
      +hh : Char = h
      +rr : List<&2, Char> = rest
      +tt : Char = t
      +pp : Nat = pos
      find_char_go(rr, Nat.add(pp, 1n), tt, find_char_hit(Char.is_eq(hh, tt), pp, best))

def find_char(+s: String, +t: Char) -> Maybe<&1, Nat>:
  find_char_go(String.to_list(s), 0n, t, None{})

# --- tail-recursive split on a char, order-preserving ---
# (String.split is not tail-recursive; on untrusted input it can overflow
# the machine stack. This scanner accumulates pieces reversed and reverses
# ONCE at the end — never a double reverse.)

def split_push(+cur: List<&2, Char>, +acc: List<&2, String>) -> List<&2, String>:
  String.from_list(List.reverse(&2, Char, cur)) <> acc

def split_fin(+cur: List<&2, Char>, +acc: List<&2, String>) -> List<&2, String>:
  List.reverse(&2, String, split_push(cur, acc))

def split_cur_go(is_sep: Bool, +h: Char, +cur: List<&2, Char>) -> List<&2, Char>:
  match is_sep:
    case True{}: Nil{}
    case False{}: h <> cur

def split_cur(+h: Char, +sep: Char, +cur: List<&2, Char>) -> List<&2, Char>:
  split_cur_go(Char.is_eq(h, sep), h, cur)

def split_acc_go(is_sep: Bool, +cur: List<&2, Char>, +acc: List<&2, String>) -> List<&2, String>:
  match is_sep:
    case True{}: split_push(cur, acc)
    case False{}: acc

def split_acc(+h: Char, +sep: Char, +cur: List<&2, Char>, +acc: List<&2, String>) -> List<&2, String>:
  split_acc_go(Char.is_eq(h, sep), cur, acc)

def split_go(+cs: List<&2, Char>, +sep: Char, +cur: List<&2, Char>, +acc: List<&2, String>) -> List<&2, String>:
  match cs:
    case Nil{}: split_fin(cur, acc)
    case h <> t:
      +hh : Char = h
      +cc : List<&2, Char> = cur
      split_go(t, sep, split_cur(hh, sep, cc), split_acc(hh, sep, cc, acc))

def split_char(+s: String, +sep: Char) -> List<&2, String>:
  split_go(String.to_list(s), sep, Nil{}, Nil{})

# join_str: RIGHT-nested non-tail recursion => each ++ copies only its small
# left operand (h ++ sep), so total string work is O(sum of lengths), not
# O(n^2). The old tail-recursive form accumulated (acc ++ sep) ++ h with the
# growing accumulator on the LEFT of ++, copying it on every step (item 16).
# Depth is bounded by callers (<= ~1000 for evt_filter); safe.
def join_str(+xs: List<&2, String>, +sep: String) -> String:
  match xs:
    case Nil{}: ""
    case h <> t:
      match t:
        case Nil{}: h
        case hh <> tt: h ++ sep ++ join_str(t, sep)

# json_esc_ext is pure and NON-recursive (Bool.pick with constant branches is
# safe); json_esc_go makes exactly one recursive call. Never nest recursive
# calls inside Bool.pick branches: Bend evaluates all function arguments
# strictly, so N nested picks with recursion in each branch is O(2^N) per char.
def hex_char_go(is_digit: Bool, +u: U32) -> Char:
  match is_digit:
    case True{}: Char.from_u32(U32.add(48, u))
    case False{}: Char.from_u32(U32.add(87, u))

def hex_char(+u: U32) -> Char:
  hex_char_go(U32.is_lt(u, 10), u)

def json_esc_control(+u: U32, +acc: List<&2, Char>) -> List<&2, Char>:
  hex_char(U32.mod(u, 16)) <> hex_char(U32.div(u, 16)) <> Char.from_u32(48) <> Char.from_u32(48) <> Char.from_u32(117) <> Char.from_u32(92) <> acc

def json_esc_ext(+u: U32, +h: Char, +acc: List<&2, Char>) -> List<&2, Char>:
  Bool.pick(List<&2, Char>, U32.is_eq(u, 34),
    Char.from_u32(34) <> Char.from_u32(92) <> acc,
    Bool.pick(List<&2, Char>, U32.is_eq(u, 92),
      Char.from_u32(92) <> Char.from_u32(92) <> acc,
      Bool.pick(List<&2, Char>, U32.is_eq(u, 10),
        Char.from_u32(110) <> Char.from_u32(92) <> acc,
        Bool.pick(List<&2, Char>, U32.is_eq(u, 9),
          Char.from_u32(116) <> Char.from_u32(92) <> acc,
          Bool.pick(List<&2, Char>, U32.is_eq(u, 13),
            Char.from_u32(114) <> Char.from_u32(92) <> acc,
            Bool.pick(List<&2, Char>, U32.is_eq(u, 8),
              Char.from_u32(98) <> Char.from_u32(92) <> acc,
              Bool.pick(List<&2, Char>, U32.is_eq(u, 12),
                Char.from_u32(102) <> Char.from_u32(92) <> acc,
                Bool.pick(List<&2, Char>, U32.is_lt(u, 32),
                  json_esc_control(u, acc),
                  h <> acc))))))))

def json_esc_go(+cs: List<&2, Char>, +acc: List<&2, Char>) -> List<&2, Char>:
  match cs:
    case Nil{}: List.reverse(&2, Char, acc)
    case h <> t: json_esc_go(t, json_esc_ext(Char.to_u32(h), h, acc))

def json_esc(+s: String) -> String:
  String.from_list(json_esc_go(String.to_list(s), Nil{}))

# --- query string: "a=1&b=2" -> value for key ---

def q_kv_go(+kv: List<&2, String>) -> String & String:
  match kv:
    case Nil{}: ("", "")
    case k <> t:
      match t:
        case Nil{}: (k, "")
        case v <> _: (k, v)

def q_put(+m: Map<&2, String>, kv: String & String) -> Map<&2, String>:
  (k, v) = kv
  Map.set(&2, String, m, k, v)

def q_build(+parts: List<&2, String>, +m: Map<&2, String>) -> Map<&2, String>:
  match parts:
    case Nil{}: m
    case h <> t: q_build(t, q_put(m, q_kv_go(split_char(h, Char.from_u32(61)))))

def q_get_v_go(empty: Bool, +v: String) -> Maybe<&1, String>:
  match empty:
    case True{}: None{}
    case False{}: Some{v}

def q_get_v(+v: String) -> Maybe<&1, String>:
  q_get_v_go(String.is_empty(v), v)

def q_get(mv: Map<&2, String> & String) -> Maybe<&1, String>:
  (m2, v) = mv
  q_get_v(v)

def q_val(+query: String, +key: String) -> Maybe<&1, String>:
  q_get(Map.get(String, "", q_build(split_char(query, Char.from_u32(38)), Map.new(&2, String)), key))

# --- path segments: "/v1/articles/a1" -> ["v1","articles","a1"] ---

def segs_keep(empty: Bool, +h: String, +acc: List<&2, String>) -> List<&2, String>:
  match empty:
    case True{}: acc
    case False{}: h <> acc

def segs_go(+parts: List<&2, String>, +acc: List<&2, String>) -> List<&2, String>:
  match parts:
    case Nil{}: List.reverse(&2, String, acc)
    case h <> t: segs_go(t, segs_keep(String.is_empty(h), h, acc))

def path_segs(+path: String) -> List<&2, String>:
  segs_go(split_char(path, Char.from_u32(47)), Nil{})

# --- join strings with a separator ---

def join_go(+xs: List<&2, String>, +sep: String, +acc: String) -> String:
  match xs:
    case Nil{}: acc
    case h <> t: join_go(t, sep, acc ++ sep ++ h)

def join_with(+xs: List<&2, String>, +sep: String) -> String:
  match xs:
    case Nil{}: ""
    case h <> t: join_go(t, sep, h)

# srv_sha256.bend — pure-Bend SHA-256 (FIPS 180-4).
#
# Purpose: API-key verifiers. The server persists sha256_hex(secret) and
# never the secret itself — not in the WAL, DB, snapshots, or logs.
# Authentication hashes the presented Bearer credential and compares verifiers.
#
# U32.add/and/or/xor/not/shln/shrn compile to native 32-bit JS ops, so one
# hash of a ~100-byte secret is microseconds, not milliseconds.
#
# Input MUST be ASCII (all key material is ASCII by construction: "bk_" ++
# hex, or operator env secrets). Non-ASCII input hashes its codepoints, which
# is deterministic but NOT standard SHA-256.
#
# Bend constraints honored: defs precede use, no mutual recursion, the
# shrinking argument is first and pattern-bound, match never scrutinizes a
# computed value, tuple destructuring only on parameters.

# --- round constants K[0..63]: fractional parts of cbrt(first 64 primes) ---
def sha_ks() -> List<&2, U32>:
  1116352408 <> 1899447441 <> 3049323471 <> 3921009573 <> 961987163 <> 1508970993 <> 2453635748 <> 2870763221 <>
  3624381080 <> 310598401 <> 607225278 <> 1426881987 <> 1925078388 <> 2162078206 <> 2614888103 <> 3248222580 <>
  3835390401 <> 4022224774 <> 264347078 <> 604807628 <> 770255983 <> 1249150122 <> 1555081692 <> 1996064986 <>
  2554220882 <> 2821834349 <> 2952996808 <> 3210313671 <> 3336571891 <> 3584528711 <> 113926993 <> 338241895 <>
  666307205 <> 773529912 <> 1294757372 <> 1396182291 <> 1695183700 <> 1986661051 <> 2177026350 <> 2456956037 <>
  2730485921 <> 2820302411 <> 3259730800 <> 3345764771 <> 3516065817 <> 3600352804 <> 4094571909 <> 275423344 <>
  430227734 <> 506948616 <> 659060556 <> 883997877 <> 958139571 <> 1322822218 <> 1537002063 <> 1747873779 <>
  1955562222 <> 2024104815 <> 2227730452 <> 2361852424 <> 2428436474 <> 2756734187 <> 3204031479 <> 3329325298 <> Nil{}

# --- bitwise helpers ---

def sha_rotr(+x: U32, +n: Nat) -> U32:
  U32.or(U32.shrn(x, n), U32.shln(x, Nat.sub(32n, n)))

def sha_S1(+e: U32) -> U32:
  U32.xor(U32.xor(sha_rotr(e, 6n), sha_rotr(e, 11n)), sha_rotr(e, 25n))

def sha_Ch(+e: U32, +f: U32, +g: U32) -> U32:
  U32.xor(U32.and(e, f), U32.and(U32.not(e), g))

def sha_S0(+a: U32) -> U32:
  U32.xor(U32.xor(sha_rotr(a, 2n), sha_rotr(a, 13n)), sha_rotr(a, 22n))

def sha_Maj(+a: U32, +b: U32, +c: U32) -> U32:
  U32.xor(U32.xor(U32.and(a, b), U32.and(a, c)), U32.and(b, c))

def sha_s0(+x: U32) -> U32:
  U32.xor(U32.xor(sha_rotr(x, 7n), sha_rotr(x, 18n)), U32.shrn(x, 3n))

def sha_s1(+x: U32) -> U32:
  U32.xor(U32.xor(sha_rotr(x, 17n), sha_rotr(x, 19n)), U32.shrn(x, 10n))

# --- indexed access into a List<U32> ---

def sha_at(+i: Nat, +xs: List<&2, U32>) -> U32:
  match i:
    case 0n:
      match xs:
        case Nil{}: 0
        case h <> t: h
    case 1n+p:
      match xs:
        case Nil{}: 0
        case h <> t: sha_at(p, t)

# word i (0..15) of the 64-byte block at byte offset boff, big-endian
def sha_word_at(+padded: List<&2, U32>, +boff: Nat, +i: Nat) -> U32:
  +o : Nat = Nat.add(boff, Nat.mul(i, 4n))
  +b0 : U32 = sha_at(o, padded)
  +b1 : U32 = sha_at(Nat.add(o, 1n), padded)
  +b2 : U32 = sha_at(Nat.add(o, 2n), padded)
  +b3 : U32 = sha_at(Nat.add(o, 3n), padded)
  U32.or(U32.shln(b0, 24n), U32.or(U32.shln(b1, 16n), U32.or(U32.shln(b2, 8n), b3)))

# first 16 schedule words for the block at boff
def sha_w16_go(+padded: List<&2, U32>, +boff: Nat, +n: Nat, +acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n: acc
    case 1n+m: sha_w16_go(padded, boff, m, sha_word_at(padded, boff, m) <> acc)

def sha_w16(+padded: List<&2, U32>, +boff: Nat) -> List<&2, U32>:
  sha_w16_go(padded, boff, 16n, Nil{})

# extend 16 -> 64 schedule words; m counts 47..0, word index i = 63 - m
def sha_append(+ws: List<&2, U32>, +w: U32) -> List<&2, U32>:
  match ws:
    case Nil{}: w <> Nil{}
    case h <> t: h <> sha_append(t, w)

def sha_ext_go(+n: Nat, +ws: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n: ws
    case 1n+m:
      +w2 : U32 = sha_at(Nat.sub(61n, m), ws)
      +w7 : U32 = sha_at(Nat.sub(56n, m), ws)
      +w15 : U32 = sha_at(Nat.sub(48n, m), ws)
      +w16 : U32 = sha_at(Nat.sub(47n, m), ws)
      +w : U32 = U32.add(U32.add(sha_s1(w2), w7), U32.add(sha_s0(w15), w16))
      sha_ext_go(m, sha_append(ws, w))

def sha_sched(+padded: List<&2, U32>, +boff: Nat) -> List<&2, U32>:
  sha_ext_go(48n, sha_w16(padded, boff))

# --- 64-round compression; n counts 64..1, round index i = 63 - m ---
# h0..h7 are both the initial state AND the chaining values added at the end.
# (tuple-typed params must be linear: `+` conflicts with `&` type syntax)

def sha_round_go(+n: Nat, +ws: List<&2, U32>, +ks: List<&2, U32>, +a: U32, +b: U32, +c: U32, +d: U32, +e: U32, +f: U32, +g: U32, +h: U32, h0: U32, h1: U32, h2: U32, h3: U32, h4: U32, h5: U32, h6: U32, h7: U32) -> U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32:
  match n:
    case 0n: (U32.add(h0, a), U32.add(h1, b), U32.add(h2, c), U32.add(h3, d), U32.add(h4, e), U32.add(h5, f), U32.add(h6, g), U32.add(h7, h))
    case 1n+m:
      +i : Nat = Nat.sub(63n, m)
      +w : U32 = sha_at(i, ws)
      +k : U32 = sha_at(i, ks)
      +t1 : U32 = U32.add(U32.add(U32.add(U32.add(h, sha_S1(e)), sha_Ch(e, f, g)), k), w)
      +t2 : U32 = U32.add(sha_S0(a), sha_Maj(a, b, c))
      sha_round_go(m, ws, ks, U32.add(t1, t2), a, b, c, U32.add(d, t1), e, f, g, h0, h1, h2, h3, h4, h5, h6, h7)

def sha_compress(+padded: List<&2, U32>, +boff: Nat, +h0: U32, +h1: U32, +h2: U32, +h3: U32, +h4: U32, +h5: U32, +h6: U32, +h7: U32) -> U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32:
  sha_round_go(64n, sha_sched(padded, boff), sha_ks(), h0, h1, h2, h3, h4, h5, h6, h7, h0, h1, h2, h3, h4, h5, h6, h7)

# --- multi-block loop over n blocks; state threaded as a linear tuple ---

def sha_blocks_go(+n: Nat, +padded: List<&2, U32>, +boff: Nat, t: U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32) -> U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32:
  match n:
    case 0n: t
    case 1n+m:
      match t:
        case (h0, h1, h2, h3, h4, h5, h6, h7):
          sha_blocks_go(m, padded, Nat.add(boff, 64n), sha_compress(padded, boff, h0, h1, h2, h3, h4, h5, h6, h7))

# --- padding ---

def sha_rev_go(+xs: List<&2, U32>, +acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}: acc
    case h <> t: sha_rev_go(t, h <> acc)

def sha_rev(+xs: List<&2, U32>) -> List<&2, U32>:
  sha_rev_go(xs, Nil{})

def sha_bytes_go(+cs: List<&2, Char>, +acc: List<&2, U32>) -> List<&2, U32>:
  match cs:
    case Nil{}: sha_rev(acc)
    case c <> rest: sha_bytes_go(rest, Char.to_u32(c) <> acc)

def sha_bytes(+s: String) -> List<&2, U32>:
  sha_bytes_go(String.to_list(s), Nil{})

def sha_concat(+a: List<&2, U32>, +b: List<&2, U32>) -> List<&2, U32>:
  match a:
    case Nil{}: b
    case h <> t: h <> sha_concat(t, b)

# zero bytes after the 0x80 marker: (64 - ((l + 9) mod 64)) mod 64
def sha_pad_zeros(+l: Nat) -> Nat:
  Nat.mod(Nat.sub(64n, Nat.mod(Nat.add(l, 9n), 64n)), 64n)

def sha_zeros_go(+n: Nat, +acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n: acc
    case 1n+m: sha_zeros_go(m, 0 <> acc)

def sha_lenbytes_go(+n: Nat, +bits: Nat, +acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n: acc
    case 1n+m: sha_lenbytes_go(m, Nat.div(bits, 256n), U32.from_nat(Nat.mod(bits, 256n)) <> acc)

def sha_lenbytes(+l: Nat) -> List<&2, U32>:
  sha_lenbytes_go(8n, Nat.mul(l, 8n), Nil{})

def sha_pad(+bytes: List<&2, U32>, +l: Nat) -> List<&2, U32>:
  sha_concat(bytes, sha_concat(128 <> Nil{}, sha_concat(sha_zeros_go(sha_pad_zeros(l), Nil{}), sha_lenbytes(l))))

# --- hex output ---

def sha_hex_of(+w: U32) -> String:
  String.from_list(
    hex_dig(U32.and(U32.shrn(w, 28n), 15)) <>
    hex_dig(U32.and(U32.shrn(w, 24n), 15)) <>
    hex_dig(U32.and(U32.shrn(w, 20n), 15)) <>
    hex_dig(U32.and(U32.shrn(w, 16n), 15)) <>
    hex_dig(U32.and(U32.shrn(w, 12n), 15)) <>
    hex_dig(U32.and(U32.shrn(w, 8n), 15)) <>
    hex_dig(U32.and(U32.shrn(w, 4n), 15)) <>
    hex_dig(U32.and(w, 15)) <> Nil{})

def sha_hex8(+h0: U32, +h1: U32, +h2: U32, +h3: U32, +h4: U32, +h5: U32, +h6: U32, +h7: U32) -> String:
  sha_hex_of(h0) ++ sha_hex_of(h1) ++ sha_hex_of(h2) ++ sha_hex_of(h3) ++
  sha_hex_of(h4) ++ sha_hex_of(h5) ++ sha_hex_of(h6) ++ sha_hex_of(h7)

def sha_finish(t: U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32) -> String:
  match t:
    case (h0, h1, h2, h3, h4, h5, h6, h7):
      sha_hex8(h0, h1, h2, h3, h4, h5, h6, h7)

# SHA-256 hex digest of an ASCII string. The single public entry point.
def sha256_hex(+s: String) -> String:
  +l : Nat = String.length(s)
  +padded : List<&2, U32> = sha_pad(sha_bytes(s), l)
  +nblocks : Nat = Nat.div(Nat.add(l, Nat.add(9n, sha_pad_zeros(l))), 64n)
  sha_finish(sha_blocks_go(nblocks, padded, 0n, (1779033703, 3144134277, 1013904242, 2773480762, 1359893119, 2600822924, 528734635, 1541459225)))

# med_types.bend — fresh Medium service, part 3: types + field accessors.
# Auth bakes in the kid lesson from the start: `key` is the INTERNAL lookup
# identity (env key name, or verifier "v1$<64 hex>" for managed keys) used
# for authentication, rate limits and logs; `kid` is the STABLE PUBLIC
# identity (env name, or "k_<n>") used for authorship, ownership and claps.
# The raw secret never appears in the DB, WAL, snapshots, or logs.

type Auth is Data:
  MkAuth{kid: String, key: String, tenant: String, role: String, expires: Nat, revoked: Bool}

def auth_kid(+a: Auth) -> String:
  match a:
    case MkAuth{kid, key, tenant, role, expires, revoked}: kid

def auth_key(+a: Auth) -> String:
  match a:
    case MkAuth{kid, key, tenant, role, expires, revoked}: key

def auth_tenant(+a: Auth) -> String:
  match a:
    case MkAuth{kid, key, tenant, role, expires, revoked}: tenant

def auth_role(+a: Auth) -> String:
  match a:
    case MkAuth{kid, key, tenant, role, expires, revoked}: role

def auth_expires(+a: Auth) -> Nat:
  match a:
    case MkAuth{kid, key, tenant, role, expires, revoked}: expires

def auth_revoked(+a: Auth) -> Bool:
  match a:
    case MkAuth{kid, key, tenant, role, expires, revoked}: revoked

# Commit event for the shared-state log (newest first in state, cap 1000).
type Evt is Data:
  MkEvt{seq: Nat, tenant: String, etype: String, payload: String}

def evt_seq(+e: Evt) -> Nat:
  match e:
    case MkEvt{seq, tenant, etype, payload}: seq

def evt_tenant(+e: Evt) -> String:
  match e:
    case MkEvt{seq, tenant, etype, payload}: tenant

def evt_type(+e: Evt) -> String:
  match e:
    case MkEvt{seq, tenant, etype, payload}: etype

def evt_payload(+e: Evt) -> String:
  match e:
    case MkEvt{seq, tenant, etype, payload}: payload

# Parked long-poll subscriber. The Socket travels in a 1-shot Chan(Socket):
# Chan is Data so it can live in MedState; Socket is a law type and cannot
# be a Data constructor field.
type PendSub is Data:
  MkPend{sch: Chan(Socket), tenant: String, cursor: Nat, born: Nat}

def pend_tenant(+p: PendSub) -> String:
  match p:
    case MkPend{sch, tenant, cursor, born}: tenant

def pend_cursor(+p: PendSub) -> Nat:
  match p:
    case MkPend{sch, tenant, cursor, born}: cursor

def pend_born(+p: PendSub) -> Nat:
  match p:
    case MkPend{sch, tenant, cursor, born}: born

def pend_sch(+p: PendSub) -> Chan(Socket):
  match p:
    case MkPend{sch, tenant, cursor, born}: sch

# Assembled request handed to the serialized owner task.
type ReqBody is Data:
  MkReqBody{method: String, path: String, headers: Map<&2, String>, body: String, sockch: Chan(Socket)}

# Owner mailbox: requests from connection handlers, ticks from the ticker.
type OwnMsg is Data:
  ReqM{rb: ReqBody}
  TickM{}

# Whole server state, owned by the single serialized owner task.
# db: tenant-scoped records. keys: lookup-id -> Auth. seq: id counter.
# evlog: newest-first commit events. evseq: monotonic event seq.
# pend: parked long-poll subscribers. rl: lookup-id -> "window_start,count".
# rlprune: ms timestamp of the last rl-map prune (0 = never).
type MedState is Data:
  MkMed{db: Map<&2, String>, keys: Map<&2, Auth>, seq: Nat, evlog: List<&2, Evt>, evseq: Nat, pend: List<&2, PendSub>, rl: Map<&2, String>, snapseq: Nat, rlprune: Nat, rlcur: Nat, restart: Bool, rrl: Nat, krl: Nat}

def st_db(+st: MedState) -> Map<&2, String>:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: db

def st_keys(+st: MedState) -> Map<&2, Auth>:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: keys

def st_seq(+st: MedState) -> Nat:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: seq

def st_evlog(+st: MedState) -> List<&2, Evt>:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: evlog

def st_evseq(+st: MedState) -> Nat:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: evseq

def st_pend(+st: MedState) -> List<&2, PendSub>:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: pend

def st_rl(+st: MedState) -> Map<&2, String>:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: rl

def st_snapseq(+st: MedState) -> Nat:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: snapseq

def st_with_snapseq(+st: MedState, +snapseq: Nat) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq0, rlprune, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_with_db(+st: MedState, +db: Map<&2, String>) -> MedState:
  match st:
    case MkMed{db0, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_with_keys(+st: MedState, +keys: Map<&2, Auth>) -> MedState:
  match st:
    case MkMed{db, keys0, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_with_seq(+st: MedState, +seq: Nat) -> MedState:
  match st:
    case MkMed{db, keys, seq0, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_with_ev(+st: MedState, +evlog: List<&2, Evt>, +evseq: Nat) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog0, evseq0, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_with_pend(+st: MedState, +pend: List<&2, PendSub>) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend0, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_with_rl(+st: MedState, +rl: Map<&2, String>) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl0, snapseq, rlprune, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_rlprune(+st: MedState) -> Nat:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: rlprune

def st_with_rlprune(+st: MedState, +rlprune: Nat) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune0, rlcur, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def st_rlcur(+st: MedState) -> Nat:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: rlcur

def st_with_rlcur(+st: MedState, +rlcur: Nat) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur0, restart, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

# restart: graceful-restart request flag (Round 3 item 19). In-memory only:
# snap_content serializes db/keys/evlog/seq, so this never persists across
# boots and a shutdown snapshot cannot cause a restart loop.
def st_restart(+st: MedState) -> Bool:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: restart

def st_with_restart(+st: MedState, +restart: Bool) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart0, rrl, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

# rrl: per-credential restart rate limit (Round 3 item 20). In-memory config:
# how many POST /v1/admin/restart requests one bearer token may make per
# 60s window. Set once at boot from MEDIUM_RESTART_RL (default 5); never
# changed at runtime and never persisted in snapshots (snap_content only
# serializes db/keys/evlog/seq).
def st_rrl(+st: MedState) -> Nat:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: rrl

def st_with_rrl(+st: MedState, +rrl: Nat) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl0, krl}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

# krl: per-credential key-management rate limit (Round 3 item 21). In-memory
# config: how many mutating key-plane requests (POST /v1/keys create,
# POST /v1/keys/:kid/rotate, POST /v1/keys/:kid/revoke) one Bearer <redacted>
# may make per 60s window. Set once at boot from MEDIUM_KEY_RL (default 5);
# never changed at runtime and never persisted in snapshots (snap_content
# only serializes db/keys/evlog/seq).
def st_krl(+st: MedState) -> Nat:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}: krl

def st_with_krl(+st: MedState, +krl: Nat) -> MedState:
  match st:
    case MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl0}: MkMed{db, keys, seq, evlog, evseq, pend, rl, snapseq, rlprune, rlcur, restart, rrl, krl}

def default_key_rl() -> Nat:
  5n

def default_restart_rl() -> Nat:
  5n

# HTTP head assembly state (forked connection handler).
type HeadSt is Data:
  MkHs{done: Bool, ok: Bool, code: U32, head: String, rest: String, acc: String}

type HGot is Data:
  MkHg{head: String, rest: String, ok: Bool, code: U32}

# HTTP body assembly state.
type BodySt is Data:
  MkBs{done: Bool, rem: Nat, acc: String}

# Content-Length spec.
type BodySpec is Data:
  CLMissing{}
  CLBad{}
  CLOk{n: Nat}

# Parsed request line.
type HeadRes is Data:
  MkHr{method: String, path: String, ver: String}

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

# med_parse.bend — fresh Medium service, part 4: HTTP parsing + responses.
# Pure functions except the socket assembly loops at the end. Adapted from
# the proven framework patterns, with String.split replaced by the
# tail-recursive split_char (untrusted input must not touch String.split).

# --- limits (Nat literals >~1000 expand at compile time; build arithmetically) ---

def head_max() -> Nat:
  Nat.mul(64n, 128n)

def body_max() -> Nat:
  Nat.mul(64n, Nat.mul(64n, 16n))

def req_line_max() -> Nat:
  Nat.mul(64n, 64n)

# --- utf8 byte length ---

def utf8_cl4(is3: Bool) -> Nat:
  match is3:
    case True{}: 3n
    case False{}: 4n

def utf8_cl34(is2: Bool, +b: Nat) -> Nat:
  match is2:
    case True{}: 2n
    case False{}: utf8_cl4(Nat.is_lt(b, Nat.mul(256n, 256n)))

def utf8_cl12(is1: Bool, +b: Nat) -> Nat:
  match is1:
    case True{}: 1n
    case False{}: utf8_cl34(Nat.is_lt(b, Nat.mul(32n, 64n)), b)

def utf8_cln(+b: Nat) -> Nat:
  utf8_cl12(Nat.is_lt(b, 128n), b)

def utf8_char_len(+cu: U32) -> Nat:
  utf8_cln(U32.to_nat(cu))

def utf8_byte_len_go(+cs: List<&2, Char>, +acc: Nat) -> Nat:
  match cs:
    case Nil{}: acc
    case h <> t: utf8_byte_len_go(t, Nat.add(acc, utf8_char_len(Char.to_u32(h))))

def utf8_byte_len(+s: String) -> Nat:
  utf8_byte_len_go(String.to_list(s), 0n)

# --- locate end of HTTP head: index of "\r\n\r\n", or None (tail-recursive) ---

def is_cr(+c: Char) -> Bool:
  U32.is_eq(Char.to_u32(c), 13)

def is_lf(+c: Char) -> Bool:
  U32.is_eq(Char.to_u32(c), 10)

def is_crlf4(+c1: Char, +c2: Char, +c3: Char, +c4: Char) -> Bool:
  Bool.and(is_cr(c1), Bool.and(is_lf(c2), Bool.and(is_cr(c3), is_lf(c4))))

def fcr_hit(hit: Bool, +pos: Nat, best: Maybe<&1, Nat>) -> Maybe<&1, Nat>:
  match hit:
    case True{}: find_char_keep(best, pos)
    case False{}: best

def fcr_go(+cs: List<&2, Char>, +pos: Nat, best: Maybe<&1, Nat>) -> Maybe<&1, Nat>:
  match cs:
    case Nil{}: best
    case c1 <> r1:
      match r1:
        case Nil{}: best
        case c2 <> r2:
          match r2:
            case Nil{}: best
            case c3 <> r3:
              match r3:
                case Nil{}: best
                case c4 <> r4:
                  +cc2 : Char = c2
                  +cc3 : Char = c3
                  +cc4 : Char = c4
                  +rr4 : List<&2, Char> = r4
                  +pp : Nat = pos
                  fcr_go(cc2 <> (cc3 <> (cc4 <> rr4)), Nat.add(pp, 1n), fcr_hit(is_crlf4(c1, cc2, cc3, cc4), pp, best))

def find_head_end(+s: String) -> Maybe<&1, Nat>:
  fcr_go(String.to_list(s), 0n, None{})

# --- header lines ---

type Hdr is Data:
  MkHdr{name: String, val: String}

def hdr_name(+h: Hdr) -> String:
  match h:
    case MkHdr{name, val}: name

def hdr_val(+h: Hdr) -> String:
  match h:
    case MkHdr{name, val}: val

def strip_cr_end(is_cr: Bool, +line: String) -> String:
  match is_cr:
    case True{}: String.take(line, Nat.sub(String.length(line), 1n))
    case False{}: line

def strip_cr(+line: String) -> String:
  strip_cr_end(String.ends_with(line, String.from_list(ch_cr() <> Nil{})), line)

def is_head_end(+h: String) -> Bool:
  String.is_empty(strip_cr(h))

def phl_colon(mpos: Maybe<&1, Nat>, +line: String) -> Hdr:
  match mpos:
    case None{}: MkHdr{"", ""}
    case Some{p}:
      +pp : Nat = p
      +ll : String = line
      MkHdr{String.trim(String.to_lower(String.take(ll, pp))), String.trim(String.drop(ll, Nat.add(pp, 1n)))}

def phl(+line: String) -> Hdr:
  phl_colon(find_char(strip_cr(line), Char.from_u32(58)), strip_cr(line))

def hdr_ok(+h: String) -> Bool:
  Bool.not(String.is_empty(hdr_name(phl(h))))

def find_header_val(mv: Map<&2, String> & String) -> String:
  (m2, v) = mv
  v

def find_header(+hs: Map<&2, String>, +name: String) -> String:
  find_header_val(Map.get(String, "", hs, name))

# --- header block parse: status 0 ok | 1 too_many | 2 malformed | 3 unterminated ---

def hd_fin_ended(is_ended: Bool, +acc: Map<&2, String>, +status: U32) -> Map<&2, String> & U32:
  match is_ended:
    case True{}: (acc, 0)
    case False{}: (acc, status)

def hd_fin_go(is_going: Bool, is_ended: Bool, +acc: Map<&2, String>, +status: U32) -> Map<&2, String> & U32:
  match is_going:
    case True{}: (acc, 3)
    case False{}: hd_fin_ended(is_ended, acc, status)

def hd_fin(+status: U32, +acc: Map<&2, String>) -> Map<&2, String> & U32:
  hd_fin_go(U32.is_eq(status, 0), U32.is_eq(status, 4), acc, status)

def hd_ns_ok(line_ok: Bool) -> U32:
  match line_ok:
    case True{}: 0
    case False{}: 2

def hd_ns_lim(under: Bool, +h: String) -> U32:
  match under:
    case False{}: 1
    case True{}: hd_ns_ok(hdr_ok(h))

def hd_ns_end(is_end: Bool, +count: Nat, +h: String) -> U32:
  match is_end:
    case True{}: 4
    case False{}: hd_ns_lim(Nat.is_lt(count, 32n), h)

def hd_ns_new(+count: Nat, +h: String) -> U32:
  hd_ns_end(is_head_end(h), count, h)

def hd_ns_go(is_going: Bool, +count: Nat, +h: String, +status: U32) -> U32:
  match is_going:
    case False{}: status
    case True{}: hd_ns_new(count, h)

def hd_next_status(+status: U32, +count: Nat, +h: String) -> U32:
  hd_ns_go(U32.is_eq(status, 0), count, h, status)

def hd_acc_end(is_end: Bool, +pr: Hdr, +acc: Map<&2, String>) -> Map<&2, String>:
  match is_end:
    case True{}: acc
    case False{}: Map.set(&2, String, acc, hdr_name(pr), hdr_val(pr))

def hd_acc_go(is_going: Bool, is_end: Bool, +pr: Hdr, +acc: Map<&2, String>) -> Map<&2, String>:
  match is_going:
    case False{}: acc
    case True{}: hd_acc_end(is_end, pr, acc)

def hd_acc(+status: U32, +h: String, +acc: Map<&2, String>) -> Map<&2, String>:
  hd_acc_go(U32.is_eq(status, 0), is_head_end(h), phl(h), acc)

def hd_loop(+lines: List<&2, String>, +count: Nat, +acc: Map<&2, String>, +status: U32) -> Map<&2, String> & U32:
  match lines:
    case Nil{}: hd_fin(status, acc)
    case h <> t:
      +hh : String = h
      +tt : List<&2, String> = t
      +cc : Nat = count
      +aa : Map<&2, String> = acc
      +ss : U32 = status
      hd_loop(tt, Nat.add(cc, 1n), hd_acc(ss, hh, aa), hd_next_status(ss, cc, hh))

def parse_headers(+lines: List<&2, String>) -> Map<&2, String> & U32:
  hd_loop(lines, 0n, Map.new(&2, String), 0)

# --- strict Content-Length extraction ---

# Content-Length saturation cap: 1_000_000. Legitimate CLs are <= 65536
# (body_max); accumulation saturates on VALUE, not digit-string length:
# while n < 1_000_000, n*10+9 < 10_000_009 < 2^48, so the Bend native
# runtime can never see a Nat >= 2^48 (unauthenticated remote DoS before
# item 28). Values < 1_000_000 parse exactly regardless of digit count —
# item 29 fixed the item-28 length-based gate that 413'd legal leading-zero
# Content-Lengths (e.g. "00000026"). Values >= 1_000_000 saturate here and
# 413 via the existing oversize path.
def cl_sat() -> Nat:
  Nat.mul(1000n, 1000n)

def cl_digit_sat_go(is_small: Bool, +n: Nat, +d: Nat) -> Nat:
  match is_small:
    case True{}: Nat.add(Nat.mul(n, 10n), d)
    case False{}: cl_sat()

def cl_digit_sat(+n: Nat, +c: Char) -> Nat:
  cl_digit_sat_go(Nat.is_lt(n, cl_sat()), n, dig_val(c))

def cl_digit_go(is_d: Bool, +n: Nat, +c: Char) -> Maybe<&1, Nat>:
  match is_d:
    case True{}: Some{cl_digit_sat(n, c)}
    case False{}: None{}

def cl_digit(+n: Nat, +c: Char) -> Maybe<&1, Nat>:
  cl_digit_go(is_digit(c), n, c)

def cl_step(acc: Maybe<&1, Nat>, +c: Char) -> Maybe<&1, Nat>:
  match acc:
    case None{}: None{}
    case Some{n}: cl_digit(n, c)

def cl_parse_go(+cs: List<&2, Char>, acc: Maybe<&1, Nat>) -> Maybe<&1, Nat>:
  match cs:
    case Nil{}: acc
    case c <> rest: cl_parse_go(rest, cl_step(acc, c))

def parse_cl_val_res(mn: Maybe<&1, Nat>) -> BodySpec:
  match mn:
    case None{}: CLBad{}
    case Some{n}: CLOk{n}

def parse_cl_val_go(is_empty: Bool, +v: String) -> BodySpec:
  match is_empty:
    case True{}: CLBad{}
    case False{}: parse_cl_val_res(cl_parse_go(String.to_list(v), Some{0n}))

def parse_cl_val(+v: String) -> BodySpec:
  parse_cl_val_go(String.is_empty(v), v)

def get_cl_first_go(is_cl: Bool, +lh: String) -> BodySpec:
  match is_cl:
    case True{}: parse_cl_val(String.trim(strip_cr(String.drop(lh, 15n))))
    case False{}: CLMissing{}

def get_cl_first(+h: String) -> BodySpec:
  get_cl_first_go(String.starts_with(String.to_lower(h), "content-length:"), String.to_lower(h))

def get_cl_dup_eq(is_eq: Bool, +n: Nat) -> BodySpec:
  match is_eq:
    case True{}: CLOk{n}
    case False{}: CLBad{}

def get_cl_dup_cmp(spec: BodySpec, +n: Nat) -> BodySpec:
  match spec:
    case CLMissing{}: CLBad{}
    case CLBad{}: CLBad{}
    case CLOk{m}: get_cl_dup_eq(Nat.is_eq(m, n), n)

def get_cl_dup_val(+h: String, +n: Nat) -> BodySpec:
  get_cl_dup_cmp(parse_cl_val(String.trim(strip_cr(String.drop(String.to_lower(h), 15n)))), n)

def get_cl_dup_go(is_cl: Bool, +h: String, +n: Nat) -> BodySpec:
  match is_cl:
    case True{}: get_cl_dup_val(h, n)
    case False{}: CLOk{n}

def get_cl_dup(+h: String, +n: Nat) -> BodySpec:
  get_cl_dup_go(String.starts_with(String.to_lower(h), "content-length:"), h, n)

def get_cl_step(acc: BodySpec, +h: String) -> BodySpec:
  match acc:
    case CLMissing{}: get_cl_first(h)
    case CLBad{}: CLBad{}
    case CLOk{n}: get_cl_dup(h, n)

def get_cl_go(+lines: List<&2, String>, acc: BodySpec) -> BodySpec:
  match lines:
    case Nil{}: acc
    case h <> t: get_cl_go(t, get_cl_step(acc, h))

def get_cl_spec(+lines: List<&2, String>) -> BodySpec:
  get_cl_go(lines, CLMissing{})

# --- Transfer-Encoding rejection (item 30) ---
# The service never decodes Transfer-Encoding (no chunked reader). Silently
# ignoring it interprets a different message than the client framed: a
# chunk-framed body would be read as raw Content-Length bytes, and a TE-only
# request treated as bodiless -- the canonical request-smuggling
# precondition. RFC 9112 §6.1: a server MUST NOT forward a message carrying
# Transfer-Encoding it does not support. So any Transfer-Encoding header
# whose value is not exactly "identity" (the no-op coding, case-insensitive)
# is rejected here, pre-auth, next to the Content-Length spec extraction.
# "identity" is accepted so compliant clients are not broken.
def te_line_bad_go(is_te: Bool, +rest: String) -> Bool:
  match is_te:
    case True{}: Bool.not(String.eq(String.trim(rest), "identity"))
    case False{}: False{}

def te_line_bad(+h: String) -> Bool:
  te_line_bad_go(String.starts_with(String.to_lower(h), "transfer-encoding:"), String.drop(String.to_lower(h), 18n))

def te_bad_step(bad: Bool, +h: String) -> Bool:
  match bad:
    case True{}: True{}
    case False{}: te_line_bad(h)

def te_bad_go(+lines: List<&2, String>, bad: Bool) -> Bool:
  match lines:
    case Nil{}: bad
    case h <> t: te_bad_go(t, te_bad_step(bad, h))

def te_unsupported(+lines: List<&2, String>) -> Bool:
  te_bad_go(lines, False{})

# --- request line: METHOD SP PATH SP VERSION ---

def check_version(ok: Bool, +m: String, +p: String, +v: String) -> Maybe<&1, HeadRes>:
  match ok:
    case True{}: Some{MkHr{m, p, v}}
    case False{}: None{}

def parse_rl_rest(+t2: List<&2, String>, +m: String, +p: String, +v: String) -> Maybe<&1, HeadRes>:
  match t2:
    case Nil{}: check_version(String.starts_with(v, "HTTP/"), m, p, v)
    case _ <> _: None{}

def parse_rl_parts3(+t: List<&2, String>, +m: String, +p: String) -> Maybe<&1, HeadRes>:
  match t:
    case Nil{}: None{}
    case v <> t2: parse_rl_rest(t2, m, p, v)

def parse_rl_parts2(+t: List<&2, String>, +m: String) -> Maybe<&1, HeadRes>:
  match t:
    case Nil{}: None{}
    case p <> t2: parse_rl_parts3(t2, m, p)

def parse_rl_parts(+parts: List<&2, String>) -> Maybe<&1, HeadRes>:
  match parts:
    case Nil{}: None{}
    case m <> t: parse_rl_parts2(t, m)

def parse_req_line(+line: String) -> Maybe<&1, HeadRes>:
  parse_rl_parts(split_char(line, ch_sp()))
# med_parse.bend, part 2: responses, validation, JSON field extraction,
# and the socket assembly loops (run in the forked connection handler).

# --- HTTP responses ---

def status_text(+code: U32) -> String:
  Bool.pick(String, U32.is_eq(code, 200), "OK",
  Bool.pick(String, U32.is_eq(code, 201), "Created",
  Bool.pick(String, U32.is_eq(code, 202), "Accepted",
  Bool.pick(String, U32.is_eq(code, 400), "Bad Request",
  Bool.pick(String, U32.is_eq(code, 401), "Unauthorized",
  Bool.pick(String, U32.is_eq(code, 403), "Forbidden",
  Bool.pick(String, U32.is_eq(code, 404), "Not Found",
  Bool.pick(String, U32.is_eq(code, 405), "Method Not Allowed",
  Bool.pick(String, U32.is_eq(code, 409), "Conflict",
  Bool.pick(String, U32.is_eq(code, 410), "Gone",
  Bool.pick(String, U32.is_eq(code, 411), "Length Required",
  Bool.pick(String, U32.is_eq(code, 413), "Content Too Large",
  Bool.pick(String, U32.is_eq(code, 414), "URI Too Long",
  Bool.pick(String, U32.is_eq(code, 408), "Request Timeout",
  Bool.pick(String, U32.is_eq(code, 429), "Too Many Requests",
  Bool.pick(String, U32.is_eq(code, 431), "Request Header Fields Too Large",
  Bool.pick(String, U32.is_eq(code, 500), "Internal Server Error",
  Bool.pick(String, U32.is_eq(code, 503), "Service Unavailable", "Unknown"))))))))))))))))))

def http_conn_hdr(keep: Bool) -> String:
  # Round 3 item 183 (HTTP keep-alive): the Connection header is now
  # dynamic. keep=True emits keep-alive; keep=False preserves the
  # historical close behavior. All responses carry Content-Length, so
  # framing is safe for keep-alive reuse.
  Bool.pick(String, keep, "Connection: keep-alive", "Connection: close")

def http_resp_head(+code: U32, +body: String, keep: Bool) -> String:
  # Item 104: RFC 9110 S9.3.2 — a server MUST NOT send a message body in a
  # response to a HEAD request. http_resp_head emits the exact same headers
  # (Content-Length = the would-be body length, which S8.6 permits on HEAD)
  # with NO body bytes. http_resp is headers ++ body (wire format unchanged).
  "HTTP/1.1 " ++ U32.show(code) ++ " " ++ status_text(code) ++ s_crlf()
  ++ "Content-Type: application/json" ++ s_crlf()
  ++ "Content-Length: " ++ Nat.show(utf8_byte_len(body)) ++ s_crlf()
  ++ http_conn_hdr(keep) ++ s_crlf() ++ s_crlf()

def http_resp(+code: U32, +body: String, keep: Bool) -> String:
  http_resp_head(code, body, keep) ++ body

def err_body_json(code: U32, +err: String, +hint: String) -> String:
  "{\"error\":" ++ jstr(err)
  ++ ",\"code\":" ++ U32.show(code)
  ++ ",\"_hint\":" ++ jstr(hint)
  ++ ",\"_links\":{\"help\":\"/help\",\"schema\":\"/schema\"}}"

def http_err(+code: U32, +msg: String, +hint: String, keep: Bool) -> String:
  http_resp(code, err_body_json(code, msg, hint), keep)

def http_err_head(+code: U32, +msg: String, +hint: String, keep: Bool) -> String:
  # Item 104: headers-only error response for HEAD requests (RFC 9110 S9.3.2).
  http_resp_head(code, err_body_json(code, msg, hint), keep)

# First token of the first head line — the request method token as sent on
# the wire. Used to suppress response bodies for HEAD requests on error
# paths where only the raw head text is available (item 104).
def head_tok_line(+toks: List<&2, String>) -> String:
  match toks:
    case Nil{}: ""
    case h <> _: h

def head_first_line(+lines: List<&2, String>) -> String:
  match lines:
    case Nil{}: ""
    case h <> _: h

def head_method_token(+head: String) -> String:
  head_tok_line(split_char(strip_cr(head_first_line(split_char(head, ch_lf()))), ch_sp()))

# First 5 wire bytes of the head accumulator. The 431 cap-trip paths
# (hs_add_big/hs_add_done) deliberately discard the raw head to bound memory;
# they stash head_tok5(acc) in the HeadSt `head` field instead, which is
# exactly enough to decide method=="HEAD" (token "HEAD" <=> prefix "HEAD ").
def head_tok5(+s: String) -> String:
  String.take(s, 5n)

def http_ok(+body: String, keep: Bool) -> String:
  http_resp(200, body, keep)

def http_created(+body: String, keep: Bool) -> String:
  http_resp(201, body, keep)

def http_html(+body: String, keep: Bool) -> String:
  "HTTP/1.1 200 OK" ++ s_crlf() ++ "Content-Type: text/html; charset=utf-8" ++ s_crlf()
  ++ "Content-Length: " ++ Nat.show(utf8_byte_len(body)) ++ s_crlf()
  ++ http_conn_hdr(keep) ++ s_crlf() ++ s_crlf() ++ body

def ka_want_ver_go(is_close: Bool, is_ka: Bool, is_11: Bool) -> Bool:
  # Round 3 item 183: RFC 9112 keep-alive defaults.
  # - `Connection: close` -> close (always wins).
  # - `Connection: keep-alive` -> keep alive (explicit opt-in, any version).
  # - otherwise -> keep alive iff HTTP/1.1 (default); HTTP/1.0 and others close.
  match is_close:
    case True{}: False{}
    case False{}:
      match is_ka:
        case True{}: True{}
        case False{}: is_11

def ka_want_ver(+ver: String, +headers: Map<&2, String>) -> Bool:
  +conn_v : String = find_header(headers, "connection")
  ka_want_ver_go(String.eq(String.to_lower(conn_v), "close"), String.eq(String.to_lower(conn_v), "keep-alive"), String.eq(ver, "HTTP/1.1"))

def ka_want_of(+headers: Map<&2, String>) -> Bool:
  ka_want_ver("HTTP/1.0", headers)

# --- field validation: 1-64 chars, alnum + _ . - ---

def is_alnum(+code: U32) -> Bool:
  Bool.or(Bool.and(U32.is_ge(code, 48), U32.is_le(code, 57)),
  Bool.or(Bool.and(U32.is_ge(code, 65), U32.is_le(code, 90)),
          Bool.and(U32.is_ge(code, 97), U32.is_le(code, 122))))

def valid_name_code(+code: U32) -> Bool:
  Bool.or(is_alnum(code),
  Bool.or(U32.is_eq(code, 95),
  Bool.or(U32.is_eq(code, 46), U32.is_eq(code, 45))))

def valid_name_char(c: Char) -> Bool:
  valid_name_code(Char.to_u32(c))

def all_valid_name(+cs: List<&2, Char>) -> Bool:
  match cs:
    case Nil{}: True{}
    case c <> t: Bool.and(valid_name_char(c), all_valid_name(t))

def valid_name_go(ok: Bool, +s: String) -> Bool:
  match ok:
    case True{}: all_valid_name(String.to_list(s))
    case False{}: False{}

def valid_name(+s: String) -> Bool:
  valid_name_go(Bool.and(Nat.is_ge(String.length(s), 1n), Nat.is_le(String.length(s), 64n)), s)

# Article titles: free text (spaces/punctuation allowed), but no control
# characters (they would corrupt logs and the tab-separated WAL format).
def valid_title_char(c: Char) -> Bool:
  +code : U32 = Char.to_u32(c)
  Bool.and(U32.is_ge(code, 32), Bool.not(U32.is_eq(code, 127)))

def all_valid_title(+cs: List<&2, Char>) -> Bool:
  match cs:
    case Nil{}: True{}
    case c <> t: Bool.and(valid_title_char(c), all_valid_title(t))

def valid_title_go(ok: Bool, +s: String) -> Bool:
  match ok:
    case True{}: all_valid_title(String.to_list(s))
    case False{}: False{}

def valid_title(+s: String) -> Bool:
  valid_title_go(Bool.and(Nat.is_ge(String.length(s), 1n), Nat.is_le(String.length(s), 200n)), s)

# Tenant names: 1-32 chars, alnum plus dash/underscore. Control characters,
# tabs and newlines would corrupt the tab-separated WAL/KEY records, so
# they are rejected here (Round 2 item 9).
def valid_tenant_code(+code: U32) -> Bool:
  Bool.or(is_alnum(code),
  Bool.or(U32.is_eq(code, 45), U32.is_eq(code, 95)))

def valid_tenant_char(c: Char) -> Bool:
  valid_tenant_code(Char.to_u32(c))

def all_valid_tenant(+cs: List<&2, Char>) -> Bool:
  match cs:
    case Nil{}: True{}
    case c <> t: Bool.and(valid_tenant_char(c), all_valid_tenant(t))

def valid_tenant_go(ok: Bool, +s: String) -> Bool:
  match ok:
    case True{}: all_valid_tenant(String.to_list(s))
    case False{}: False{}

def valid_tenant(+s: String) -> Bool:
  valid_tenant_go(Bool.and(Nat.is_ge(String.length(s), 1n), Nat.is_le(String.length(s), 32n)), s)

# --- top-level JSON key search (item 97) ---
# The old find_sub matched `"name"` anywhere in the raw body, including inside
# string literals (via an escaped-quote boundary, e.g. "ab\"count") and inside
# nested objects/arrays. Both let unintended content shadow or hide the real
# top-level field: {"x":"ab\"count", "count": 3} lost the real count (default
# +1), {"ab\"count": 5, "count": 3} applied 5, {"a":{"count":5},"count":3}
# applied the nested 5. jf_find_key scans the body once: it skips string
# literals (escape-aware, so \" never opens/closes a string) and only accepts
# a key at brace depth 1. First top-level occurrence wins (item 68 preserved).
type JfSs is Data:
  SsTop{depth: Nat}   # outside a string; depth counts { [ nesting
  SsStr{depth: Nat}   # inside a string literal
  SsEsc{depth: Nat}   # inside a string, previous char was a backslash

def jfk_is_q(+h: Char) -> Bool:
  U32.is_eq(Char.to_u32(h), 34)

def jfk_is_bs(+h: Char) -> Bool:
  U32.is_eq(Char.to_u32(h), 92)

def jfk_is_open(+h: Char) -> Bool:
  +u : U32 = Char.to_u32(h)
  Bool.or(U32.is_eq(u, 123), U32.is_eq(u, 91))

def jfk_is_close(+h: Char) -> Bool:
  +u : U32 = Char.to_u32(h)
  Bool.or(U32.is_eq(u, 125), U32.is_eq(u, 93))

# does pt match the char list t at its head? (single recursion; the two-list
# comparison is split into total head/tail helpers because Bend forbids
# matching a parameter inside another match arm and forbids mutual recursion)
def jf_pt_empty(+pt: List<&2, Char>) -> Bool:
  match pt:
    case Nil{}: True{}
    case _ <> _: False{}

def jf_hd(+d: Char, +l: List<&2, Char>) -> Char:
  match l:
    case Nil{}: d
    case h <> _: h

def jf_tl(+l: List<&2, Char>) -> List<&2, Char>:
  match l:
    case Nil{}: Nil{}
    case _ <> t: t

# jf_match_wkr (Fresh Round 3 item 97 perf fix): the PATTERN drives the
# recursion — it stops the moment the pattern is exhausted, so each call
# costs O(|pat|), not O(remaining body). The previous version recursed on
# the BODY tail t (jf_match_wkr(t2, jf_tl(pt))): once pt hit Nil, jf_tl(Nil)
# = Nil kept the recursion walking the entire rest of the body, and since
# jf_match_pat is evaluated at every top-level char (strict Bool.and in
# jf_scan), the full key scan was O(n^2) — a 5000-key body took 23.2s on
# r31 vs 0.1s on r30 (item25 C12). Shrinking arg (pt) is first and
# pattern-bound, per the termination rule; the inner match scrutinizes t,
# a function parameter (allowed). Same prefix-match semantics as before.
def jf_match_wkr(+pt: List<&2, Char>, +t: List<&2, Char>) -> Bool:
  match pt:
    case Nil{}: True{}
    case ph <> pt2:
      match t:
        case Nil{}: False{}
        case h <> t2:
          Bool.pick(Bool, U32.is_eq(Char.to_u32(h), Char.to_u32(ph)),
            jf_match_wkr(pt2, t2), False{})

def jf_match_pat(+h: Char, +t: List<&2, Char>, +pat: List<&2, Char>) -> Bool:
  match pat:
    case Nil{}: True{}
    case ph <> pt:
      Bool.and(U32.is_eq(Char.to_u32(h), Char.to_u32(ph)), jf_match_wkr(pt, t))

def jf_found_upd(should: Bool, found: Maybe<&1, Nat>, +pos: Nat) -> Maybe<&1, Nat>:
  match found:
    case Some{p}: Some{p}
    case None{}: Bool.pick(Maybe<&1, Nat>, should, Some{pos}, None{})

def jf_next_top(is_q: Bool, is_open: Bool, is_close: Bool, +depth: Nat) -> JfSs:
  +d : Nat = depth
  Bool.pick(JfSs, is_q, SsStr{d},
    Bool.pick(JfSs, is_open, SsTop{Nat.add(d, 1n)},
      Bool.pick(JfSs, is_close, SsTop{Nat.sub(d, 1n)}, SsTop{d})))

def jf_next_str(is_q: Bool, is_bs: Bool, +depth: Nat) -> JfSs:
  +d : Nat = depth
  Bool.pick(JfSs, is_q, SsTop{d},
    Bool.pick(JfSs, is_bs, SsEsc{d}, SsStr{d}))

def jf_scan(+cs: List<&2, Char>, +pos: Nat, +st: JfSs, +pat: List<&2, Char>, found: Maybe<&1, Nat>) -> Maybe<&1, Nat>:
  match cs:
    case Nil{}: found
    case h <> t:
      match st:
        case SsTop{depth}:
          +tt : List<&2, Char> = t
          +pp : Nat = pos
          +dd : Nat = depth
          jf_scan(tt, Nat.add(pp, 1n),
            jf_next_top(jfk_is_q(h), jfk_is_open(h), jfk_is_close(h), dd),
            pat,
            jf_found_upd(Bool.and(jfk_is_q(h), Bool.and(jf_match_pat(h, tt, pat), Nat.is_eq(dd, 1n))), found, pp))
        case SsStr{depth}:
          +tt : List<&2, Char> = t
          jf_scan(tt, Nat.add(pos, 1n), jf_next_str(jfk_is_q(h), jfk_is_bs(h), depth), pat, found)
        case SsEsc{depth}:
          +tt : List<&2, Char> = t
          jf_scan(tt, Nat.add(pos, 1n), SsStr{depth}, pat, found)

def jf_pat(+name: String) -> String:
  s_dq() ++ name ++ s_dq()

# --- minimal JSON string-field extractor ---
# jf_field(body, "title"): value of the first top-level "title":"..." pair,
# or None. Key lookup is string- and depth-aware (jf_find_key). Handles
# \" \\ \n \t \r escapes. Bodies are small and machine-made; this is
# deliberately NOT a full JSON parser.

def jf_find_key(+body: String, +name: String) -> Maybe<&1, Nat>:
  +cs : List<&2, Char> = String.to_list(body)
  jf_scan(cs, 0n, SsTop{0n}, String.to_list(jf_pat(name)), None{})

def jf_is_ws(+c: Char) -> Bool:
  +u : U32 = Char.to_u32(c)
  Bool.or(U32.is_eq(u, 32), Bool.or(U32.is_eq(u, 9), Bool.or(U32.is_eq(u, 10), U32.is_eq(u, 13))))

def jf_skip_ws(+cs: List<&2, Char>) -> List<&2, Char>:
  match cs:
    case Nil{}: Nil{}
    case h <> t: Bool.pick(List<&2, Char>, jf_is_ws(h), jf_skip_ws(t), h <> t)

def jf_colon_go(is_colon: Bool, +t: List<&2, Char>) -> Maybe<&1, List<&2, Char>>:
  match is_colon:
    case True{}: Some{jf_skip_ws(t)}
    case False{}: None{}

def jf_expect_colon(+cs: List<&2, Char>) -> Maybe<&1, List<&2, Char>>:
  match cs:
    case Nil{}: None{}
    case h <> t: jf_colon_go(U32.is_eq(Char.to_u32(h), 58), t)

def jf_unesc_r(is_r: Bool, +h: Char) -> Char:
  match is_r:
    case True{}: ch_cr()
    case False{}: h

def jf_unesc_ff(is_f: Bool, +h: Char) -> Char:
  match is_f:
    case True{}: Char.from_u32(12)
    case False{}: jf_unesc_r(U32.is_eq(Char.to_u32(h), 114), h)

def jf_unesc_bs(is_b2: Bool, +h: Char) -> Char:
  match is_b2:
    case True{}: Char.from_u32(8)
    case False{}: jf_unesc_ff(U32.is_eq(Char.to_u32(h), 102), h)

def jf_unesc_t(is_t: Bool, +h: Char) -> Char:
  match is_t:
    case True{}: ch_tab()
    case False{}: jf_unesc_bs(U32.is_eq(Char.to_u32(h), 98), h)

def jf_unesc_n(is_n: Bool, +h: Char) -> Char:
  match is_n:
    case True{}: ch_lf()
    case False{}: jf_unesc_t(U32.is_eq(Char.to_u32(h), 116), h)

def jf_unesc_q(is_q: Bool, +h: Char) -> Char:
  match is_q:
    case True{}: ch_dq()
    case False{}: jf_unesc_n(U32.is_eq(Char.to_u32(h), 110), h)

def jf_unesc_b(is_b: Bool, +h: Char) -> Char:
  match is_b:
    case True{}: ch_bs()
    case False{}: jf_unesc_q(U32.is_eq(Char.to_u32(h), 34), h)

def jf_unesc(+h: Char) -> Char:
  jf_unesc_b(U32.is_eq(Char.to_u32(h), 92), h)

def jf_is_quote(+h: Char) -> Bool:
  U32.is_eq(Char.to_u32(h), 34)

def jf_is_bs(+h: Char) -> Bool:
  U32.is_eq(Char.to_u32(h), 92)

# --- \uXXXX pre-pass for JSON strings ---
# jf_str_go is the only recursive def allowed in the string scanner
# (mutual recursion is banned, and its 1-char peek cannot span the 4 hex
# digits of a \u escape). So jf_preu, a separate single-recursive def,
# rewrites \uXXXX sequences to their chars BEFORE jf_str_go runs.
# Branch decisions travel as state DATA (PreSt): each iteration precomputes
# the NEXT head's classification via non-recursive leaf helpers
# (jf_preu_cls_norm/jf_preu_cls_esc); jf_preu matches only on params and
# arm-bound fields and recurses directly. A `+` let-bind must sit INSIDE
# the match arm that uses it, never before the match (it breaks param
# scrutinees). \\u0041 passes through as literal \u0041 (the second
# backslash is an escaped char, so u never becomes an introducer); a
# malformed \u (fewer than 4 hex digits) is emitted literally and then
# subject to jf_unesc like any other unknown escape. Surrogate halves
# (\uD800-\uDFFF) are treated as malformed \u: decoding one to a Char
# would emit CESU-8 (invalid UTF-8) in responses, so the escape passes
# through literally instead. Surrogate pairs are therefore never combined
# (each half degrades to its literal spelling independently).

type PreURes is Data:
  PuUni{v: Nat}
  PuPair{v: Nat}  # combined surrogate pair -> supplementary-plane scalar
  PuLit{}
  PuOther{}

def jf_is_u(+h: Char) -> Bool:
  U32.is_eq(Char.to_u32(h), 117)

def hex_val_au_go(is_up: Bool, +hc: Nat) -> Maybe<&1, Nat>:
  match is_up:
    case True{}: Some{Nat.add(Nat.sub(hc, 65n), 10n)}
    case False{}: None{}

def hex_val_au(+hc: Nat) -> Maybe<&1, Nat>:
  hex_val_au_go(Bool.and(Nat.is_lt(64n, hc), Nat.is_lt(hc, 71n)), hc)

def hex_val_af_go(is_lo: Bool, +hc: Nat) -> Maybe<&1, Nat>:
  match is_lo:
    case True{}: Some{Nat.add(Nat.sub(hc, 97n), 10n)}
    case False{}: hex_val_au(hc)

def hex_val_af(+hc: Nat) -> Maybe<&1, Nat>:
  hex_val_af_go(Bool.and(Nat.is_lt(96n, hc), Nat.is_lt(hc, 103n)), hc)

def hex_val_go(is_dig: Bool, +hc: Nat) -> Maybe<&1, Nat>:
  match is_dig:
    case True{}: Some{Nat.sub(hc, 48n)}
    case False{}: hex_val_af(hc)

def hex_val(+hc: Nat) -> Maybe<&1, Nat>:
  hex_val_go(Bool.and(Nat.is_lt(47n, hc), Nat.is_lt(hc, 58n)), hc)

def jf_hex4_d4(m4: Maybe<&1, Nat>, +d1: Nat, +d2: Nat, +d3: Nat) -> Maybe<&1, Nat>:
  match m4:
    case None{}: None{}
    case Some{d4}: Some{Nat.add(Nat.add(Nat.mul(d1, 4096n), Nat.mul(d2, 256n)), Nat.add(Nat.mul(d3, 16n), d4))}

def jf_hex4_d3(m3: Maybe<&1, Nat>, +d1: Nat, +d2: Nat, m4: Maybe<&1, Nat>) -> Maybe<&1, Nat>:
  match m3:
    case None{}: None{}
    case Some{d3}: jf_hex4_d4(m4, d1, d2, d3)

def jf_hex4_d2(m2: Maybe<&1, Nat>, +d1: Nat, m3: Maybe<&1, Nat>, m4: Maybe<&1, Nat>) -> Maybe<&1, Nat>:
  match m2:
    case None{}: None{}
    case Some{d2}: jf_hex4_d3(m3, d1, d2, m4)

def jf_hex4_d1(m1: Maybe<&1, Nat>, m2: Maybe<&1, Nat>, m3: Maybe<&1, Nat>, m4: Maybe<&1, Nat>) -> Maybe<&1, Nat>:
  match m1:
    case None{}: None{}
    case Some{d1}: jf_hex4_d2(m2, d1, m3, m4)

def jf_hex1(+c: Char) -> Maybe<&1, Nat>:
  hex_val(U32.to_nat(Char.to_u32(c)))

def jf_hex4(+cs: List<&2, Char>) -> Maybe<&1, Nat>:
  match cs:
    case Nil{}: None{}
    case c1 <> r1:
      match r1:
        case Nil{}: None{}
        case c2 <> r2:
          match r2:
            case Nil{}: None{}
            case c3 <> r3:
              match r3:
                case Nil{}: None{}
                case c4 <> r4: jf_hex4_d1(jf_hex1(c1), jf_hex1(c2), jf_hex1(c3), jf_hex1(c4))

# jf_hex4t: like jf_hex4 but also returns the chars after the 4 hex digits,
# so the surrogate-pair check can look for a following \uXXXX low surrogate.
# (Item 96: \uD83C\uDF0D must decode to U+1F30D per RFC 8259.)
def jf_hex4t_d4(m4: Maybe<&1, Nat>, +d1: Nat, +d2: Nat, +d3: Nat, +tail: List<&2, Char>) -> Maybe<&1, Nat & List<&2, Char>>:
  match m4:
    case None{}: None{}
    case Some{d4}: Some{(Nat.add(Nat.add(Nat.mul(d1, 4096n), Nat.mul(d2, 256n)), Nat.add(Nat.mul(d3, 16n), d4)), tail)}

def jf_hex4t_d3(m3: Maybe<&1, Nat>, +d1: Nat, +d2: Nat, m4: Maybe<&1, Nat>, +tail: List<&2, Char>) -> Maybe<&1, Nat & List<&2, Char>>:
  match m3:
    case None{}: None{}
    case Some{d3}: jf_hex4t_d4(m4, d1, d2, d3, tail)

def jf_hex4t_d2(m2: Maybe<&1, Nat>, +d1: Nat, m3: Maybe<&1, Nat>, m4: Maybe<&1, Nat>, +tail: List<&2, Char>) -> Maybe<&1, Nat & List<&2, Char>>:
  match m2:
    case None{}: None{}
    case Some{d2}: jf_hex4t_d3(m3, d1, d2, m4, tail)

def jf_hex4t_d1(m1: Maybe<&1, Nat>, m2: Maybe<&1, Nat>, m3: Maybe<&1, Nat>, m4: Maybe<&1, Nat>, +tail: List<&2, Char>) -> Maybe<&1, Nat & List<&2, Char>>:
  match m1:
    case None{}: None{}
    case Some{d1}: jf_hex4t_d2(m2, d1, m3, m4, tail)

def jf_hex4t(+cs: List<&2, Char>) -> Maybe<&1, Nat & List<&2, Char>>:
  match cs:
    case Nil{}: None{}
    case c1 <> r1:
      match r1:
        case Nil{}: None{}
        case c2 <> r2:
          match r2:
            case Nil{}: None{}
            case c3 <> r3:
              match r3:
                case Nil{}: None{}
                case c4 <> r4: jf_hex4t_d1(jf_hex1(c1), jf_hex1(c2), jf_hex1(c3), jf_hex1(c4), r4)

# Surrogate-pair handling (Item 96, RFC 8259 section 7): \uHHHH\uLLLL where
# HHHH is a high surrogate (D800-DBFF) and LLLL is a low surrogate (DC00-DFFF)
# decodes to the single supplementary-plane scalar value
# U+10000 + ((HHHH-D800)<<10) + (LLLL-DC00), which is valid UTF-8 (not
# CESU-8). A lone surrogate (high without a following low, or a low without
# a preceding high) is not a valid Unicode scalar: it passes through as
# PuLit (literal; jf_preu doubles the backslash so jf_str_go preserves it).
# (Item 42 updated by item 96.)
def jf_low_sur_rng(is_low: Bool, +v: Nat) -> Maybe<&1, Nat>:
  match is_low:
    case True{}: Some{v}
    case False{}: None{}

def jf_low_sur_val_go(+v: Nat) -> Maybe<&1, Nat>:
  jf_low_sur_rng(Bool.and(Nat.is_ge(v, 56320n), Nat.is_le(v, 57343n)), v)

def jf_low_sur_val(mv: Maybe<&1, Nat>) -> Maybe<&1, Nat>:
  match mv:
    case None{}: None{}
    case Some{v}: jf_low_sur_val_go(v)

def jf_low_sur_go(is_bs: Bool, is_u: Bool, +r2: List<&2, Char>) -> Maybe<&1, Nat>:
  match is_bs:
    case False{}: None{}
    case True{}:
      match is_u:
        case False{}: None{}
        case True{}: jf_low_sur_val(jf_hex4(r2))

def jf_low_sur(+cs: List<&2, Char>) -> Maybe<&1, Nat>:
  match cs:
    case Nil{}: None{}
    case b <> r1:
      match r1:
        case Nil{}: None{}
        case u <> r2: jf_low_sur_go(U32.is_eq(Char.to_u32(b), 92), U32.is_eq(Char.to_u32(u), 117), r2)

def jf_preu_pair_go(mlow: Maybe<&1, Nat>, +v: Nat) -> PreURes:
  match mlow:
    case None{}: PuLit{}
    case Some{low}: PuPair{Nat.add(65536n, Nat.add(Nat.mul(Nat.sub(v, 55296n), 1024n), Nat.sub(low, 56320n)))}

def jf_preu_pair(+v: Nat, +tail: List<&2, Char>) -> PreURes:
  jf_preu_pair_go(jf_low_sur(tail), v)

def jf_preu_sur_go2(is_sur: Bool, +v: Nat) -> PreURes:
  match is_sur:
    case True{}: PuLit{}
    case False{}: PuUni{v}

def jf_preu_sur2(+v: Nat) -> PreURes:
  jf_preu_sur_go2(Bool.and(Nat.is_ge(v, 55296n), Nat.is_le(v, 57343n)), v)

def jf_preu_high(is_high: Bool, +v: Nat, +tail: List<&2, Char>) -> PreURes:
  match is_high:
    case True{}: jf_preu_pair(v, tail)
    case False{}: jf_preu_sur2(v)

def jf_preu_sur(+v: Nat, +tail: List<&2, Char>) -> PreURes:
  jf_preu_high(Bool.and(Nat.is_ge(v, 55296n), Nat.is_le(v, 56319n)), v, tail)

def jf_preu_mv_go(p: Nat & List<&2, Char>) -> PreURes:
  (v, tail) = p
  jf_preu_sur(v, tail)

def jf_preu_mv(mvt: Maybe<&1, Nat & List<&2, Char>>) -> PreURes:
  match mvt:
    case None{}: PuLit{}
    case Some{p}: jf_preu_mv_go(p)

def jf_preu_res_go(is_u: Bool, mvt: Maybe<&1, Nat & List<&2, Char>>) -> PreURes:
  match is_u:
    case True{}: jf_preu_mv(mvt)
    case False{}: PuOther{}

def jf_preu_res(+h: Char, +t: List<&2, Char>) -> PreURes:
  jf_preu_res_go(jf_is_u(h), jf_hex4t(t))

type PreSt is Data:
  PreNorm{}              # head is an ordinary char: emit it
  PreBs{}                # head is a backslash: consume it, next head is escaped
  PreEscC{}              # head is an escaped non-u char: emit \ then head
  PreEscU{res: PreURes}  # head is an escaped u: res decides decode vs literal
  PreSkip{n: Nat}        # drop head, decrement; at 1 drop and resume normal

# Non-recursive classifiers: each iteration precomputes the NEXT head's state
# as data (the JfAct pattern), so the single recursive def below only matches
# on params and arm-bound fields. Defs precede use; no mutual recursion.
def jf_preu_cls_norm_go(is_bs: Bool) -> PreSt:
  match is_bs:
    case True{}: PreBs{}
    case False{}: PreNorm{}

def jf_preu_cls_norm(+t: List<&2, Char>) -> PreSt:
  match t:
    case Nil{}: PreNorm{}
    case h2 <> t2: jf_preu_cls_norm_go(jf_is_bs(h2))

def jf_preu_cls_esc_go(is_u: Bool, +h2: Char, +t2: List<&2, Char>) -> PreSt:
  match is_u:
    case True{}: PreEscU{jf_preu_res(h2, t2)}
    case False{}: PreEscC{}

def jf_preu_cls_esc(+t: List<&2, Char>) -> PreSt:
  match t:
    case Nil{}: PreEscC{}
    case h2 <> t2: jf_preu_cls_esc_go(jf_is_u(h2), h2, t2)

def jf_preu_end_u(res: PreURes, +acc: List<&2, Char>) -> List<&2, Char>:
  match res:
    case PuUni{v}: List.reverse(&2, Char, Char.from_u32(U32.from_nat(v)) <> acc)
    case PuPair{v}: List.reverse(&2, Char, Char.from_u32(U32.from_nat(v)) <> acc)
    case PuLit{}: List.reverse(&2, Char, ch_u() <> (ch_bs() <> (ch_bs() <> acc)))
    case PuOther{}: List.reverse(&2, Char, ch_u() <> (ch_bs() <> (ch_bs() <> acc)))

def jf_preu_end(st: PreSt, +acc: List<&2, Char>) -> List<&2, Char>:
  match st:
    case PreNorm{}: List.reverse(&2, Char, acc)
    case PreBs{}: List.reverse(&2, Char, ch_bs() <> acc)
    case PreEscC{}: List.reverse(&2, Char, ch_bs() <> acc)
    case PreEscU{res}: jf_preu_end_u(res, acc)
    case PreSkip{n}: List.reverse(&2, Char, acc)

def jf_preu(+cs: List<&2, Char>, +acc: List<&2, Char>, +st: PreSt) -> List<&2, Char>:
  match cs:
    case Nil{}: jf_preu_end(st, acc)
    case h <> t:
      match st:
        case PreNorm{}:
          +tt : List<&2, Char> = t
          jf_preu(tt, h <> acc, jf_preu_cls_norm(tt))
        case PreBs{}:
          +tt : List<&2, Char> = t
          jf_preu(tt, acc, jf_preu_cls_esc(tt))
        case PreEscC{}:
          +tt : List<&2, Char> = t
          jf_preu(tt, h <> (ch_bs() <> acc), jf_preu_cls_norm(tt))
        case PreEscU{res}:
          match res:
            case PuUni{v}:
              +tt : List<&2, Char> = t
              jf_preu(tt, Char.from_u32(U32.from_nat(v)) <> acc, PreSkip{4n})
            case PuPair{v}:
              +tt : List<&2, Char> = t
              jf_preu(tt, Char.from_u32(U32.from_nat(v)) <> acc, PreSkip{10n})
            case PuLit{}:
              +tt : List<&2, Char> = t
              jf_preu(tt, ch_u() <> (ch_bs() <> (ch_bs() <> acc)), jf_preu_cls_norm(tt))
            case PuOther{}:
              +tt : List<&2, Char> = t
              jf_preu(tt, ch_u() <> (ch_bs() <> (ch_bs() <> acc)), jf_preu_cls_norm(tt))
        case PreSkip{n}:
          match n:
            case 0n:
              +tt : List<&2, Char> = t
              jf_preu(tt, h <> acc, jf_preu_cls_norm(tt))
            case 1n+p:
              match p:
                case 0n:
                  +tt : List<&2, Char> = t
                  jf_preu(tt, acc, jf_preu_cls_norm(tt))
                case 1n+q: jf_preu(t, acc, PreSkip{p})


# JSON string scanning. The 4-way dispatch (escaped? quote? backslash? plain)
# cannot use nested Bool.pick: Bend evaluates function arguments strictly, so
# recursive calls in multiple pick branches blow up exponentially. And match
# cannot scrutinize computed values, nor can a helper continue the loop
# (mutual recursion is banned). Solution: compute the action for the CURRENT
# head as DATA (JfAct, non-recursive helpers), thread it as a parameter, and
# peek at the next head inline to compute the following action. jf_str_go is
# the only recursive def here.
type JfAct is Data:
  JfEsc{}
  JfEnd{}
  JfBs{}
  JfChar{}

def jf_act_bs(is_b: Bool) -> JfAct:
  match is_b:
    case True{}: JfBs{}
    case False{}: JfChar{}

def jf_act_plain(is_q: Bool, is_b: Bool) -> JfAct:
  match is_q:
    case True{}: JfEnd{}
    case False{}: jf_act_bs(is_b)

def jf_act_of(esc: Bool, +h: Char) -> JfAct:
  match esc:
    case True{}: JfEsc{}
    case False{}: jf_act_plain(jf_is_quote(h), jf_is_bs(h))

def jf_str_go(+cs: List<&2, Char>, +acc: List<&2, Char>, +act: JfAct) -> Maybe<&1, String>:
  match cs:
    case Nil{}: None{}
    case h <> t:
      match t:
        case Nil{}:
          match act:
            case JfEnd{}: Some{String.from_list(List.reverse(&2, Char, acc))}
            case JfEsc{}: None{}
            case JfBs{}: None{}
            case JfChar{}: None{}
        case h2 <> t2:
          match act:
            case JfEsc{}:
              +hh : Char = h
              jf_str_go(h2 <> t2, jf_unesc(hh) <> acc, jf_act_of(False{}, h2))
            case JfEnd{}: Some{String.from_list(List.reverse(&2, Char, acc))}
            case JfBs{}:
              jf_str_go(h2 <> t2, acc, jf_act_of(True{}, h2))
            case JfChar{}:
              +hh : Char = h
              jf_str_go(h2 <> t2, hh <> acc, jf_act_of(False{}, h2))

def jf_str_pre(+cs: List<&2, Char>) -> Maybe<&1, String>:
  match cs:
    case Nil{}: None{}
    case h <> t: jf_str_go(cs, Nil{}, jf_act_of(False{}, h))

def jf_str(+cs: List<&2, Char>) -> Maybe<&1, String>:
  jf_str_pre(jf_preu(cs, Nil{}, jf_preu_cls_norm(cs)))

def jf_val_q_go(is_q: Bool, +t: List<&2, Char>) -> Maybe<&1, String>:
  match is_q:
    case True{}: jf_str(t)
    case False{}: None{}

def jf_val_q(+cs: List<&2, Char>) -> Maybe<&1, String>:
  match cs:
    case Nil{}: None{}
    case h <> t: jf_val_q_go(U32.is_eq(Char.to_u32(h), 34), t)

def jf_val(mcs: Maybe<&1, List<&2, Char>>) -> Maybe<&1, String>:
  match mcs:
    case None{}: None{}
    case Some{cs}: jf_val_q(cs)

def jf_at(mpos: Maybe<&1, Nat>, +body: String, +name: String) -> Maybe<&1, String>:
  match mpos:
    case None{}: None{}
    case Some{p}:
      +b : String = body
      +n : String = name
      +pp : Nat = p
      jf_val(jf_expect_colon(jf_skip_ws(String.to_list(String.drop(b, Nat.add(pp, Nat.add(String.length(n), 2n)))))))

# jf_body_closed (Fresh Round 3 item 26): structural completeness gate for
# request bodies. The field extractor below never validated the body as a
# whole, so a truncated object {"name":"x" (no closing brace) was accepted
# with 201. Bodies must now end with '}' after trailing whitespace;
# anything else yields None from jf_field/jf_field_any (400 missing-field
# at the call site). This also tightens the old record-only tolerance for
# trailing garbage after a valid '}' (item-25 C6): garbage -> 400 now.
# That probe never asserted 201, so no contract is broken.
def jf_trail_ws_go(+cs: List<&2, Char>) -> List<&2, Char>:
  match cs:
    case Nil{}: Nil{}
    case h <> t: Bool.pick(List<&2, Char>, jf_is_ws(h), jf_trail_ws_go(t), h <> t)

def jf_closed_head(+cs: List<&2, Char>) -> Bool:
  match cs:
    case Nil{}: False{}
    case h <> t: U32.is_eq(Char.to_u32(h), 125)

def jf_body_closed(+body: String) -> Bool:
  jf_closed_head(jf_trail_ws_go(List.reverse(&2, Char, String.to_list(body))))

# jf_no_trail_comma (Fresh Round 3 item 33): trailing-comma strictness.
# jf_body_closed (item 26) only checked that the body ENDS with '}' — so
# {"name":"x",} sailed through the gate because the flat field extractor
# never inspects commas. The char before the final '}' must not be a comma,
# where whitespace between the '}' and that char is skipped ({"a":1 , }
# is still a trailing comma). Otherwise the body is rejected (None from
# jf_field/jf_field_any -> 400 missing-field at the call site, 400
# invalid_body on the clap path). Safe w.r.t. commas inside string values:
# only the single structural position before the body's final '}' is
# inspected, so {"body":"a, b"} is unaffected. No endpoint parses nested
# objects or arrays from request bodies, so the top-level closing brace is
# the only structural position that matters.
def jf_no_trail_comma_tail(+cs: List<&2, Char>) -> Bool:
  match cs:
    case Nil{}: True{}
    case h <> t: Bool.not(U32.is_eq(Char.to_u32(h), 44))

def jf_no_trail_comma_cs(+cs: List<&2, Char>) -> Bool:
  match cs:
    case Nil{}: True{}
    case h <> t: jf_no_trail_comma_tail(jf_skip_ws(t))

def jf_no_trail_comma(+body: String) -> Bool:
  jf_no_trail_comma_cs(jf_trail_ws_go(List.reverse(&2, Char, String.to_list(body))))

def jf_body_ok(+body: String) -> Bool:
  +b : String = body
  Bool.and(jf_body_closed(b), jf_no_trail_comma(b))

def jf_field(+body: String, +name: String) -> Maybe<&1, String>:
  +b : String = body
  +n : String = name
  Bool.pick(Maybe<&1, String>, jf_body_ok(b), jf_at(jf_find_key(b, n), b, n), None{})

# jf_field_any (Round 2 item 9): like jf_field, but also accepts unquoted
# scalar values (numbers, true/false/null) and returns the raw token text.
# Quoted strings are unescaped exactly as jf_field does. Used ONLY where a
# numeric-or-string field is legitimate (clap count); name/title/bio/pub
# stay string-only so {"name":123} is still rejected.
def jf_raw_end(+code: U32) -> Bool:
  Bool.or(U32.is_eq(code, 44),
  Bool.or(U32.is_eq(code, 125),
  Bool.or(U32.is_eq(code, 32),
  Bool.or(U32.is_eq(code, 9), Bool.or(U32.is_eq(code, 10), U32.is_eq(code, 13))))))

def jf_raw_go(+cs: List<&2, Char>, +acc: List<&2, Char>) -> String:
  match cs:
    case Nil{}: String.from_list(List.reverse(&2, Char, acc))
    case h <> t:
      Bool.pick(String, jf_raw_end(Char.to_u32(h)),
        String.from_list(List.reverse(&2, Char, acc)),
        jf_raw_go(t, h <> acc))

def jf_val_any_go(is_q: Bool, +h: Char, +t: List<&2, Char>) -> Maybe<&1, String>:
  match is_q:
    case True{}: jf_str(t)
    case False{}: Some{jf_raw_go(h <> t, Nil{})}

def jf_val_any_head(+cs: List<&2, Char>) -> Maybe<&1, String>:
  match cs:
    case Nil{}: None{}
    case h <> t: jf_val_any_go(U32.is_eq(Char.to_u32(h), 34), h, t)

def jf_val_any(mcs: Maybe<&1, List<&2, Char>>) -> Maybe<&1, String>:
  match mcs:
    case None{}: None{}
    case Some{cs}: jf_val_any_head(cs)

def jf_at_any(mpos: Maybe<&1, Nat>, +body: String, +name: String) -> Maybe<&1, String>:
  match mpos:
    case None{}: None{}
    case Some{p}:
      +b : String = body
      +n : String = name
      +pp : Nat = p
      jf_val_any(jf_expect_colon(jf_skip_ws(String.to_list(String.drop(b, Nat.add(pp, Nat.add(String.length(n), 2n)))))))

def jf_field_any(+body: String, +name: String) -> Maybe<&1, String>:
  +b : String = body
  +n : String = name
  Bool.pick(Maybe<&1, String>, jf_body_ok(b), jf_at_any(jf_find_key(b, n), b, n), None{})

# --- socket assembly: head ---

def hs_add_big(too_big: Bool, +new_acc: String) -> HeadSt:
  match too_big:
    # Item 104: on 431 the raw head is dropped (memory bound) but the first 5
    # wire bytes are kept in `head` so HEAD responses stay headers-only.
    case True{}: MkHs{True{}, False{}, 431, head_tok5(new_acc), "", ""}
    case False{}: MkHs{False{}, False{}, 400, "", "", new_acc}

def hs_add_done(too_big: Bool, +new_acc: String, +pp: Nat) -> HeadSt:
  match too_big:
    # Item 104: same 5-byte method-token prefix convention as hs_add_big.
    case True{}: MkHs{True{}, False{}, 431, head_tok5(new_acc), "", ""}
    case False{}: MkHs{True{}, True{}, 200, String.take(new_acc, Nat.add(pp, 4n)), String.drop(new_acc, Nat.add(pp, 4n)), ""}

def hs_add_pos(mpos: Maybe<&1, Nat>, +new_acc: String) -> HeadSt:
  match mpos:
    case Some{p}:
      +pp : Nat = p
      +na : String = new_acc
      hs_add_done(Nat.is_lt(head_max(), utf8_byte_len(na)), na, pp)
    case None{}:
      +na2 : String = new_acc
      hs_add_big(Nat.is_lt(head_max(), utf8_byte_len(na2)), na2)

def hs_add_check(+new_acc: String) -> HeadSt:
  hs_add_pos(find_head_end(new_acc), new_acc)

def hs_add_hs(+hs: HeadSt, +chunk: String) -> HeadSt:
  match hs:
    case MkHs{done, ok, code, head, rest, acc}: hs_add_check(acc ++ chunk)

def hs_fail(+hs: HeadSt) -> HeadSt:
  match hs:
    # Item 104: keep the 5-byte method-token prefix so HEAD stays headers-only.
    case MkHs{done, ok, code, head, rest, acc}: MkHs{True{}, False{}, 400, head_tok5(acc), "", ""}

# --- poll-based read deadlines (slowloris defense) ---
# TCP.poll(sock, max, ms): Some{chunk} = data arrived ("" = peer closed),
# None{} = idle timeout, Fail = socket error. Each poll waits at most
# head_poll_ms()/body_poll_ms() for data and returns as soon as ANY bytes
# arrive -- so poll-count fuel alone cannot bound slow transfers: a head or
# body legitimately delivered in many small chunks (a 10KB body in 512B
# chunks, a head dribbled 1 byte/segment) spuriously 408/400s after 16
# polls even though every byte arrived promptly (item 25). The wall-clock
# transfer deadlines below bound slowloris dribbles instead: a client that
# keeps making progress gets the full window; idle polls still time out via
# head_poll_ms()/body_poll_ms() (~10s, unchanged). poll_fuel_backstop is a
# generous backstop against poll spin only.

def head_poll_ms() -> U32:
  10000

def body_poll_ms() -> U32:
  10000

# Max total wall-clock time to deliver the head / body once reading starts.
def head_deadline_ms() -> Nat:
  Nat.mul(30n, 1000n)

def body_deadline_ms() -> Nat:
  Nat.mul(120n, 1000n)

# Backstop: bounds total poll iterations far above any legitimate transfer
# (64KB max body in 1-byte chunks = 65536 polls).
def poll_fuel_backstop() -> Nat:
  Nat.mul(100n, 1000n)

def deadline_hit(+t0: Nat, +now: Nat, +dl: Nat) -> Bool:
  Nat.is_lt(dl, Nat.sub(now, t0))

def hs_timeout(+hs: HeadSt) -> HeadSt:
  match hs:
    # Item 104: keep the 5-byte method-token prefix so HEAD stays headers-only.
    case MkHs{done, ok, code, head, rest, acc}: MkHs{True{}, False{}, 408, head_tok5(acc), "", ""}

def hs_peer_closed(+hs: HeadSt) -> HeadSt:
  match hs:
    # Item 104: keep the 5-byte method-token prefix so HEAD stays headers-only.
    case MkHs{done, ok, code, head, rest, acc}: MkHs{True{}, False{}, 400, head_tok5(acc), "", ""}

def hs_poll_empty(is_empty: Bool, +hs: HeadSt, +chunk: String) -> HeadSt:
  match is_empty:
    case True{}: hs_peer_closed(hs)
    case False{}: hs_add_hs(hs, chunk)

def hs_poll_chunk(+hs: HeadSt, +chunk: String) -> HeadSt:
  hs_poll_empty(String.is_empty(chunk), hs, chunk)

def hs_poll_some(+hs: HeadSt, ms: Maybe<&1, String>) -> HeadSt:
  match ms:
    case None{}: hs_timeout(hs)
    case Some{chunk}: hs_poll_chunk(hs, chunk)

def hs_poll_res(+hs: HeadSt, pres: Result<&1, &1, U32 & String, Maybe<&1, String>>) -> HeadSt:
  match pres:
    case Fail{e}: hs_fail(hs)
    case Done{ms}: hs_poll_some(hs, ms)

def hs_hgot(+hs: HeadSt) -> HGot:
  match hs:
    case MkHs{done, ok, code, head, rest, acc}: MkHg{head, rest, ok, code}

def hs_poll_pr(pr: Socket & Result<&1, &1, U32 & String, Maybe<&1, String>>, +hs: HeadSt) -> Socket & HeadSt:
  (s2, pres) = pr
  (s2, hs_poll_res(hs, pres))

# (old poll-count-only recv_head_loop removed by item 25; see recv_head_step below)

# Item 25: the deadline (not poll count) bounds slow transfers; fuel is only a
# backstop. t0 is the read-start timestamp (ms, via IO.now). On deadline
# expiry poll_head feeds the loop a synthetic idle-timeout, reusing the
# existing 408 path (hs_timeout); poll_body does the same, and the
# truncated body then 400s honestly via conn_body_trunc ("body ended before
# Content-Length bytes arrived"). Non-recursive wrappers (defined before the
# loops; Bend forbids mutual recursion).
def poll_head(+hit: Bool, s2: Socket) -> IO(Socket & Result<&1, &1, U32 & String, Maybe<&1, String>>):
  match hit:
    case True{}:
      IO.pure(Socket & Result<&1, &1, U32 & String, Maybe<&1, String>>, (s2, Done{None{}}))
    case False{}:
      TCP.poll(s2, 8192, head_poll_ms())

def recv_head_loop(fuel: Nat, +t0: Nat, shs: Socket & HeadSt) -> IO(Socket & HGot):
  match fuel:
    case 0n:
      (s2, hs) = shs
      IO.pure(Socket & HGot, (s2, hs_hgot(hs_timeout(hs))))
    case 1n+f:
      (s2, hs) = shs
      match hs:
        case MkHs{True{}, ok, code, head, rest, acc}:
          IO.pure(Socket & HGot, (s2, MkHg{head, rest, ok, code}))
        case MkHs{False{}, ok, code, head, rest, acc}:
          do IO<Socket & HGot>:
            now : Nat <- IO.now()
            pr : Socket & Result<&1, &1, U32 & String, Maybe<&1, String>> <- poll_head(deadline_hit(t0, now, head_deadline_ms()), s2)
            recv_head_loop(f, t0, hs_poll_pr(pr, hs))

def recv_head(sock: Socket) -> IO(Socket & HGot):
  do IO<Socket & HGot>:
    t0 : Nat <- IO.now()
    recv_head_loop(poll_fuel_backstop(), t0, (sock, MkHs{False{}, False{}, 400, "", "", ""}))

# --- socket assembly: body ---

def bs_add_rem(+rem: Nat, +acc: String) -> BodySt:
  MkBs{Nat.is_eq(rem, 0n), rem, acc}

def body_rem_ge(ge: Bool, +rem: Nat, +clen: Nat) -> Nat:
  match ge:
    case True{}: 0n
    case False{}: Nat.sub(rem, clen)

def body_rem_len(+rem: Nat, +clen: Nat) -> Nat:
  body_rem_ge(Nat.is_ge(clen, rem), rem, clen)

def body_rem(+rem: Nat, +chunk: String) -> Nat:
  body_rem_len(rem, utf8_byte_len(chunk))

def bs_add_hs(+bs: BodySt, +chunk: String) -> BodySt:
  match bs:
    case MkBs{done, rem, acc}: bs_add_rem(body_rem(rem, chunk), acc ++ chunk)

def bs_fail(+bs: BodySt) -> BodySt:
  match bs:
    case MkBs{done, rem, acc}: MkBs{True{}, rem, acc}

def bs_done(+bs: BodySt) -> BodySt:
  match bs:
    case MkBs{done, rem, acc}: MkBs{True{}, rem, acc}

def bs_poll_empty(is_empty: Bool, +bs: BodySt, +chunk: String) -> BodySt:
  match is_empty:
    case True{}: bs_done(bs)
    case False{}: bs_add_hs(bs, chunk)

def bs_poll_chunk(+bs: BodySt, +chunk: String) -> BodySt:
  bs_poll_empty(String.is_empty(chunk), bs, chunk)

def bs_poll_some(+bs: BodySt, ms: Maybe<&1, String>) -> BodySt:
  match ms:
    case None{}: bs_done(bs)
    case Some{chunk}: bs_poll_chunk(bs, chunk)

def bs_poll_res(+bs: BodySt, pres: Result<&1, &1, U32 & String, Maybe<&1, String>>) -> BodySt:
  match pres:
    case Fail{e}: bs_fail(bs)
    case Done{ms}: bs_poll_some(bs, ms)

def bs_init(+cl: Nat, +rest: String) -> BodySt:
  bs_add_rem(body_rem(cl, rest), rest)

def bs_acc(+bs: BodySt) -> String:
  match bs:
    case MkBs{done, rem, acc}: acc

def bs_poll_pr(pr: Socket & Result<&1, &1, U32 & String, Maybe<&1, String>>, +bs: BodySt) -> Socket & BodySt:
  (s2, pres) = pr
  (s2, bs_poll_res(bs, pres))

# Item 25: deadline-gated body read (same rationale as poll_head: a body
# legitimately delivered in many small chunks must not 400 after 16 polls).
def poll_body(+hit: Bool, s2: Socket) -> IO(Socket & Result<&1, &1, U32 & String, Maybe<&1, String>>):
  match hit:
    case True{}:
      IO.pure(Socket & Result<&1, &1, U32 & String, Maybe<&1, String>>, (s2, Done{None{}}))
    case False{}:
      TCP.poll(s2, 8192, body_poll_ms())

def recv_body_loop(fuel: Nat, +t0: Nat, sbs: Socket & BodySt) -> IO(Socket & String):
  match fuel:
    case 0n:
      (s2, bs) = sbs
      IO.pure(Socket & String, (s2, bs_acc(bs)))
    case 1n+f:
      (s2, bs) = sbs
      match bs:
        case MkBs{True{}, rem, acc}: IO.pure(Socket & String, (s2, acc))
        case MkBs{False{}, rem, acc}:
          do IO<Socket & String>:
            now : Nat <- IO.now()
            pr : Socket & Result<&1, &1, U32 & String, Maybe<&1, String>> <- poll_body(deadline_hit(t0, now, body_deadline_ms()), s2)
            recv_body_loop(f, t0, bs_poll_pr(pr, bs))

def recv_body(s2: Socket, +cl: Nat, +rest: String) -> IO(Socket & String):
  do IO<Socket & String>:
    t0 : Nat <- IO.now()
    recv_body_loop(poll_fuel_backstop(), t0, (s2, bs_init(cl, rest)))

# --- byte-exact truncation (Content-Length enforcement) ---

type TakeSt is Data:
  MkTake{done: Bool, cs: List<&2, Char>, rem: Nat, acc: List<&2, Char>}

def take_step3(ok: Bool, +clen: Nat, +h: Char, +t: List<&2, Char>, +rem: Nat, +acc: List<&2, Char>) -> TakeSt:
  match ok:
    case True{}: MkTake{False{}, t, Nat.sub(rem, clen), h <> acc}
    case False{}: MkTake{True{}, t, rem, acc}

def take_step2(+cu: U32, +h: Char, +t: List<&2, Char>, +rem: Nat, +acc: List<&2, Char>) -> TakeSt:
  take_step3(Nat.is_le(utf8_char_len(cu), rem), utf8_char_len(cu), h, t, rem, acc)

def take_step(+h: Char, +t: List<&2, Char>, +rem: Nat, +acc: List<&2, Char>) -> TakeSt:
  take_step2(Char.to_u32(h), h, t, rem, acc)

def take_fin(+st: TakeSt) -> List<&2, Char>:
  match st:
    case MkTake{done, cs, rem, acc}: List.reverse(&2, Char, acc)

def str_take_bytes_go(fuel: Nat, +st: TakeSt) -> List<&2, Char>:
  match fuel:
    case 0n: take_fin(st)
    case 1n+f:
      match st:
        case MkTake{done, cs, rem, acc}:
          match done:
            case True{}: take_fin(st)
            case False{}:
              match cs:
                case Nil{}: take_fin(st)
                case h <> t: str_take_bytes_go(f, take_step(h, t, rem, acc))

def str_take_bytes(+s: String, +n: Nat) -> String:
  String.from_list(str_take_bytes_go(Nat.add(String.length(s), 1n), MkTake{False{}, String.to_list(s), n, Nil{}}))

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

# med_store.bend — fresh Medium service, part 6: storage + WAL + snapshots.
# DB keys (all tenant-scoped):
#   u:<tenant>:<id>          -> name \t bio
#   a:<tenant>:<id>          -> author_kid \t title \t body \t pub \t created_ms
#   p:<tenant>:<id>          -> owner_kid \t name \t desc
#   pm:<tenant>:<pub>:<kid>  -> role (writer|editor)
#   c:<tenant>:<aid>:<kid>   -> count
# WAL lines (tab-separated, \n-terminated):
#   SET \t key \t value
#   DEL \t key
#   KEY \t kid \t verifier-or-name \t tenant \t role \t expires \t revoked
#   SEQ \t n

def db_get_v(mv: Map<&2, String> & String) -> String:
  (m2, v) = mv
  v

def db_get(+db: Map<&2, String>, +key: String) -> String:
  db_get_v(Map.get(String, "", db, key))

def db_has(+db: Map<&2, String>, +key: String) -> Bool:
  Bool.not(String.is_empty(db_get(db, key)))

# --- bounded commit-event log (newest-first, cap 1000) ---
# Lives in the storage layer because WAL replay rebuilds it on startup.
# evt_emit (med_evt.bend) appends; every EVT line in WAL/snapshot replays here.

def evt_cap() -> Nat:
  Nat.mul(10n, 100n)

def evt_len(+log: List<&2, Evt>) -> Nat:
  match log:
    case Nil{}: 0n
    case _ <> t: Nat.add(1n, evt_len(t))

def evt_drop_last(+log: List<&2, Evt>) -> List<&2, Evt>:
  match log:
    case Nil{}: Nil{}
    case _ <> Nil{}: Nil{}
    case h <> t: h <> evt_drop_last(t)

def evt_trim_over(is_over: Bool, +log: List<&2, Evt>) -> List<&2, Evt>:
  match is_over:
    case True{}: evt_drop_last(log)
    case False{}: log

def evt_trim(+log: List<&2, Evt>) -> List<&2, Evt>:
  evt_trim_over(Nat.is_lt(evt_cap(), evt_len(log)), log)

def evt_push(+log: List<&2, Evt>, +e: Evt) -> List<&2, Evt>:
  evt_trim(e <> log)

# --- WAL append ---
# fsync'd (Round 2 item 7): a commit is acknowledged only after its WAL
# record is on stable storage. wal_write_done fsyncs the file AFTER the
# write and BEFORE the close; the Bool the owner waits on is True only if
# write AND sync both succeeded. A sync failure surfaces as
# 500 "wal_write_failed", never a silent ack.

def wal_sync_done(sr: File & Result<&1, &1, U32 & String, Unit>) -> IO(Bool):
  (f3, sres) = sr
  match sres:
    case Fail{e}:
      do IO<Bool>:
        _c : Unit <- File.close(f3)
        IO.pure(Bool, False{})
    case Done{u}:
      do IO<Bool>:
        _c : Unit <- File.close(f3)
        IO.pure(Bool, True{})

def wal_write_done(wr: File & Result<&1, &1, U32 & String, Unit>) -> IO(Bool):
  (f2, res) = wr
  match res:
    case Fail{e}:
      do IO<Bool>:
        _c : Unit <- File.close(f2)
        IO.pure(Bool, False{})
    case Done{u}:
      do IO<Bool>:
        sr : File & Result<&1, &1, U32 & String, Unit> <- File.sync(f2)
        wal_sync_done(sr)

def wal_write_open(r: Result<&1, &1, U32 & String, File>, +entry: String) -> IO(Bool):
  match r:
    case Fail{e}: IO.pure(Bool, False{})
    case Done{f}:
      do IO<Bool>:
        wr : File & Result<&1, &1, U32 & String, Unit> <- File.write(f, entry)
        wal_write_done(wr)

# --- Segmented WAL (Round 3 item 14) ---
#
# The single bocht.wal is replaced by numbered segments:
#   wal/active/seg-000042.wal            - not yet covered by a snapshot
#   wal/archive/YYYY/MM/seg-000042.wal   - covered by a durable snapshot
#
# Rollover policy: SIZE-BASED. Before each append the current segment is
# statted; when it has reached MEDIUM_WAL_SEG_CAP bytes (default 64 MiB)
# the counter advances and the write starts seg-N+1. 64 MiB is the production
# rollover policy; the per-file replay read cap is 80 MiB, so no segment can
# outgrow a single replay read. Time-based rollover was rejected: it needs
# clock bookkeeping and still allows unbounded growth under burst load.
# (The snapshot-every-500 cadence usually archives the current segment
# before it fills; that is fine.)
#
# Crash-safety sequence:
#   1. Every commit appends to the current active segment and is fsync'd
#      before the ack - the same ack-after-durable guarantee as before.
#   2. On snapshot: tmp write + fsync + validate, main write + fsync +
#      validate - exactly as before.
#   3. ONLY after the snapshot validates, the archive step runs: the
#      destination is clash-checked first (the archive aborts, retrying
#      after the next snapshot, if a planned archive name already exists),
#      then the segment counter is bumped past every active segment number
#      (fsync'd; the archive aborts if the bump fails), then every active
#      segment is moved with atomic rename(2) into wal/archive/YYYY/MM/,
#      then both directories are fsync'd.
#   4. A crash before step 3 completes leaves segments in wal/active/;
#      they replay harmlessly (replay is idempotent; every record carries
#      its sequence number).
#   5. rename(2) is atomic: a segment is never half-moved and never
#      deleted by the move. A destination-clash guard aborts the archive
#      (rather than overwriting) if a planned archive name already exists.
#   6. The counter only ever increases, so a segment number is never
#      reused and an archived seg-N can never collide with a new seg-N.
#
# Boot: wal/ and wal/active/ are created (a mkdir failure is fatal: the
# service refuses to start rather than serve without a WAL); a legacy
# single bocht.wal (from pre-segmentation installs) is imported ONCE as
# wal/active/seg-000000.wal iff no segments exist yet; the counter is
# reconciled to the next free segment number - max(counter file, active
# max, archive max), bumped past the archive max when wal/active/ is empty
# (the max walk alone cannot tell "archive empty" from "archive holds
# seg-0", and reusing the newest archived number would clash on the next
# archive). A segment number is therefore never reused, and an archived
# seg-N can never collide with a new seg-N.
#
# Purge: wal/archive/ is scanned at boot (dry-run first, then for real);
# segments older than MEDIUM_WAL_PURGE_DAYS are deleted. The named
# constant WAL_PURGE_RETENTION_DAYS is 10000, i.e. effectively disabled
# (user decision 2026-09-21: build the infrastructure, purge nothing).
# A stat failure yields "now" as the mtime, so an unreadable segment is
# never purged (fail-closed).

def wal_dir() -> String:
  "wal"

def wal_active_dir() -> String:
  "wal/active"

def wal_archive_dir() -> String:
  "wal/archive"

def wal_segcounter_path() -> String:
  "wal/segcounter"

# Named retention constant: 10000 days. The purge scanner runs, but
# nothing is purged until an operator lowers this (or sets
# MEDIUM_WAL_PURGE_DAYS). User decision 2026-09-21.
def wal_purge_retention_days_default() -> Nat:
  10000n

# 64 MiB = 64 * 1024 * 1024, built arithmetically: Nat literals above ~1000
# expand at compile time and overflow the stack.
def wal_seg_cap_default() -> Nat:
  Nat.mul(64n, Nat.mul(Nat.mul(32n, 32n), Nat.mul(32n, 32n)))

def wal_zpad2(+n: Nat) -> String:
  String.drop(Nat.show(Nat.add(100n, n)), 1n)

def wal_zpad4(+n: Nat) -> String:
  String.drop(Nat.show(Nat.add(10000n, n)), 1n)

def wal_zpad6_go(small: Bool, +n: Nat) -> String:
  match small:
    case True{}: String.drop(Nat.show(Nat.add(1000000n, n)), 1n)
    case False{}: Nat.show(n)

def wal_zpad6(+n: Nat) -> String:
  wal_zpad6_go(Nat.is_lt(n, 1000000n), n)

def wal_seg_name(+n: Nat) -> String:
  "seg-" ++ wal_zpad6(n) ++ ".wal"

def wal_seg_path(+n: Nat) -> String:
  wal_active_dir() ++ "/" ++ wal_seg_name(n)

def u32_ok(+v: U32) -> Bool:
  Bool.not(U32.is_eq(v, (0 : U32)))

# --- segment counter (fsync'd via wal_write_open; reconciled at boot) ---

def wal_segcounter_num(mn: Maybe<&1, Nat>) -> Nat:
  match mn:
    case None{}: 0n
    case Some{n}: n

# The counter file is written as "N\n". parse_nat_opt rejects the trailing
# newline (it is not a digit), so the whole content must never be parsed
# directly: parse only the first line. (Bug found 2026-09-21: parsing the
# raw content made every boot read counter=0, reuse segment numbers after
# an archive, and clash/defer the next archive.)
def wal_segcounter_head(+parts: List<&2, String>) -> Maybe<&1, Nat>:
  match parts:
    case Nil{}: None{}
    case h <> t: parse_nat_opt(h)

def wal_segcounter_got(rr: File & Result<&1, &1, U32 & String, String>) -> IO(Nat):
  (f2, res) = rr
  match res:
    case Fail{e}:
      do IO<Nat>:
        _c : Unit <- File.close(f2)
        IO.pure(Nat, 0n)
    case Done{content}:
      do IO<Nat>:
        _c : Unit <- File.close(f2)
        IO.pure(Nat, wal_segcounter_num(wal_segcounter_head(split_char(content, ch_lf()))))

def wal_segcounter_read(r: Result<&1, &1, U32 & String, File>) -> IO(Nat):
  match r:
    case Fail{e}: IO.pure(Nat, 0n)
    case Done{f}:
      do IO<Nat>:
        rr : File & Result<&1, &1, U32 & String, String> <- File.read(f, 16777216)
        wal_segcounter_got(rr)

def wal_seg_current() -> IO(Nat):
  do IO<Nat>:
    r : Result<&1, &1, U32 & String, File> <- File.open(wal_segcounter_path(), "r")
    wal_segcounter_read(r)

def wal_seg_set_current(+n: Nat) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(wal_segcounter_path(), "w")
    wal_write_open(r, Nat.show(n) ++ "\n")

# --- size-based rollover ---

def wal_seg_cap_pos(is_zero: Bool, +n: Nat) -> Nat:
  match is_zero:
    case True{}: wal_seg_cap_default()
    case False{}: n

def wal_seg_cap_nz(+n: Nat) -> Nat:
  wal_seg_cap_pos(Nat.is_eq(n, 0n), n)

def wal_seg_cap_num(mn: Maybe<&1, Nat>) -> Nat:
  match mn:
    case None{}: wal_seg_cap_default()
    case Some{n}: wal_seg_cap_nz(n)

def wal_seg_cap_env(mr: Result<&1, &1, U32 & String, String>) -> Nat:
  match mr:
    case Fail{e}: wal_seg_cap_default()
    case Done{+s}: wal_seg_cap_num(parse_nat_opt(s))

def wal_seg_cap() -> IO(Nat):
  do IO<Nat>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_WAL_SEG_CAP")
    IO.pure(Nat, wal_seg_cap_env(mr))

def wal_append_seg(+n: Nat, +entry: String) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(wal_seg_path(n), "a")
    wal_write_open(r, entry)

# A failed counter bump must fail the commit (500 wal_write_failed), not
# silently append to a segment number the counter does not own (that would
# risk reusing a number and clashing on archive).
def wal_write_roll_bump(ok: Bool, +entry: String, +cur: Nat) -> IO(Bool):
  match ok:
    case False{}: IO.pure(Bool, False{})
    case True{}: wal_append_seg(Nat.add(cur, 1n), entry)

def wal_write_roll(roll: Bool, +entry: String, +cur: Nat) -> IO(Bool):
  match roll:
    case False{}: wal_append_seg(cur, entry)
    case True{}:
      do IO<Bool>:
        ok : Bool <- wal_seg_set_current(Nat.add(cur, 1n))
        wal_write_roll_bump(ok, entry, cur)

def wal_write_sz(+entry: String, +cur: Nat, +cap: Nat, sz: U32) -> IO(Bool):
  wal_write_roll(Bool.not(Nat.is_lt(U32.to_nat(sz), cap)), entry, cur)

def wal_write_go(+cur: Nat, +entry: String, +cap: Nat) -> IO(Bool):
  do IO<Bool>:
    sz : U32 <- FS.file_size(wal_seg_path(cur))
    wal_write_sz(entry, cur, cap, sz)

def wal_write(+entry: String) -> IO(Bool):
  do IO<Bool>:
    cap : Nat <- wal_seg_cap()
    cur : Nat <- wal_seg_current()
    wal_write_go(cur, entry, cap)

# --- segment-number parsing ("seg-000042.wal" -> 42) ---

def wal_is_segname(+h: String) -> Bool:
  Bool.and(String.starts_with(h, "seg-"), String.ends_with(h, ".wal"))

def wal_segnum_head2(+h: String) -> Maybe<&1, Nat>:
  parse_nat_opt(String.drop(h, 4n))

def wal_segnum_head(+parts: List<&2, String>) -> Maybe<&1, Nat>:
  match parts:
    case Nil{}: None{}
    case h <> t: wal_segnum_head2(h)

def wal_segnum_checked(ok: Bool, +h: String) -> Maybe<&1, Nat>:
  match ok:
    case False{}: None{}
    case True{}: wal_segnum_head(split_char(h, ch_dot()))

def wal_segnum_name(+h: String) -> Maybe<&1, Nat>:
  wal_segnum_checked(wal_is_segname(h), h)

# --- small Nat list helpers (insertion sort; segments are few) ---

def nats_min_ab(+a: Nat, +b: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(a, b), a, b)

def nats_min_go(+xs: List<&2, Nat>, +best: Nat) -> Nat:
  match xs:
    case Nil{}: best
    case h <> t: nats_min_go(t, nats_min_ab(h, best))

def nats_min(+xs: List<&2, Nat>) -> Nat:
  match xs:
    case Nil{}: 0n
    case h <> t: nats_min_go(t, h)

def nats_max_ab(+a: Nat, +b: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(a, b), b, a)

def nats_max_go(+xs: List<&2, Nat>, +best: Nat) -> Nat:
  match xs:
    case Nil{}: best
    case h <> t: nats_max_go(t, nats_max_ab(h, best))

def nats_max(+xs: List<&2, Nat>) -> Nat:
  nats_max_go(xs, 0n)

# Ascending insertion sort on Nat lists. Segment counts at boot are small
# (each segment is up to 64 MiB), so O(n^2) is negligible. Sorting the
# enumerated directory listing replaces the old min..max range reads: a
# single hostile seg-999999.wal (or a bogus 9999/ archive year) can no
# longer turn replay into a million-file boot scan.
#
# Bend forbids mutual recursion, so the Bool dispatch cannot live in a
# helper that calls back into nats_insert. Instead the caller always
# computes the recursively-inserted tail (strict evaluation; the unused
# arm drops it) and a leaf helper defined first branches on the Bool.
def nats_insert_branch(lt: Bool, +x: Nat, +h: Nat, +t_sorted: List<&2, Nat>, +t: List<&2, Nat>) -> List<&2, Nat>:
  match lt:
    case True{}: h <> t_sorted
    case False{}: x <> h <> t

def nats_insert(+x: Nat, +xs: List<&2, Nat>) -> List<&2, Nat>:
  match xs:
    case Nil{}: x <> Nil{}
    case h <> t: nats_insert_branch(Nat.is_lt(h, x), x, h, nats_insert(x, t), t)

def nats_sort(+xs: List<&2, Nat>) -> List<&2, Nat>:
  match xs:
    case Nil{}: Nil{}
    case h <> t: nats_insert(h, nats_sort(t))

def wal_set(+k: String, +v: String) -> IO(Bool):
  wal_write("SET" ++ s_tab() ++ k ++ s_tab() ++ v ++ "\n")

def wal_del(+k: String) -> IO(Bool):
  wal_write("DEL" ++ s_tab() ++ k ++ "\n")

def wal_key(+a: Auth) -> IO(Bool):
  wal_write("KEY" ++ s_tab() ++ apikey_serialize(a) ++ "\n")

def wal_keyrot(+old_v: String, +new: Auth) -> IO(Bool):
  wal_write("KEYROT" ++ s_tab() ++ old_v ++ s_tab() ++ apikey_serialize(new) ++ "\n")

# Revoked-key tombstone reclamation (Round 3 item 15): snapshot-time compaction
# drops revoked keys from the live map and persists each drop as one KEYDEL
# line (fsync'd like every WAL write). Replay drops them too, so a crash
# between compaction and snapshot promotion cannot resurrect them. Revocation
# is permanent and auth rejects missing keys with 401 exactly like revoked
# ones, so dropping is behavior-preserving; the WAL archive keeps the full
# KEY/KEYDEL history for audit.
def wal_keydel(v: String) -> IO(Bool):
  wal_write("KEYDEL" ++ s_tab() ++ v ++ "\n")

# Combined single-line commit records (Round 2 item 7b): a mutation and its
# sequence number are written as ONE line with ONE fsync. A crash can only
# leave this line fully present (replayed atomically: both the mutation and
# the sequence advance together) or torn-and-unterminated (dropped by
# wal_replay's trailing-record trim). The old two-write form (wal_set then
# wal_seq) had a crash window where a durable SET replayed with a stale SEQ,
# causing the next create to reuse the same id and silently overwrite.
def wal_setseq(+k: String, +v: String, +n: Nat) -> IO(Bool):
  wal_write("SSET" ++ s_tab() ++ k ++ s_tab() ++ v ++ s_tab() ++ Nat.show(n) ++ "\n")

def wal_keyseq(+a: Auth, +n: Nat) -> IO(Bool):
  wal_write("SKEY" ++ s_tab() ++ apikey_serialize(a) ++ s_tab() ++ Nat.show(n) ++ "\n")

# --- single-line integrated commit records (Round 2 item 9) ---
# Item 8 wrote SSET/SET + EVT as two lines in one write() call. A torn
# OS-crash write could then leave the mutation line complete but the EVT
# line torn (dropped by wal_drop_torn): a durable mutation with no event.
# The V records integrate mutation + event into ONE line, so a torn write
# drops both atomically — the event log can never diverge from the DB:
#   SSETV\t<k>\t<v>\t<n>\t<evseq>\t<tenant>\t<etype>\t<payload>
#   SETV \t<k>\t<v>\t<evseq>\t<tenant>\t<etype>\t<payload>
#   DELV \t<k>\t<evseq>\t<tenant>\t<etype>\t<payload>
# v may contain structural tabs (user/article/pub serialization), so replay
# takes k first and peels the fixed trailing event fields off the reversed
# remainder, re-joining the middle as v. tenant/etype/payload are tab-free:
# payloads are built only from json_esc + Nat.show, and valid_tenant
# rejects tabs in tenant names (the same invariant KEY records rely on).
# Legacy SSET/SET/DEL/EVT lines remain replayable (dispatch order below).

def wal_evt_fields(+e: Evt) -> String:
  match e:
    case MkEvt{s, t, k, p}:
      Nat.show(s) ++ s_tab() ++ t ++ s_tab() ++ k ++ s_tab() ++ p

# Legacy two-line form, still used by snapshot EVT sections (snapshots are
# written to .tmp + renamed, so the torn-write concern does not apply).
def wal_evt_line(+e: Evt) -> String:
  "EVT" ++ s_tab() ++ wal_evt_fields(e) ++ "\n"

def wal_setseq_evt_go(me: Maybe<&1, Evt>, +k: String, +v: String, +n: Nat) -> IO(Bool):
  match me:
    case None{}: wal_setseq(k, v, n)
    case Some{+e}:
      wal_write("SSETV" ++ s_tab() ++ k ++ s_tab() ++ v ++ s_tab() ++ Nat.show(n) ++ s_tab() ++ wal_evt_fields(e) ++ "\n")

def wal_setseq_evt(+k: String, +v: String, +n: Nat, e: Maybe<&1, Evt>) -> IO(Bool):
  wal_setseq_evt_go(e, k, v, n)

def wal_set_evt_go(me: Maybe<&1, Evt>, +k: String, +v: String) -> IO(Bool):
  match me:
    case None{}: wal_set(k, v)
    case Some{+e}:
      wal_write("SETV" ++ s_tab() ++ k ++ s_tab() ++ v ++ s_tab() ++ wal_evt_fields(e) ++ "\n")

def wal_set_evt(+k: String, +v: String, e: Maybe<&1, Evt>) -> IO(Bool):
  wal_set_evt_go(e, k, v)

def wal_del_evt_go(me: Maybe<&1, Evt>, +k: String) -> IO(Bool):
  match me:
    case None{}: wal_del(k)
    case Some{+e}:
      wal_write("DELV" ++ s_tab() ++ k ++ s_tab() ++ wal_evt_fields(e) ++ "\n")

def wal_del_evt(+k: String, e: Maybe<&1, Evt>) -> IO(Bool):
  wal_del_evt_go(e, k)

# --- WAL replay (pure; uses split_char, never String.split) ---

def wal_do_set2(+k: String, +t: List<&2, String>, +st: MedState) -> MedState:
  match t:
    case Nil{}: st
    case _ <> _: st_with_db(st, Map.set(&2, String, st_db(st), k, join_str(t, s_tab())))

def wal_do_set(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case k <> t: wal_do_set2(k, t, st)

def wal_do_del(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case k <> t: st_with_db(st, Map.del(&2, String, st_db(st), k))

def wal_do_key_go(mk: Maybe<&1, Auth>, +st: MedState) -> MedState:
  match mk:
    case None{}: st
    case Some{+a}: st_with_keys(st, Map.set(&2, Auth, st_keys(st), auth_key(a), a))

def wal_do_key(+rest: List<&2, String>, +st: MedState) -> MedState:
  wal_do_key_go(apikey_deserialize(join_str(rest, s_tab())), st)

def wal_do_keyrot_go(mk: Maybe<&1, Auth>, +old_v: String, +st: MedState) -> MedState:
  match mk:
    case None{}: st
    case Some{+a}: st_with_keys(st, Map.set(&2, Auth, Map.del(&2, Auth, st_keys(st), old_v), auth_key(a), a))

def wal_do_keyrot(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case old_v <> t: wal_do_keyrot_go(apikey_deserialize(join_str(t, s_tab())), old_v, st)

def wal_do_keydel(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case v <> _: st_with_keys(st, Map.del(&2, Auth, st_keys(st), v))

def wal_do_seq_go(mn: Maybe<&1, Nat>, +st: MedState) -> MedState:
  match mn:
    case None{}: st
    # Round 3 item 136: max-defense on the record-id counter. Bare SEQ lines
    # are only ever written in the snapshot trailer; the live server never
    # emits them into WAL segments, so a bare SEQ in a segment is corrupt /
    # forged input. Applying it blindly rewinds st_seq: post-reboot writes
    # reuse ids and silently clobber existing records (evseq already takes
    # the max as defense in wal_push_evt; st_seq gets the same here and at
    # the SSET/SKEY/SSETV replay sites below). No-op on legitimate replay:
    # the single owner emits strictly increasing seqs.
    case Some{n}: st_with_seq(st, Nat.max(n, st_seq(st)))

def wal_do_seq(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case n <> t: wal_do_seq_go(parse_nat_opt(n), st)

# SSET: one line carries both the mutation and its sequence number.
# Format: SSET\t<k>\t<v>\t<seq>; v may itself contain tabs, seq is last.
def wal_do_setseq_apply(+k: String, +v: String, mn: Maybe<&1, Nat>, +st: MedState) -> MedState:
  match mn:
    case None{}: st
    case Some{n}: st_with_seq(st_with_db(st, Map.set(&2, String, st_db(st), k, v)), Nat.max(n, st_seq(st)))

def wal_do_setseq_v(+k: String, +seqs: String, +vparts: List<&2, String>, +st: MedState) -> MedState:
  wal_do_setseq_apply(k, join_str(vparts, s_tab()), parse_nat_opt(seqs), st)

def wal_do_setseq_rev(+k: String, +rev: List<&2, String>, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case seqs <> vrev: wal_do_setseq_v(k, seqs, List.reverse(&2, String, vrev), st)

def wal_do_setseq(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case k <> t: wal_do_setseq_rev(k, List.reverse(&2, String, t), st)

# SKEY: one line carries both the key record and its sequence number.
# Format: SKEY\t<kid>\t<k>\t<t>\t<r>\t<e>\t<rv>\t<seq>; seq is last.
def wal_do_keyseq_set(n: Nat, mk: Maybe<&1, Auth>, +st: MedState) -> MedState:
  match mk:
    case None{}: st
    case Some{+a}: st_with_seq(st_with_keys(st, Map.set(&2, Auth, st_keys(st), auth_key(a), a)), Nat.max(n, st_seq(st)))

def wal_do_keyseq_apply(+arec: List<&2, String>, mn: Maybe<&1, Nat>, +st: MedState) -> MedState:
  match mn:
    case None{}: st
    case Some{n}: wal_do_keyseq_set(n, apikey_deserialize(join_str(arec, s_tab())), st)

def wal_do_keyseq_rev(+rev: List<&2, String>, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case seqs <> arev: wal_do_keyseq_apply(List.reverse(&2, String, arev), parse_nat_opt(seqs), st)

def wal_do_keyseq(+rest: List<&2, String>, +st: MedState) -> MedState:
  wal_do_keyseq_rev(List.reverse(&2, String, rest), st)

# EVT replay: rebuild the in-memory evlog and evseq from persisted events so
# cursors survive restart. evseq takes the max as defense; the single owner
# emits strictly increasing seqs so replay order == seq order.
# Idempotent replay (Round 3 item 128): a SIGKILL between snapshot_save and
# wal_archive_covered leaves covered entries in wal/active; boot replays them
# over a snapshot that already contains them. SET/SEQ are absolute and
# idempotent, but evt_push is a blind prepend, so replaying a covered EVT
# duplicated the event. The live path always assigns es = evseq+1 (evt_emit)
# and snapshot EVT lines replay in increasing order from an empty state, so
# skipping a replayed event with es <= evseq can only drop an event the state
# already holds.
def wal_push_evt_go(skip: Bool, +st: MedState, +e: Evt, +es: Nat) -> MedState:
  match skip:
    case True{}: st
    case False{}: st_with_ev(st, evt_push(st_evlog(st), e), es)

def wal_push_evt(+st: MedState, +e: Evt, +es: Nat) -> MedState:
  wal_push_evt_go(Nat.is_le(es, st_evseq(st)), st, e, es)

def wal_do_evt_n(+n: Nat, +tenant: String, +etype: String, +payload: String, +st: MedState) -> MedState:
  wal_push_evt(st, MkEvt{n, tenant, etype, payload}, n)

def wal_do_evt_apply(mn: Maybe<&1, Nat>, +tenant: String, +etype: String, +payload: String, +st: MedState) -> MedState:
  match mn:
    case None{}: st
    case Some{n}: wal_do_evt_n(n, tenant, etype, payload, st)

def wal_do_evt_rest(mn: Maybe<&1, Nat>, +tenant: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case etype <> t: wal_do_evt_apply(mn, tenant, etype, join_str(t, s_tab()), st)

def wal_do_evt_tenant(mn: Maybe<&1, Nat>, +rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case tenant <> t: wal_do_evt_rest(mn, tenant, t, st)

def wal_do_evt(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case seqs <> t: wal_do_evt_tenant(parse_nat_opt(seqs), t, st)

# --- V-record replay (Round 2 item 9) ---
# SSETV: fields after op are k, v-parts.., n, evseq, tenant, etype, payload.
# v may contain structural tabs, so k is taken first and the five trailing
# event fields are peeled off the reversed remainder; the middle re-joins
# to v. Malformed records are skipped, never half-applied.
def wal_do_ssetv_ev_go(+es: Nat, +k: String, +vrev: List<&2, String>, +n: Nat, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  wal_push_evt(st_with_seq(st_with_db(st, Map.set(&2, String, st_db(st), k, join_str(List.reverse(&2, String, vrev), s_tab()))), Nat.max(n, st_seq(st))), MkEvt{es, tn, et, p}, es)

def wal_do_ssetv_ev(mes: Maybe<&1, Nat>, +k: String, +vrev: List<&2, String>, +n: Nat, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  match mes:
    case None{}: st
    case Some{es}: wal_do_ssetv_ev_go(es, k, vrev, n, tn, et, p, st)

def wal_do_ssetv_seq(mn: Maybe<&1, Nat>, +k: String, +vrev: List<&2, String>, +es: String, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  match mn:
    case None{}: st
    case Some{n}: wal_do_ssetv_ev(parse_nat_opt(es), k, vrev, n, tn, et, p, st)

def wal_do_ssetv_apply(+k: String, +vrev: List<&2, String>, +ns: String, +es: String, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  wal_do_ssetv_seq(parse_nat_opt(ns), k, vrev, es, tn, et, p, st)

def wal_do_ssetv_n(+k: String, +rev: List<&2, String>, +es: String, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case ns <> vrev: wal_do_ssetv_apply(k, vrev, ns, es, tn, et, p, st)

def wal_do_ssetv_es(+k: String, +rev: List<&2, String>, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case es <> r1: wal_do_ssetv_n(k, r1, es, tn, et, p, st)

def wal_do_ssetv_t(+k: String, +rev: List<&2, String>, +et: String, +p: String, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case tn <> r1: wal_do_ssetv_es(k, r1, tn, et, p, st)

def wal_do_ssetv_e(+k: String, +rev: List<&2, String>, +p: String, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case et <> r1: wal_do_ssetv_t(k, r1, et, p, st)

def wal_do_ssetv_p(+k: String, +rev: List<&2, String>, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case p <> r1: wal_do_ssetv_e(k, r1, p, st)

def wal_do_ssetv(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case k <> t: wal_do_ssetv_p(k, List.reverse(&2, String, t), st)

# SETV: fields after op are k, v-parts.., evseq, tenant, etype, payload
# (no sequence advance; used by claps and membership changes).
def wal_do_setv_ev_go(+es: Nat, +k: String, +vrev: List<&2, String>, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  wal_push_evt(st_with_db(st, Map.set(&2, String, st_db(st), k, join_str(List.reverse(&2, String, vrev), s_tab()))), MkEvt{es, tn, et, p}, es)

def wal_do_setv_ev(mes: Maybe<&1, Nat>, +k: String, +vrev: List<&2, String>, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  match mes:
    case None{}: st
    case Some{es}: wal_do_setv_ev_go(es, k, vrev, tn, et, p, st)

def wal_do_setv_apply(+k: String, +vrev: List<&2, String>, +es: String, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  wal_do_setv_ev(parse_nat_opt(es), k, vrev, tn, et, p, st)

def wal_do_setv_es(+k: String, +rev: List<&2, String>, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case es <> vrev: wal_do_setv_apply(k, vrev, es, tn, et, p, st)

def wal_do_setv_t(+k: String, +rev: List<&2, String>, +et: String, +p: String, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case tn <> r1: wal_do_setv_es(k, r1, tn, et, p, st)

def wal_do_setv_e(+k: String, +rev: List<&2, String>, +p: String, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case et <> r1: wal_do_setv_t(k, r1, et, p, st)

def wal_do_setv_p(+k: String, +rev: List<&2, String>, +st: MedState) -> MedState:
  match rev:
    case Nil{}: st
    case p <> r1: wal_do_setv_e(k, r1, p, st)

def wal_do_setv(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case k <> t: wal_do_setv_p(k, List.reverse(&2, String, t), st)

# DELV: fixed six fields — DELV\t<k>\t<evseq>\t<tenant>\t<etype>\t<payload>.
def wal_do_delv_ev_go(+es: Nat, +k: String, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  wal_push_evt(st_with_db(st, Map.del(&2, String, st_db(st), k)), MkEvt{es, tn, et, p}, es)

def wal_do_delv_ev(mes: Maybe<&1, Nat>, +k: String, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  match mes:
    case None{}: st
    case Some{es}: wal_do_delv_ev_go(es, k, tn, et, p, st)

def wal_do_delv_apply(+k: String, +es: String, +tn: String, +et: String, +p: String, +st: MedState) -> MedState:
  wal_do_delv_ev(parse_nat_opt(es), k, tn, et, p, st)

def wal_do_delv_p2(+k: String, +es: String, +tn: String, +et: String, +p: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: wal_do_delv_apply(k, es, tn, et, p, st)
    case _ <> _: st

def wal_do_delv_p(+k: String, +es: String, +tn: String, +et: String, +t: List<&2, String>, +st: MedState) -> MedState:
  match t:
    case Nil{}: st
    case p <> rest: wal_do_delv_p2(k, es, tn, et, p, rest, st)

def wal_do_delv_e(+k: String, +es: String, +tn: String, +t: List<&2, String>, +st: MedState) -> MedState:
  match t:
    case Nil{}: st
    case et <> t2: wal_do_delv_p(k, es, tn, et, t2, st)

def wal_do_delv_t(+k: String, +es: String, +t: List<&2, String>, +st: MedState) -> MedState:
  match t:
    case Nil{}: st
    case tn <> t2: wal_do_delv_e(k, es, tn, t2, st)

def wal_do_delv_es(+k: String, +t: List<&2, String>, +st: MedState) -> MedState:
  match t:
    case Nil{}: st
    case es <> t2: wal_do_delv_t(k, es, t2, st)

def wal_do_delv(+rest: List<&2, String>, +st: MedState) -> MedState:
  match rest:
    case Nil{}: st
    case k <> t: wal_do_delv_es(k, t, st)

def wal_replay_op_keydel(is_keydel: Bool, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_keydel:
    case True{}: wal_do_keydel(rest, st)
    case False{}: st

def wal_replay_op5(is_keyrot: Bool, is_keydel: Bool, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_keyrot:
    case True{}: wal_do_keyrot(rest, st)
    case False{}: wal_replay_op_keydel(is_keydel, rest, st)

def wal_replay_op4(is_seq: Bool, is_keyrot: Bool, is_keydel: Bool, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_seq:
    case True{}: wal_do_seq(rest, st)
    case False{}: wal_replay_op5(is_keyrot, is_keydel, rest, st)

def wal_replay_op3(is_key: Bool, is_seq: Bool, is_keyrot: Bool, is_keydel: Bool, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_key:
    case True{}: wal_do_key(rest, st)
    case False{}: wal_replay_op4(is_seq, is_keyrot, is_keydel, rest, st)

def wal_replay_op2(is_del: Bool, is_key: Bool, is_seq: Bool, is_keyrot: Bool, is_keydel: Bool, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_del:
    case True{}: wal_do_del(rest, st)
    case False{}: wal_replay_op3(is_key, is_seq, is_keyrot, is_keydel, rest, st)

def wal_replay_op_go(is_set: Bool, is_del: Bool, is_key: Bool, is_seq: Bool, is_keyrot: Bool, is_keydel: Bool, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_set:
    case True{}: wal_do_set(rest, st)
    case False{}: wal_replay_op2(is_del, is_key, is_seq, is_keyrot, is_keydel, rest, st)

# New single-line commit records are dispatched before the legacy chain.
def wal_replay_op_legacy(+op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  wal_replay_op_go(String.eq(op, "SET"), String.eq(op, "DEL"), String.eq(op, "KEY"), String.eq(op, "SEQ"), String.eq(op, "KEYROT"), String.eq(op, "KEYDEL"), rest, st)

def wal_replay_op_new3(is_evt: Bool, +op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_evt:
    case True{}: wal_do_evt(rest, st)
    case False{}: wal_replay_op_legacy(op, rest, st)

def wal_replay_op_new2(is_skey: Bool, is_evt: Bool, +op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_skey:
    case True{}: wal_do_keyseq(rest, st)
    case False{}: wal_replay_op_new3(is_evt, op, rest, st)

def wal_replay_op_new(is_sset: Bool, is_skey: Bool, is_evt: Bool, +op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_sset:
    case True{}: wal_do_setseq(rest, st)
    case False{}: wal_replay_op_new2(is_skey, is_evt, op, rest, st)

# The single-line V records dispatch before the legacy chain; legacy
# SSET/SKEY/EVT/SET/DEL/KEY/SEQ/KEYROT lines remain replayable.
def wal_replay_op_v3(is_delv: Bool, +op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_delv:
    case True{}: wal_do_delv(rest, st)
    case False{}: wal_replay_op_new(String.eq(op, "SSET"), String.eq(op, "SKEY"), String.eq(op, "EVT"), op, rest, st)

def wal_replay_op_v2(is_setv: Bool, is_delv: Bool, +op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_setv:
    case True{}: wal_do_setv(rest, st)
    case False{}: wal_replay_op_v3(is_delv, op, rest, st)

def wal_replay_op_v(is_ssetv: Bool, is_setv: Bool, is_delv: Bool, +op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  match is_ssetv:
    case True{}: wal_do_ssetv(rest, st)
    case False{}: wal_replay_op_v2(is_setv, is_delv, op, rest, st)

def wal_replay_op(+op: String, +rest: List<&2, String>, +st: MedState) -> MedState:
  wal_replay_op_v(String.eq(op, "SSETV"), String.eq(op, "SETV"), String.eq(op, "DELV"), op, rest, st)

def wal_replay_parts(+parts: List<&2, String>, +st: MedState) -> MedState:
  match parts:
    case Nil{}: st
    case op <> rest: wal_replay_op(op, rest, st)

def wal_replay_line_empty(is_empty: Bool, +line: String, +st: MedState) -> MedState:
  match is_empty:
    case True{}: st
    case False{}: wal_replay_parts(split_char(line, ch_tab()), st)

def wal_replay_line(+line: String, +st: MedState) -> MedState:
  wal_replay_line_empty(String.is_empty(line), line, st)

def wal_replay_lines(+lines: List<&2, String>, +st: MedState) -> MedState:
  match lines:
    case Nil{}: st
    case h <> t: wal_replay_lines(t, wal_replay_line(h, st))

# A well-formed WAL always ends each record with \n, so split_char's last
# segment is "". A non-empty last segment is a torn trailing write from a
# crash mid-write: drop it rather than replaying a partial record.
def wal_drop_torn_decide(empty: Bool, +h: String, +t: List<&2, String>) -> List<&2, String>:
  match empty:
    case True{}: List.reverse(&2, String, h <> t)
    case False{}: List.reverse(&2, String, t)

def wal_drop_torn_head(+h: String, +t: List<&2, String>) -> List<&2, String>:
  wal_drop_torn_decide(String.is_empty(h), h, t)

def wal_drop_torn(+rev: List<&2, String>) -> List<&2, String>:
  match rev:
    case Nil{}: Nil{}
    case h <> t: wal_drop_torn_head(h, t)

def wal_replay(+content: String, +st: MedState) -> MedState:
  wal_replay_lines(wal_drop_torn(List.reverse(&2, String, split_char(content, ch_lf()))), st)

# --- snapshots ---
# Snapshot writes are fsync'd like WAL writes (Round 2 item 7): the Bool
# returned is True only if write AND sync both succeeded, so a promoted
# snapshot is durable against process death and OS crashes. This is not a
# power-loss claim, and newly created file metadata would need a
# parent-directory fsync for the strongest POSIX durability argument.

def snap_sync_done(sr: File & Result<&1, &1, U32 & String, Unit>) -> IO(Bool):
  (f3, sres) = sr
  match sres:
    case Fail{e}:
      do IO<Bool>:
        _c : Unit <- File.close(f3)
        IO.pure(Bool, False{})
    case Done{u}:
      do IO<Bool>:
        _c : Unit <- File.close(f3)
        IO.pure(Bool, True{})

def snap_write_done(wr: File & Result<&1, &1, U32 & String, Unit>) -> IO(Bool):
  (f2, res) = wr
  match res:
    case Fail{e}:
      do IO<Bool>:
        _c : Unit <- File.close(f2)
        IO.pure(Bool, False{})
    case Done{u}:
      do IO<Bool>:
        sr : File & Result<&1, &1, U32 & String, Unit> <- File.sync(f2)
        snap_sync_done(sr)

def snap_write_open(r: Result<&1, &1, U32 & String, File>, +content: String) -> IO(Bool):
  match r:
    case Fail{e}: IO.pure(Bool, False{})
    case Done{f}:
      do IO<Bool>:
        wr : File & Result<&1, &1, U32 & String, Unit> <- File.write(f, content)
        snap_write_done(wr)

def snap_kv(+k: String, +v: String) -> String:
  "SET" ++ s_tab() ++ k ++ s_tab() ++ v ++ "\n"

def snap_db_go(+kvs: List<&2, Sigma<&2, &2, String, _ => String>>) -> String:
  match kvs:
    case Nil{}: ""
    case h <> t:
      (k, v) = h
      snap_kv(k, v) ++ snap_db_go(t)

def snap_db(+db: Map<&2, String>) -> String:
  snap_db_go(Map.to_list(&2, String, db))

def snap_keys_go(+kvs: List<&2, Sigma<&2, &2, String, _ => Auth>>) -> String:
  match kvs:
    case Nil{}: ""
    case h <> t:
      (k, +a) = h
      "KEY" ++ s_tab() ++ apikey_serialize(a) ++ "\n" ++ snap_keys_go(t)

def snap_keys(+keys: Map<&2, Auth>) -> String:
  snap_keys_go(Map.to_list(&2, Auth, keys))

# Persisted commit events in the snapshot (Round 2 item 8): the in-memory
# evlog is newest-first; serialize oldest-first so replay (which prepends
# via evt_push) rebuilds newest-first. Bounded by the same 1000-entry trim.
# Placed before the SEQ trailer so snap_trailer_ok is unaffected.
def snap_evts_go(+log: List<&2, Evt>) -> String:
  match log:
    case Nil{}: ""
    case h <> t: wal_evt_line(h) ++ snap_evts_go(t)

def snap_evts(+log: List<&2, Evt>) -> String:
  snap_evts_go(List.reverse(&2, Evt, log))

# --- rate-limit bucket persistence across graceful restart (Round 3 item 172) ---
# The rl map ("bucket-id" -> "window_start,count"; windows anchored on the
# monotonic IO.now clock, one iprl_window_ms window) used to be absent from
# snapshots, so every restart wiped ALL buckets. For kr: (Round 3 item 20,
# MEDIUM_RESTART_RL/60s per presented token) that is self-defeating: the
# limiter lives in the very map the restart destroys, so it could never
# bind an admin chaining restarts -- the exact permanent-restart-loop threat
# the item-20 comment names. The same wipe also refreshed kt:/kb:/ks:/ip:/
# ipd: quotas on every restart (quota amplification via restart chaining).
#
# Fix: the final pre-restart snapshot (st.restart is set; periodic
# snapshots are unaffected) carries an RL section with every still-live
# bucket entry, serialized as a pure duration:
#   RL\t<bucket-id>\t<remaining_ms>\t<count>
# Boot (med_init_after_boot) rebases each entry into the new monotonic
# clock domain: start' = max(0, now + rem - window), rem clamped to one
# window. Expired entries (rem 0) are dropped at save; malformed RL lines
# are skipped at load (fail-closed: a bad line restores nothing). Bucket
# ids are server-constructed ("kr:/ks:/kb:v1$<64hex>", "kt:<alnum-_>",
# "ip:/ipd:<addr>") and cannot contain tab/LF, so the tab-separated line
# format is injection-safe by construction. Crash recovery (SIGKILL) still
# wipes: no final snapshot runs, and periodic snapshots carry no RL
# section -- accepted and documented.

def iprl_window_ms() -> Nat:
  Nat.mul(600n, 100n)

def snap_rl_rem(+now: Nat, +start: Nat) -> Nat:
  Nat.sub(iprl_window_ms(), Nat.sub(now, start))

def snap_rl_emit(skip: Bool, +rem: Nat, +k: String, +count: Nat) -> String:
  match skip:
    case True{}: ""
    case False{}: "RL" ++ s_tab() ++ k ++ s_tab() ++ Nat.show(rem) ++ s_tab() ++ Nat.show(count) ++ "\n"

def snap_rl_line_go(+now: Nat, +k: String, +start: Nat, +count: Nat) -> String:
  snap_rl_emit(Nat.is_eq(snap_rl_rem(now, start), 0n), snap_rl_rem(now, start), k, count)

def snap_rl_parsed(+now: Nat, +k: String, sc: Nat & Nat) -> String:
  (+start, count) = sc
  snap_rl_line_go(now, k, start, count)

def snap_rl_line(+now: Nat, +kv: Sigma<&2, &2, String, _ => String>) -> String:
  (k, v) = kv
  snap_rl_parsed(now, k, rl_parse(v))

def snap_rl_go(+now: Nat, +kvs: List<&2, Sigma<&2, &2, String, _ => String>>) -> String:
  match kvs:
    case Nil{}: ""
    case h <> t: snap_rl_line(now, h) ++ snap_rl_go(now, t)

def snap_rl_section_go(is_restart: Bool, +st: MedState, +now: Nat) -> String:
  match is_restart:
    case True{}: snap_rl_go(now, Map.to_list(&2, String, st_rl(st)))
    case False{}: ""

def snap_rl_section(+st: MedState, +now: Nat) -> String:
  snap_rl_section_go(st_restart(st), st, now)

# --- record-count binding in the snapshot trailer (Round 3 item 189) ---
# Item-188 E8 proved a silent-partial-state path: a snapshot cut at a real
# line boundary with the original valid "SEQ\t<n>" trailer re-appended
# passes the purely syntactic snap_trailer_ok, boots clean, and serves
# 354/600 articles — 246 silently missing (the item-138 archive-coverage
# guard only replays segments newer than the claimed SEQ, so the middle
# range vanishes). The trailer now also carries the number of record lines
# the snapshot claims, and boot verifies the actual count matches (see
# snap_count_ok + the tamper gate in med_init_boot_after_tamper).
# Every record line is one non-empty "\n"-terminated line, so the record
# count is the number of non-empty lines. Replay is unaffected: wal_do_seq
# takes the first field and ignores the rest; snap_seq_of still works
# because rl_nat stops at the first non-digit.
def snap_record_count_go(+lines: List<&2, String>, +acc: Nat) -> Nat:
  match lines:
    case Nil{}: acc
    case h <> t: snap_record_count_go(t, Nat.add(acc, Bool.pick(Nat, String.is_empty(h), 0n, 1n)))

def snap_record_count(+body: String) -> Nat:
  snap_record_count_go(split_char(body, ch_lf()), 0n)

def snap_body(+st: MedState, +now: Nat) -> String:
  snap_db(st_db(st)) ++ snap_keys(st_keys(st)) ++ snap_evts(st_evlog(st)) ++ snap_rl_section(st, now)

def snap_with_trailer(+st: MedState, +body: String) -> String:
  body ++ "SEQ" ++ s_tab() ++ Nat.show(st_seq(st)) ++ s_tab() ++ Nat.show(snap_record_count(body)) ++ "\n"

def snap_content(+st: MedState, +now: Nat) -> String:
  snap_with_trailer(st, snap_body(st, now))

# Item 197: the unsigned snapshot content (body ++ "SEQ\t<seq>\t<count>",
# no trailing newline): the exact bytes the trailer MAC is computed over.
# Pure helper so the affine state can feed both body and seq.
def snap_unsigned_content(+st: MedState, +now: Nat) -> String:
  +body : String = snap_body(st, now)
  body ++ "SEQ" ++ s_tab() ++ Nat.show(st_seq(st)) ++ s_tab() ++ Nat.show(snap_record_count(body))

# Item 197: snapshot content with a signed trailer when a key is configured:
#   SEQ\t<seq>\t<count>\t<mac>
# mac = HMAC-SHA256(key, body ++ "SEQ\t" ++ seq ++ "\t" ++ count).
# With the key empty, byte-identical to snap_content (item-189 3-field
# trailer). The key is read at each snapshot cycle, so a rotation takes
# effect on the next cycle without a restart.
def snap_add_mac(+unsigned: String, +key: String) -> IO(String):
  do IO<String>:
    mac : String <- FS.hmac_sha256_hex(key, unsigned)
    IO.pure(String, unsigned ++ s_tab() ++ mac ++ "\n")

def snap_content_signed_go(no_key: Bool, +st: MedState, +now: Nat, +key: String) -> IO(String):
  match no_key:
    case True{}: IO.pure(String, snap_content(st, now))
    case False{}: snap_add_mac(snap_unsigned_content(st, now), key)

def snap_content_signed(+st: MedState, +now: Nat, +key: String) -> IO(String):
  snap_content_signed_go(String.is_empty(key), st, now, key)

def snap_write_path(+path: String, +content: String) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "w")
    snap_write_open(r, content)

def snap_read_done(rr: File & Result<&1, &1, U32 & String, String>) -> IO(String):
  (f2, res) = rr
  match res:
    case Fail{e}:
      do IO<String>:
        _c : Unit <- File.close(f2)
        IO.pure(String, "")
    case Done{content}:
      do IO<String>:
        _c : Unit <- File.close(f2)
        IO.pure(String, content)

def snap_read_open(r: Result<&1, &1, U32 & String, File>) -> IO(String):
  match r:
    case Fail{e}: IO.pure(String, "")
    case Done{f}:
      do IO<String>:
        # 80 MiB read cap: covers 64 MiB segments plus headroom for the final
        # appended record.
        rr : File & Result<&1, &1, U32 & String, String> <- File.read(f, U32.mul(80, U32.mul(U32.mul(32, 32), U32.mul(32, 32))))
        snap_read_done(rr)

def snap_read_path(+path: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    snap_read_open(r)

# --- snapshot trailer validation ---
# A snapshot is complete iff it ends with "\n" and its last non-empty line
# is the SEQ trailer. Used to pick a good file on startup and to verify
# writes before truncating the WAL.

def snap_nonempty_last(+lines: List<&2, String>, +acc: String) -> String:
  match lines:
    case Nil{}: acc
    case h <> t:
      snap_nonempty_last(t, Bool.pick(String, String.is_empty(h), acc, h))

def snap_trailer_ok(+content: String) -> Bool:
  Bool.and(String.ends_with(content, "\n"),
    String.starts_with(snap_nonempty_last(split_char(content, ch_lf()), ""), "SEQ" ++ s_tab()))

def snap_seq_of_field(+fields: List<&2, String>) -> Nat:
  match fields:
    case Nil{}: 0n
    case seq_s <> _: rl_nat(seq_s)

def snap_seq_of(+content: String) -> Nat:
  snap_seq_of_field(split_char(String.drop(snap_nonempty_last(split_char(content, ch_lf()), ""), 4n), ch_tab()))

# --- snapshot trailer HMAC (Round 3 item 197; T7 residual) ---
# The item-189 count binding ("SEQ\t<seq>\t<count>") stops the naive E8
# forgery, but a filesystem writer can rewrite the count to match a forged
# body. The item-197 trailer appends a 4th field:
#   SEQ\t<seq>\t<count>\t<mac>
# mac = HMAC-SHA256(key, body ++ "SEQ\t" ++ seq ++ "\t" ++ count), where
# key comes from MEDIUM_SNAPSHOT_HMAC_KEY (out-of-band env, never the
# waldir). Pure-Bend HMAC measured ~2 KiB/s native — infeasible for
# boot-time verification of multi-MiB snapshots — so the MAC runs in the
# snap_hmac.c effect (self-contained FIPS 180-4 + RFC 2104).
#
# Key semantics:
# - MEDIUM_SNAPSHOT_HMAC_KEY unset/empty: writer emits the byte-identical
#   item-189 3-field trailer; boot verifies nothing (loud once-per-boot
#   warning). Documented safe default: existing deployments keep working;
#   the degraded mode is exactly the shipped item-189 posture.
# - KEY set: writer signs; boot FATALS on missing/mismatched MAC.
# - MEDIUM_SNAPSHOT_HMAC_KEY_PREV: accepted for VERIFICATION ONLY (never
#   signing). Rotation: set PREV=old + KEY=new, wait one snapshot cycle
#   (500 seqs, or a graceful shutdown's final snapshot), unset PREV.
# - MEDIUM_SNAPSHOT_HMAC_ALLOW_LEGACY=1: one-boot migration flag. With KEY
#   set, a MAC-less trailer is accepted with a loud WARNING (instead of
#   the steady-state FATAL) and the next snapshot cycle re-signs it.
def snap_hmac_key_env(mr: Result<&1, &1, U32 & String, String>) -> String:
  match mr:
    case Fail{e}: ""
    case Done{+s}: s

def snap_hmac_key() -> IO(String):
  do IO<String>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_SNAPSHOT_HMAC_KEY")
    IO.pure(String, snap_hmac_key_env(mr))

def snap_hmac_key_prev() -> IO(String):
  do IO<String>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_SNAPSHOT_HMAC_KEY_PREV")
    IO.pure(String, snap_hmac_key_env(mr))

def snap_hmac_allow_legacy_env(mr: Result<&1, &1, U32 & String, String>) -> Bool:
  match mr:
    case Fail{e}: False{}
    case Done{+s}: String.eq(s, "1")

def snap_hmac_allow_legacy() -> IO(Bool):
  do IO<Bool>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_SNAPSHOT_HMAC_ALLOW_LEGACY")
    IO.pure(Bool, snap_hmac_allow_legacy_env(mr))

# --- snapshot record-count verification (Round 3 item 189) ---
# The trailer line is "SEQ\t<seq>\t<count>" (item 189+). Pre-item-189
# trailers carry only "SEQ\t<seq>" — no count to check; accepted for
# r56->r57 upgrade continuity, with a loud boot warning (see
# snapshot_boot_check below). A trailer with 3+ fields is malformed and
# fails the check loudly.
def snap_trailer_line(+content: String) -> String:
  snap_nonempty_last(split_char(content, ch_lf()), "")

def snap_rest_nonempty(+rest: List<&2, String>) -> Bool:
  match rest:
    case Nil{}: False{}
    case _ <> _: True{}

def snap_count_field_present(+fields: List<&2, String>) -> Bool:
  match fields:
    case Nil{}: False{}
    case _ <> rest: snap_rest_nonempty(rest)

def snap_trailer_has_count(+content: String) -> Bool:
  snap_count_field_present(split_char(String.drop(snap_trailer_line(content), 4n), ch_tab()))

def snap_claimed_count_tail(+tail: List<&2, String>, +cnt: String, +content: String) -> Bool:
  match tail:
    case Nil{}: Nat.is_eq(rl_nat(cnt), Nat.sub(snap_record_count(content), 1n))
    case _ <> _: False{}

def snap_claimed_count_rest(+rest: List<&2, String>, +content: String) -> Bool:
  match rest:
    case Nil{}: True{}
    case cnt <> tail: snap_claimed_count_tail(tail, cnt, content)

def snap_claimed_count_go(+fields: List<&2, String>, +content: String) -> Bool:
  match fields:
    case Nil{}: False{}
    case _ <> rest: snap_claimed_count_rest(rest, content)

def snap_count_ok(+content: String) -> Bool:
  snap_claimed_count_go(split_char(String.drop(snap_trailer_line(content), 4n), ch_tab()), content)

def snap_full_ok(+content: String) -> Bool:
  Bool.and(snap_trailer_ok(content), snap_count_ok(content))

# --- atomic-ish snapshot save ---
# No File.rename in Base, so: write tmp -> verify tmp -> overwrite main ->
# verify main -> clear tmp. A crash during the main overwrite leaves the
# verified tmp behind; startup prefers a verified main, else falls back to
# a verified tmp (tmp is cleared after every successful cycle, so any
# non-empty tmp is strictly newer than main).

def snap_tmp_check(ok: Bool) -> IO(Bool):
  match ok:
    case False{}: IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        content : String <- snap_read_path("bocht.snapshot.tmp")
        IO.pure(Bool, snap_trailer_ok(content))

def snapshot_save_tmp(+st: MedState) -> IO(Bool):
  do IO<Bool>:
    now : Nat <- IO.now()
    key : String <- snap_hmac_key()
    content : String <- snap_content_signed(st, now, key)
    ok : Bool <- snap_write_path("bocht.snapshot.tmp", content)
    snap_tmp_check(ok)

def snap_promote_check(ok: Bool) -> IO(Bool):
  match ok:
    case False{}: IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        content : String <- snap_read_path("bocht.snapshot")
        IO.pure(Bool, snap_trailer_ok(content))

def snapshot_promote(+st: MedState) -> IO(Bool):
  do IO<Bool>:
    now : Nat <- IO.now()
    key : String <- snap_hmac_key()
    content : String <- snap_content_signed(st, now, key)
    ok : Bool <- snap_write_path("bocht.snapshot", content)
    snap_promote_check(ok)

def snap_save_clear(ok: Bool) -> IO(Bool):
  match ok:
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: snapshot promote FAILED, keeping WAL\n")
        IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        _b : Bool <- snap_write_path("bocht.snapshot.tmp", "")
        IO.pure(Bool, True{})

def snap_save_promote(tmp_ok: Bool, +st: MedState) -> IO(Bool):
  match tmp_ok:
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: snapshot tmp write FAILED, keeping WAL\n")
        IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        ok : Bool <- snapshot_promote(st)
        snap_save_clear(ok)

def snapshot_save(+st: MedState) -> IO(Bool):
  do IO<Bool>:
    tmp_ok : Bool <- snapshot_save_tmp(st)
    snap_save_promote(tmp_ok, st)

def snapshot_load_tmp_ok(ok: Bool, +tmp: String) -> IO(String):
  match ok:
    case True{}: IO.pure(String, tmp)
    case False{}: IO.pure(String, "")

def snapshot_load_tmp_go(+tmp: String) -> IO(String):
  snapshot_load_tmp_ok(snap_trailer_ok(tmp), tmp)

def snapshot_load_tmp() -> IO(String):
  do IO<String>:
    tmp : String <- snap_read_path("bocht.snapshot.tmp")
    snapshot_load_tmp_go(tmp)

def snapshot_load_pick(main_ok: Bool, +main: String) -> IO(String):
  match main_ok:
    case True{}: IO.pure(String, main)
    case False{}: snapshot_load_tmp()

def snapshot_load_go(+main: String) -> IO(String):
  snapshot_load_pick(snap_trailer_ok(main), main)

def snapshot_load() -> IO(String):
  do IO<String>:
    main : String <- snap_read_path("bocht.snapshot")
    snapshot_load_go(main)

# --- tamper-evident boot gate (Round 3 item 189) ---
# A non-empty snapshot file with a syntactically valid trailer whose
# record-count binding fails is evidence of out-of-band truncation or
# tampering (the item-188 E8 forgery shape: 354 records + the original
# valid trailer re-appended). Torn/incomplete writes have NO valid trailer
# and are not tamper evidence — they keep the existing fallback/cover
# behavior. Pre-item-189 ("legacy") trailers carry no count field; they
# are accepted for r56->r57 upgrade continuity with a loud warning, and
# are rewritten in the new format on the next snapshot cycle.
def snap_file_bad(+content: String) -> Bool:
  Bool.and(Bool.not(String.is_empty(content)),
    Bool.and(snap_trailer_ok(content), Bool.not(snap_count_ok(content))))

def snap_boot_warn(+content: String) -> Bool:
  Bool.and(Bool.not(String.is_empty(content)),
    Bool.and(snap_trailer_ok(content), Bool.not(snap_trailer_has_count(content))))

def snap_boot_warn_print(warn: Bool) -> IO(Unit):
  match warn:
    case True{}: IO.print("medium-fresh: WARNING: legacy snapshot trailer without record-count binding (pre-item-189 format); accepted for upgrade continuity, rewritten on next snapshot cycle\n")
    case False{}: IO.pure(Unit, Unit{})

def snap_boot_warn_print2(+main: String, +tmp: String) -> IO(Unit):
  do IO<Unit>:
    _a : Unit <- snap_boot_warn_print(snap_boot_warn(main))
    _b : Unit <- snap_boot_warn_print(snap_boot_warn(tmp))
    IO.pure(Unit, Unit{})

def snap_boot_bad2(+main: String, +tmp: String) -> Bool:
  Bool.or(snap_file_bad(main), snap_file_bad(tmp))

def snapshot_boot_check_go(+main: String, +tmp: String) -> IO(Bool):
  do IO<Bool>:
    _w : Unit <- snap_boot_warn_print2(main, tmp)
    IO.pure(Bool, snap_boot_bad2(main, tmp))

def snapshot_boot_check_tmp(+main: String) -> IO(Bool):
  do IO<Bool>:
    tmp : String <- snap_read_path("bocht.snapshot.tmp")
    snapshot_boot_check_go(main, tmp)

def snapshot_boot_check() -> IO(Bool):
  do IO<Bool>:
    main : String <- snap_read_path("bocht.snapshot")
    snapshot_boot_check_tmp(main)

# --- single-split snapshot boot (Round 3 item 196) ---
# Boot used to run split_char over the FULL snapshot content ~10 times
# (snapshot_load trailer pick, snapshot_boot_check trailer+count,
# wal_snap_ok x3, wal_replay, snap_seq_of, wal_snap_max_seq,
# snap_rl_restore). At ~25s per 52 MiB pass (measured 2026-09-28 on the
# item-196 burst snapshot), boot exceeded 5 minutes on large snapshots and
# the SIGKILL+reboot durability probe timed out. snapshot_boot_load splits
# each snapshot file ONCE and every downstream boot step works from that
# single line list. All predicates below are equivalent to their
# content-based originals: snap_ends_lf == String.ends_with(content, "\n"),
# and the empty-content guard in snap_file_bad is subsumed by trailer_ok
# (a trailer_ok file is never empty).

def snap_ends_lf_last(+rest: List<&2, String>, +last: String, +n: Nat) -> Bool:
  match rest:
    case Nil{}: Bool.and(Nat.is_ge(n, 2n), String.is_empty(last))
    case h <> t: snap_ends_lf_last(t, h, Nat.add(n, 1n))

def snap_ends_lf(+lines: List<&2, String>) -> Bool:
  match lines:
    case Nil{}: False{}
    case h <> t: snap_ends_lf_last(t, h, 1n)

def snap_lines_ok(+lines: List<&2, String>) -> Bool:
  Bool.and(snap_ends_lf(lines),
    String.starts_with(snap_nonempty_last(lines, ""), "SEQ" ++ s_tab()))

# Item 197: a 4-field trailer [seq, count, mac] still binds the count
# (the MAC covers it too); 5+ fields is malformed.
def snap_claimed_count_tail_rest(+rest: List<&2, String>, +c: String, +cnt: Nat) -> Bool:
  match rest:
    case Nil{}: Nat.is_eq(rl_nat(c), Nat.sub(cnt, 1n))
    case _ <> _: False{}

def snap_claimed_count_tail_scan(+tail: List<&2, String>, +c: String, +cnt: Nat) -> Bool:
  match tail:
    case Nil{}: Nat.is_eq(rl_nat(c), Nat.sub(cnt, 1n))
    case _ <> rest: snap_claimed_count_tail_rest(rest, c, cnt)

def snap_claimed_count_rest_scan(+rest: List<&2, String>, +cnt: Nat) -> Bool:
  match rest:
    case Nil{}: True{}
    case c <> tail: snap_claimed_count_tail_scan(tail, c, cnt)

def snap_claimed_count_scan(+fields: List<&2, String>, +cnt: Nat) -> Bool:
  match fields:
    case Nil{}: False{}
    case _ <> rest: snap_claimed_count_rest_scan(rest, cnt)

def snap_count_ok_trailer(+trailer: String, +cnt: Nat) -> Bool:
  +fields : List<&2, String> = split_char(String.drop(trailer, 4n), ch_tab())
  snap_claimed_count_scan(fields, cnt)

def snap_lines_count_ok(+lines: List<&2, String>) -> Bool:
  +trailer : String = snap_nonempty_last(lines, "")
  +cnt : Nat = snap_record_count_go(lines, 0n)
  snap_count_ok_trailer(trailer, cnt)

def snap_lines_bad(+lines: List<&2, String>) -> Bool:
  Bool.and(snap_lines_ok(lines), Bool.not(snap_lines_count_ok(lines)))

def snap_lines_pick_tmp(tmp_ok: Bool, +tampered: Bool, +tlines: List<&2, String>) -> List<&2, String> & Bool:
  match tmp_ok:
    case True{}: (tlines, tampered)
    case False{}: (split_char("", ch_lf()), tampered)

def snap_lines_pick_which(main_ok: Bool, tmp_ok: Bool, +tampered: Bool, +mlines: List<&2, String>, +tlines: List<&2, String>) -> List<&2, String> & Bool:
  match main_ok:
    case True{}: (mlines, tampered)
    case False{}: snap_lines_pick_tmp(tmp_ok, tampered, tlines)

def snap_lines_pick(+mlines: List<&2, String>, +tlines: List<&2, String>) -> List<&2, String> & Bool:
  +main_ok : Bool = snap_lines_ok(mlines)
  +tmp_ok : Bool = snap_lines_ok(tlines)
  +tampered : Bool = Bool.or(snap_lines_bad(mlines), snap_lines_bad(tlines))
  snap_lines_pick_which(main_ok, tmp_ok, tampered, mlines, tlines)

# --- snapshot trailer HMAC verification (Round 3 item 197) ---
# Runs on the single-split line lists (item-196): no extra full-content
# passes. The MAC message is rebuilt from the scanned lines as
#   body ++ "SEQ\t" ++ seq_field ++ "\t" ++ count_field
# using the RAW field strings, so the verifier hashes byte-identical input
# to the writer. Body = all lines except the trailer line and the trailing
# "" (joined with "\n" plus one "\n"; "" when the body is empty).

# The trailer line's fields after "SEQ\t": [seq], [seq, count],
# [seq, count, mac], or longer (malformed).
def snap_trailer_fields(+lines: List<&2, String>) -> List<&2, String>:
  split_char(String.drop(snap_nonempty_last(lines, ""), 4n), ch_tab())

def snap_drop2(+lines: List<&2, String>) -> List<&2, String>:
  match lines:
    case Nil{}: Nil{}
    case _ <> rest:
      match rest:
        case Nil{}: Nil{}
        case _ <> rest2: rest2

def snap_body_lines(+lines: List<&2, String>) -> List<&2, String>:
  List.reverse(&2, String, snap_drop2(List.reverse(&2, String, lines)))

def snap_join_body(+lines: List<&2, String>) -> String:
  match lines:
    case Nil{}: ""
    case _ <> _: join_str(lines, "\n") ++ "\n"

def snap_mac_msg_of(+lines: List<&2, String>, +seq_s: String, +count_s: String) -> String:
  snap_join_body(snap_body_lines(lines)) ++ "SEQ" ++ s_tab() ++ seq_s ++ s_tab() ++ count_s

def snap_hmac_prev_cmp(ok: Bool) -> IO(Bool):
  match ok:
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: NOTICE snapshot trailer verified under MEDIUM_SNAPSHOT_HMAC_KEY_PREV (rotation in progress; re-sign with the new key on the next snapshot cycle)\n")
        IO.pure(Bool, False{})
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: FATAL snapshot trailer HMAC mismatch under both MEDIUM_SNAPSHOT_HMAC_KEY and MEDIUM_SNAPSHOT_HMAC_KEY_PREV (possible forgery); refusing to boot\n")
        IO.pure(Bool, True{})

def snap_hmac_try_prev(prev_empty: Bool, +lines: List<&2, String>, +seq_s: String, +count_s: String, +mac_s: String, +prev: String) -> IO(Bool):
  match prev_empty:
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: FATAL snapshot trailer HMAC mismatch (possible forgery or wrong MEDIUM_SNAPSHOT_HMAC_KEY); refusing to boot\n")
        IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        pmac : String <- FS.hmac_sha256_hex(prev, snap_mac_msg_of(lines, seq_s, count_s))
        snap_hmac_prev_cmp(String.eq(pmac, mac_s))

def snap_hmac_mac_cmp(ok: Bool, +lines: List<&2, String>, +seq_s: String, +count_s: String, +mac_s: String, +prev: String) -> IO(Bool):
  match ok:
    case True{}: IO.pure(Bool, False{})
    case False{}: snap_hmac_try_prev(String.is_empty(prev), lines, seq_s, count_s, mac_s, prev)

def snap_hmac_verify_mac_go(no_key: Bool, +lines: List<&2, String>, +seq_s: String, +count_s: String, +mac_s: String, +key: String, +prev: String) -> IO(Bool):
  match no_key:
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WARNING snapshot trailer carries a MAC but MEDIUM_SNAPSHOT_HMAC_KEY is not set; cannot verify (count binding only)\n")
        IO.pure(Bool, False{})
    case False{}:
      do IO<Bool>:
        mac : String <- FS.hmac_sha256_hex(key, snap_mac_msg_of(lines, seq_s, count_s))
        snap_hmac_mac_cmp(String.eq(mac, mac_s), lines, seq_s, count_s, mac_s, prev)

def snap_hmac_verify_mac(+lines: List<&2, String>, +seq_s: String, +count_s: String, +mac_s: String, +key: String, +prev: String) -> IO(Bool):
  snap_hmac_verify_mac_go(String.is_empty(key), lines, seq_s, count_s, mac_s, key, prev)

def snap_hmac_nomac_key_set(+allow_legacy: Bool, +desc: String) -> IO(Bool):
  match allow_legacy:
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WARNING " ++ desc ++ " but MEDIUM_SNAPSHOT_HMAC_KEY is set; accepted via MEDIUM_SNAPSHOT_HMAC_ALLOW_LEGACY=1, will re-sign on next snapshot cycle\n")
        IO.pure(Bool, False{})
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: FATAL " ++ desc ++ " but MEDIUM_SNAPSHOT_HMAC_KEY is set (downgrade shape); refusing to boot (set MEDIUM_SNAPSHOT_HMAC_ALLOW_LEGACY=1 for one boot to migrate)\n")
        IO.pure(Bool, True{})

def snap_hmac_nomac_bad_go(no_key: Bool, +allow_legacy: Bool, +desc: String) -> IO(Bool):
  match no_key:
    case True{}: IO.pure(Bool, False{})
    case False{}: snap_hmac_nomac_key_set(allow_legacy, desc)

def snap_hmac_nomac_bad(+key: String, +allow_legacy: Bool, +desc: String) -> IO(Bool):
  snap_hmac_nomac_bad_go(String.is_empty(key), allow_legacy, desc)

def snap_hmac_after_mac(+rest3: List<&2, String>, +seq_s: String, +count_s: String, +mac_s: String, +lines: List<&2, String>, +key: String, +prev: String) -> IO(Bool):
  match rest3:
    case Nil{}: snap_hmac_verify_mac(lines, seq_s, count_s, mac_s, key, prev)
    case _ <> _:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: FATAL snapshot trailer has more than 4 fields (malformed); refusing to boot\n")
        IO.pure(Bool, True{})

def snap_hmac_after_count(+rest2: List<&2, String>, +seq_s: String, +count_s: String, +lines: List<&2, String>, +key: String, +prev: String, +allow_legacy: Bool) -> IO(Bool):
  match rest2:
    case Nil{}:
      snap_hmac_nomac_bad(key, allow_legacy, "snapshot trailer without MAC (item-189 format)")
    case mac_s <> rest3: snap_hmac_after_mac(rest3, seq_s, count_s, mac_s, lines, key, prev)

def snap_hmac_after_seq(+rest: List<&2, String>, +seq_s: String, +lines: List<&2, String>, +key: String, +prev: String, +allow_legacy: Bool) -> IO(Bool):
  match rest:
    case Nil{}:
      snap_hmac_nomac_bad(key, allow_legacy, "legacy snapshot trailer (pre item-189, no count/MAC)")
    case count_s <> rest2: snap_hmac_after_count(rest2, seq_s, count_s, lines, key, prev, allow_legacy)

def snap_hmac_fields_bad(+fields: List<&2, String>, +lines: List<&2, String>, +key: String, +prev: String, +allow_legacy: Bool) -> IO(Bool):
  match fields:
    case Nil{}: IO.pure(Bool, False{})
    case seq_s <> rest: snap_hmac_after_seq(rest, seq_s, lines, key, prev, allow_legacy)

def snap_file_hmac_bad_go(ok: Bool, +lines: List<&2, String>, +key: String, +prev: String, +allow_legacy: Bool) -> IO(Bool):
  match ok:
    case False{}: IO.pure(Bool, False{})
    case True{}: snap_hmac_fields_bad(snap_trailer_fields(lines), lines, key, prev, allow_legacy)

# Item 197: IO verdict for one snapshot file's trailer. True = HMAC-tampered
# (boot must refuse). Prints the specific diagnostic; the generic boot
# FATAL fires downstream via the tampered flag. Files without a valid
# trailer are not our concern here (torn writes keep the item-182 cover
# behavior; they are not tamper evidence).
def snap_file_hmac_bad(+lines: List<&2, String>, +key: String, +prev: String, +allow_legacy: Bool) -> IO(Bool):
  snap_file_hmac_bad_go(snap_lines_ok(lines), lines, key, prev, allow_legacy)

def snap_hmac_boot_bad(+mlines: List<&2, String>, +tlines: List<&2, String>, +key: String, +prev: String, +allow_legacy: Bool) -> IO(Bool):
  do IO<Bool>:
    b1 : Bool <- snap_file_hmac_bad(mlines, key, prev, allow_legacy)
    b2 : Bool <- snap_file_hmac_bad(tlines, key, prev, allow_legacy)
    IO.pure(Bool, Bool.or(b1, b2))

def snap_combine_bad(res: List<&2, String> & Bool, +hmac_bad: Bool) -> List<&2, String> & Bool:
  match res:
    case (lines, bad): (lines, Bool.or(bad, hmac_bad))

# Item 197: once-per-boot loud warning when the HMAC key is unset. The
# degraded mode is exactly the shipped item-189 posture (count binding
# only); the warning makes the posture explicit instead of silent.
def snap_hmac_boot_warn_go(no_key: Bool) -> IO(Unit):
  match no_key:
    case True{}: IO.print("medium-fresh: WARNING MEDIUM_SNAPSHOT_HMAC_KEY is not set — snapshot trailer HMAC signing/verification DISABLED (count binding only)\n")
    case False{}: IO.pure(Unit, Unit{})

def snap_hmac_boot_warn(+key: String) -> IO(Unit):
  snap_hmac_boot_warn_go(String.is_empty(key))

# snapshot_boot_load: read main+tmp, split each ONCE, pick the valid one,
# and report the tamper flag (item-189 count binding OR item-197 HMAC).
# Replaces the snapshot_load + snapshot_boot_check pair (which re-read and
# re-split everything).
def snapshot_boot_load() -> IO(List<&2, String> & Bool):
  do IO<List<&2, String> & Bool>:
    +main : String <- snap_read_path("bocht.snapshot")
    +tmp : String <- snap_read_path("bocht.snapshot.tmp")
    +mlines : List<&2, String> = split_char(main, ch_lf())
    +tlines : List<&2, String> = split_char(tmp, ch_lf())
    +key : String <- snap_hmac_key()
    +prev : String <- snap_hmac_key_prev()
    +allow_legacy : Bool <- snap_hmac_allow_legacy()
    _w : Unit <- snap_hmac_boot_warn(key)
    +hmac_bad : Bool <- snap_hmac_boot_bad(mlines, tlines, key, prev, allow_legacy)
    IO.pure(List<&2, String> & Bool, snap_combine_bad(snap_lines_pick(mlines, tlines), hmac_bad))

# --- segmented-WAL boot, replay, archive, purge (Round 3 item 14) ---
# Block B: uses snap_read_path/snap_trailer_ok (defined above).

def wal_segnums_add(mn: Maybe<&1, Nat>, +acc: List<&2, Nat>) -> List<&2, Nat>:
  match mn:
    case None{}: acc
    case Some{n}: n <> acc

def wal_segnums_go(+names: List<&2, String>, +acc: List<&2, Nat>) -> List<&2, Nat>:
  match names:
    case Nil{}: acc
    case h <> t: wal_segnums_go(t, wal_segnums_add(wal_segnum_name(h), acc))

def wal_segnums_dir(+dir: String) -> IO(List<&2, Nat>):
  do IO<List<&2, Nat>>:
    listing : String <- FS.list_dir(dir)
    IO.pure(List<&2, Nat>, wal_segnums_go(split_char(listing, ch_lf()), Nil{}))

# --- torn-tail amputation at boot (Round 3 item 145 fix) ---
# wal_drop_torn drops a torn trailing record from the REPLAYED TEXT ONLY; the
# torn bytes stay in the segment file. The next wal_write then GLUES its
# complete line onto the torn bytes (append mode, no truncation, no tail
# check): the glued line parses as a record under the torn key (garbage
# value, seq still advanced) or is dropped for a garbage opcode, and a crash
# before the next snapshot loses the 201-acked write for good (item 145:
# 201-acked article -> 404, 201-acked key -> 401 after the second crash).
# Amputate once per boot, after replay and before any wal_write (including
# the purge preservation write): if the max-numbered active segment is
# non-empty and its last byte is not "\n", rewrite it keeping only bytes
# through the last "\n" via tmp + atomic FS.rename_seg, so every later append
# starts on a clean line boundary. The torn bytes contributed nothing to
# replayed state, so the rewrite is state-preserving. Fail-open: any IO error
# leaves the file untouched (the old drop_torn replay behavior still protects
# replay) and is logged loudly. Returns True when the tail is clean or was
# successfully amputated.

def wal_torn_kept_tail(+t: List<&2, String>) -> String:
  match t:
    case Nil{}: ""
    case _ <> _: join_str(List.reverse(&2, String, t), "\n") ++ "\n"

def wal_torn_kept_rev(+rev: List<&2, String>) -> String:
  match rev:
    case Nil{}: ""
    case _h <> t: wal_torn_kept_tail(t)

def wal_torn_kept(+parts: List<&2, String>) -> String:
  wal_torn_kept_rev(List.reverse(&2, String, parts))

def wal_tail_torn_byte(+bs: List<&2, U32>) -> Bool:
  match bs:
    case Nil{}: False{}
    case b <> _t: Bool.not(U32.is_eq(b, (10 : U32)))

def wal_amputate_tail_rr(rr: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Bool):
  (f2, res) = rr
  match res:
    case Fail{e}:
      do IO<Bool>:
        _c : Unit <- File.close(f2)
        IO.pure(Bool, False{})
    case Done{+bs}:
      do IO<Bool>:
        _c : Unit <- File.close(f2)
        IO.pure(Bool, wal_tail_torn_byte(bs))

def wal_amputate_tail_go(is_empty: Bool, f: File, +sz: U32) -> IO(Bool):
  match is_empty:
    case True{}:
      do IO<Bool>:
        _c : Unit <- File.close(f)
        IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        +off : U32 = U32.sub(sz, (1 : U32))
        tr : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_at(f, off, (1 : U32))
        wal_amputate_tail_rr(tr)

def wal_amputate_sized(rr: File & Result<&1, &1, U32 & String, U32>) -> IO(Bool):
  (f2, res) = rr
  match res:
    case Fail{e}:
      do IO<Bool>:
        _c : Unit <- File.close(f2)
        IO.pure(Bool, False{})
    case Done{+sz}:
      wal_amputate_tail_go(U32.is_eq(sz, (0 : U32)), f2, sz)

def wal_amputate_open(r: Result<&1, &1, U32 & String, File>) -> IO(Bool):
  match r:
    case Fail{e}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL torn-tail check: cannot open segment, leaving untouched\n")
        IO.pure(Bool, False{})
    case Done{f}:
      do IO<Bool>:
        sr : File & Result<&1, &1, U32 & String, U32> <- File.size(f)
        wal_amputate_sized(sr)

def wal_amputate_tail_torn(+path: String) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    wal_amputate_open(r)

def wal_amputate_rename_logged(ok: Bool, +path: String) -> IO(Bool):
  match ok:
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL torn-tail amputation: rename FAILED, leaving segment untouched\n")
        IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        _a : U32 <- FS.sync_dir(wal_active_dir())
        _u : Unit <- IO.print("medium-fresh: WAL torn-tail amputation: amputated torn tail of " ++ path ++ "\n")
        IO.pure(Bool, True{})

def wal_amputate_rename_done(ok: Bool, +path: String, +tmp: String) -> IO(Bool):
  do IO<Bool>:
    _d : U32 <- FS.unlink(tmp)
    wal_amputate_rename_logged(ok, path)

def wal_amputate_renamed(ok: Bool, +path: String, +tmp: String) -> IO(Bool):
  match ok:
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL torn-tail amputation: tmp write FAILED, leaving segment untouched\n")
        IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        r : U32 <- FS.rename_seg(tmp, path)
        wal_amputate_rename_done(u32_ok(r), path, tmp)

def wal_amputate_rewrite(+path: String, +content: String) -> IO(Bool):
  +kept : String = wal_torn_kept(split_char(content, ch_lf()))
  +tmp : String = path ++ ".amputmp"
  do IO<Bool>:
    ok : Bool <- snap_write_path(tmp, kept)
    wal_amputate_renamed(ok, path, tmp)

def wal_amputate_decide(torn: Bool, +path: String) -> IO(Bool):
  match torn:
    case False{}: IO.pure(Bool, True{})
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL torn-tail amputation: torn tail detected in " ++ path ++ ", amputating\n")
        content : String <- snap_read_path(path)
        wal_amputate_rewrite(path, content)

def wal_amputate_max(+m: Nat) -> IO(Bool):
  do IO<Bool>:
    torn : Bool <- wal_amputate_tail_torn(wal_seg_path(m))
    wal_amputate_decide(torn, wal_seg_path(m))

def wal_amputate_nums(+nums: List<&2, Nat>) -> IO(Bool):
  match nums:
    case Nil{}: IO.pure(Bool, True{})
    case _ <> _: wal_amputate_max(nats_max(nums))

def wal_amputate_torn_tail() -> IO(Bool):
  do IO<Bool>:
    nums : List<&2, Nat> <- wal_segnums_dir(wal_active_dir())
    wal_amputate_nums(nums)


def wal_dirnums_add(mn: Maybe<&1, Nat>, +acc: List<&2, Nat>) -> List<&2, Nat>:
  match mn:
    case None{}: acc
    case Some{n}: n <> acc

def wal_dirnums_go(+names: List<&2, String>, +acc: List<&2, Nat>) -> List<&2, Nat>:
  match names:
    case Nil{}: acc
    case h <> t: wal_dirnums_go(t, wal_dirnums_add(parse_nat_opt(h), acc))

def wal_dirnums(+dir: String) -> IO(List<&2, Nat>):
  do IO<List<&2, Nat>>:
    listing : String <- FS.list_dir(dir)
    IO.pure(List<&2, Nat>, wal_dirnums_go(split_char(listing, ch_lf()), Nil{}))

# Recursive archive-tree walk collecting segment numbers. No tuples, no
# list append: subdirectories recurse inline, numbers cons onto acc.
# Bounded-depth archive scan (wal/archive/YYYY/MM/). The archive layout is
# fixed at two levels, so no general recursive tree walk is needed (Bend
# forbids the mutual recursion a general walk would require). Directory
# listings are filtered by wal_segnums_dir/wal_dirnums, which safely skip
# non-matching names (including the empty trailing entry from split).

def wal_boot_max_months(+ms: List<&2, Nat>, +ydir: String, +best: Nat) -> IO(Nat):
  match ms:
    case Nil{}: IO.pure(Nat, best)
    case m <> t:
      do IO<Nat>:
        nums : List<&2, Nat> <- wal_segnums_dir(ydir ++ "/" ++ wal_zpad2(m))
        wal_boot_max_months(t, ydir, nats_max_ab(best, nats_max(nums)))

def wal_boot_max_year(+y: Nat, +best: Nat) -> IO(Nat):
  do IO<Nat>:
    ms : List<&2, Nat> <- wal_dirnums(wal_archive_dir() ++ "/" ++ wal_zpad4(y))
    wal_boot_max_months(ms, wal_archive_dir() ++ "/" ++ wal_zpad4(y), best)

def wal_boot_max_years(+ys: List<&2, Nat>, +best: Nat) -> IO(Nat):
  match ys:
    case Nil{}: IO.pure(Nat, best)
    case y <> t:
      do IO<Nat>:
        b2 : Nat <- wal_boot_max_year(y, best)
        wal_boot_max_years(t, b2)

def wal_boot_max_arch() -> IO(Nat):
  do IO<Nat>:
    ys : List<&2, Nat> <- wal_dirnums(wal_archive_dir())
    wal_boot_max_years(ys, 0n)

# Archive-nonempty walk (companion to wal_boot_max_arch): the max walk alone
# cannot distinguish "archive empty" (max 0) from "archive holds seg-0"
# (max 0). Both walks are boot-only and the tree is shallow, so the extra
# pass is cheap. Self-recursive (Bend forbids the mutual recursion a
# shared decide-helper would need).

def wal_list_empty(+xs: List<&2, Nat>) -> Bool:
  match xs:
    case Nil{}: True{}
    case _ <> _: False{}

def wal_arch_any_month(+ms: List<&2, Nat>, +ydir: String) -> IO(Bool):
  match ms:
    case Nil{}: IO.pure(Bool, False{})
    case m <> t:
      do IO<Bool>:
        nums : List<&2, Nat> <- wal_segnums_dir(ydir ++ "/" ++ wal_zpad2(m))
        rest : Bool <- wal_arch_any_month(t, ydir)
        IO.pure(Bool, Bool.or(Bool.not(wal_list_empty(nums)), rest))

def wal_arch_any_year(+y: Nat) -> IO(Bool):
  do IO<Bool>:
    ms : List<&2, Nat> <- wal_dirnums(wal_archive_dir() ++ "/" ++ wal_zpad4(y))
    wal_arch_any_month(ms, wal_archive_dir() ++ "/" ++ wal_zpad4(y))

def wal_arch_any_years(+ys: List<&2, Nat>) -> IO(Bool):
  match ys:
    case Nil{}: IO.pure(Bool, False{})
    case y <> t:
      do IO<Bool>:
        one : Bool <- wal_arch_any_year(y)
        rest : Bool <- wal_arch_any_years(t)
        IO.pure(Bool, Bool.or(one, rest))

def wal_archive_nonempty() -> IO(Bool):
  do IO<Bool>:
    ys : List<&2, Nat> <- wal_dirnums(wal_archive_dir())
    wal_arch_any_years(ys)

# --- boot ---

def wal_boot_legacy_done(ok: Bool) -> IO(Bool):
  match ok:
    case False{}: IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: imported legacy bocht.wal as wal/active/seg-000000.wal\n")
        IO.pure(Bool, True{})

def wal_boot_legacy_sz(nonempty: Bool) -> IO(Bool):
  match nonempty:
    case False{}: IO.pure(Bool, True{})
    case True{}:
      do IO<Bool>:
        r : U32 <- FS.rename_seg("bocht.wal", wal_seg_path(0n))
        wal_boot_legacy_done(u32_ok(r))

def wal_boot_legacy(empty: Bool) -> IO(Bool):
  match empty:
    case False{}: IO.pure(Bool, True{})
    case True{}:
      do IO<Bool>:
        sz : U32 <- FS.file_size("bocht.wal")
        wal_boot_legacy_sz(u32_ok(sz))

# The counter must exceed every segment number ever assigned. The counter
# file is authoritative when present; when it is missing or unreadable and
# wal/active/ is empty, fall back to archive_max+1 - never archive_max
# (reusing the newest archived number would clash on the next archive and
# confuse replay ranges). When wal/active/ is non-empty its max is the live
# segment being appended to, so the counter stays there.
def wal_boot_fix_empty(arch_nonempty: Bool, +base: Nat, +arch_max: Nat) -> Nat:
  match arch_nonempty:
    case False{}: base
    case True{}: nats_max_ab(base, Nat.add(arch_max, 1n))

def wal_boot_fix(active_empty: Bool, arch_nonempty: Bool, +base: Nat, +arch_max: Nat) -> Nat:
  match active_empty:
    case False{}: base
    case True{}: wal_boot_fix_empty(arch_nonempty, base, arch_max)

def wal_boot_max_act(+act: List<&2, Nat>, +cur: Nat, arch_nonempty: Bool, +arch_max: Nat) -> Nat:
  match act:
    case Nil{}: wal_boot_fix(True{}, arch_nonempty, nats_max_ab(cur, arch_max), arch_max)
    case _ <> _: wal_boot_fix(False{}, arch_nonempty, nats_max_ab(cur, nats_max_ab(nats_max(act), arch_max)), arch_max)

def wal_boot_max(+cur: Nat) -> IO(Nat):
  do IO<Nat>:
    arch : Nat <- wal_boot_max_arch()
    act : List<&2, Nat> <- wal_segnums_dir(wal_active_dir())
    nonempty : Bool <- wal_archive_nonempty()
    IO.pure(Nat, wal_boot_max_act(act, cur, nonempty, arch))

def wal_boot_done(+maxn: Nat) -> IO(Bool):
  do IO<Bool>:
    _s : Bool <- wal_seg_set_current(maxn)
    _d : U32 <- FS.sync_dir(wal_dir())
    _u : Unit <- IO.print("medium-fresh: segmented WAL ready (wal/active/, counter=" ++ Nat.show(maxn) ++ ")\n")
    IO.pure(Bool, True{})

# A wal/ or wal/active/ that cannot be created is fatal: serving without a
# WAL would silently lose every commit, so the service refuses to start.
def wal_boot_mkdir(ok: Bool) -> IO(Bool):
  match ok:
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: FATAL: cannot create wal/ or wal/active/, refusing to start\n")
        IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        _c : U32 <- FS.sync_dir(wal_dir())
        act : List<&2, Nat> <- wal_segnums_dir(wal_active_dir())
        _l : Bool <- wal_boot_legacy(wal_list_empty(act))
        cur : Nat <- wal_seg_current()
        maxn : Nat <- wal_boot_max(cur)
        wal_boot_done(maxn)

def wal_boot() -> IO(Bool):
  do IO<Bool>:
    a : U32 <- FS.mkdir_p(wal_dir())
    b : U32 <- FS.mkdir_p(wal_active_dir())
    wal_boot_mkdir(Bool.and(u32_ok(a), u32_ok(b)))

# --- replay: active segments in numeric order; archive only as fallback ---
# On a valid snapshot only wal/active/ replays (archived segments are
# covered by the snapshot). On a corrupt/missing snapshot the archive
# replays first in (year, month, segnum) order, then wal/active/.

# Replay reads exactly the segments the directory listing enumerates, in
# ascending numeric order. Gaps are harmless (a missing name simply has no
# file). This never ranges over min..max: a hostile seg-999999.wal cannot
# turn boot replay into a million-file scan.
def wal_concat_segs_each(+nums: List<&2, Nat>, +dir: String, +acc: String) -> IO(String):
  match nums:
    case Nil{}: IO.pure(String, acc)
    case n <> t:
      do IO<String>:
        c : String <- snap_read_path(dir ++ "/" ++ wal_seg_name(n))
        # Item 146 fix: strip a torn tail from EVERY segment before
        # concatenating. The old `acc ++ c` glued a non-final segment's torn
        # tail onto the next segment's first line, destroying a
        # 201-acknowledged record at replay (and the phantom record the glue
        # created was then persisted into snapshots). Every wal_write entry
        # ends with \n, so bytes after the last \n are always a torn partial
        # write, never a valid record. This covers active and archived
        # segments (both flow through here) and all opcodes. The item-145
        # max-segment physical amputation is kept: it prevents the distinct
        # append-glue bug, which a read-time strip cannot address.
        wal_concat_segs_each(t, dir, acc ++ wal_torn_kept(split_char(c, ch_lf())))

def wal_concat_segs_go(is_empty: Bool, +nums: List<&2, Nat>, +dir: String) -> IO(String):
  match is_empty:
    case True{}: IO.pure(String, "")
    case False{}: wal_concat_segs_each(nats_sort(nums), dir, "")

def wal_concat_active_go(+nums: List<&2, Nat>) -> IO(String):
  wal_concat_segs_go(wal_list_empty(nums), nums, wal_active_dir())

def wal_concat_active() -> IO(String):
  do IO<String>:
    nums : List<&2, Nat> <- wal_segnums_dir(wal_active_dir())
    wal_concat_active_go(nums)

def wal_concat_month_go(+nums: List<&2, Nat>, +y: Nat, +m: Nat) -> IO(String):
  wal_concat_segs_go(wal_list_empty(nums), nums, wal_archive_dir() ++ "/" ++ wal_zpad4(y) ++ "/" ++ wal_zpad2(m))

def wal_concat_month(+y: Nat, +m: Nat) -> IO(String):
  do IO<String>:
    nums : List<&2, Nat> <- wal_segnums_dir(wal_archive_dir() ++ "/" ++ wal_zpad4(y) ++ "/" ++ wal_zpad2(m))
    wal_concat_month_go(nums, y, m)

def wal_concat_months_n(+n: Nat, +y: Nat, +m: Nat, +acc: String) -> IO(String):
  match n:
    case 0n: IO.pure(String, acc)
    case 1n+p:
      do IO<String>:
        c : String <- wal_concat_month(y, m)
        wal_concat_months_n(p, y, Nat.add(m, 1n), acc ++ c)

def wal_concat_year(+y: Nat) -> IO(String):
  wal_concat_months_n(12n, y, 1n, "")

# Archive years iterate the enumerated year directories (sorted ascending),
# never a min..max range: a bogus 9999/ directory cannot force thousands of
# empty year scans at boot.
def wal_concat_years_each(+ys: List<&2, Nat>, +acc: String) -> IO(String):
  match ys:
    case Nil{}: IO.pure(String, acc)
    case y <> t:
      do IO<String>:
        c : String <- wal_concat_year(y)
        wal_concat_years_each(t, acc ++ c)

def wal_concat_archive_go(is_empty: Bool, +ys: List<&2, Nat>) -> IO(String):
  match is_empty:
    case True{}: IO.pure(String, "")
    case False{}: wal_concat_years_each(nats_sort(ys), "")

def wal_concat_archive_go2(+ys: List<&2, Nat>) -> IO(String):
  wal_concat_archive_go(wal_list_empty(ys), ys)

def wal_concat_archive() -> IO(String):
  do IO<String>:
    ys : List<&2, Nat> <- wal_dirnums(wal_archive_dir())
    wal_concat_archive_go2(ys)

def wal_read_all(snap_ok: Bool) -> IO(String):
  match snap_ok:
    case True{}: wal_concat_active()
    case False{}:
      do IO<String>:
        arch : String <- wal_concat_archive()
        act : String <- wal_concat_active()
        IO.pure(String, arch ++ act)

# --- archive: move covered segments after a verified snapshot ---
# Civil date via Howard Hinnant's days-to-civil algorithm (branch-free;
# large constants built arithmetically - see wal_seg_cap_default note).

def wal_c_1000() -> Nat:
  Nat.mul(10n, Nat.mul(10n, 10n))

def wal_c_719468() -> Nat:
  Nat.add(Nat.mul(719n, wal_c_1000()), 468n)

def wal_c_146097() -> Nat:
  Nat.add(Nat.mul(146n, wal_c_1000()), 97n)

def wal_c_146096() -> Nat:
  Nat.add(Nat.mul(146n, wal_c_1000()), 96n)

def wal_c_36524() -> Nat:
  Nat.add(Nat.mul(36n, wal_c_1000()), 524n)

def wal_pick_m(is_lt10: Bool, +mp: Nat) -> Nat:
  match is_lt10:
    case True{}: Nat.add(mp, 3n)
    case False{}: Nat.sub(mp, 9n)

def wal_pick_y2(is_le2: Bool, +y: Nat) -> Nat:
  match is_le2:
    case True{}: Nat.add(y, 1n)
    case False{}: y

# Seconds per day: 86,400.
def wal_c_day_secs() -> Nat:
  Nat.add(Nat.mul(86n, wal_c_1000()), 400n)

def wal_ym_code(+days: Nat) -> Nat:
  +z : Nat = Nat.add(days, wal_c_719468())
  +era : Nat = Nat.div(z, wal_c_146097())
  +doe : Nat = Nat.sub(z, Nat.mul(era, wal_c_146097()))
  +yoe : Nat = Nat.div(Nat.sub(Nat.add(Nat.sub(doe, Nat.div(doe, 1460n)), Nat.div(doe, wal_c_36524())), Nat.div(doe, wal_c_146096())), 365n)
  +y : Nat = Nat.add(yoe, Nat.mul(era, 400n))
  +doy : Nat = Nat.sub(doe, Nat.sub(Nat.add(Nat.mul(365n, yoe), Nat.div(yoe, 4n)), Nat.div(yoe, 100n)))
  +mp : Nat = Nat.div(Nat.add(Nat.mul(5n, doy), 2n), 153n)
  +m : Nat = wal_pick_m(Nat.is_lt(mp, 10n), mp)
  +y2 : Nat = wal_pick_y2(Nat.is_le(m, 2n), y)
  Nat.add(Nat.mul(y2, 100n), m)

def wal_ym_path(+ym: Nat) -> String:
  wal_zpad4(Nat.div(ym, 100n)) ++ "/" ++ wal_zpad2(Nat.mod(ym, 100n))

# Wall-clock epoch seconds via native effect. (IO.now() is monotonic/uptime,
# not wall-clock, so it cannot be used for archive dating or purge ages.)
def wal_now_sec() -> IO(Nat):
  do IO<Nat>:
    t : U32 <- FS.now_sec()
    IO.pure(Nat, U32.to_nat(t))

def wal_yyyymm(+now_sec: Nat) -> String:
  wal_ym_path(wal_ym_code(Nat.div(now_sec, wal_c_day_secs())))

def wal_num_member_go(+n: Nat, +nums: List<&2, Nat>) -> Bool:
  match nums:
    case Nil{}: False{}
    case h <> t: Bool.or(Nat.is_eq(n, h), wal_num_member_go(n, t))

def wal_any_member(+xs: List<&2, Nat>, +ys: List<&2, Nat>) -> Bool:
  match xs:
    case Nil{}: False{}
    case h <> t: Bool.or(wal_num_member_go(h, ys), wal_any_member(t, ys))

def wal_archive_clash(+dest: String, +nums: List<&2, Nat>) -> IO(Bool):
  do IO<Bool>:
    existing : List<&2, Nat> <- wal_segnums_dir(dest)
    IO.pure(Bool, wal_any_member(nums, existing))

def wal_archive_bump(ok: Bool, +moved: Nat) -> Nat:
  match ok:
    case True{}: Nat.add(moved, 1n)
    case False{}: moved

# A failed rename is only a moved-count shortfall in wal_archive_go, so log it
# loudly here: the segment stays active and retries after the next snapshot.
def wal_archive_one_logged(ok: Bool, +n: Nat) -> IO(Bool):
  match ok:
    case True{}: IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL archive WARNING: rename failed for " ++ wal_seg_name(n) ++ "; segment stays active and will retry after next snapshot\n")
        IO.pure(Bool, False{})

def wal_archive_one(+n: Nat, +dest: String) -> IO(Bool):
  do IO<Bool>:
    r : U32 <- FS.rename_seg(wal_seg_path(n), dest ++ "/" ++ wal_seg_name(n))
    wal_archive_one_logged(u32_ok(r), n)

def wal_archive_go(+nums: List<&2, Nat>, +dest: String, +moved: Nat) -> IO(Nat):
  match nums:
    case Nil{}:
      do IO<Nat>:
        _a : U32 <- FS.sync_dir(dest)
        _b : U32 <- FS.sync_dir(wal_active_dir())
        IO.pure(Nat, moved)
    case n <> t:
      do IO<Nat>:
        ok : Bool <- wal_archive_one(n, dest)
        wal_archive_go(t, dest, wal_archive_bump(ok, moved))

def wal_archive_checked(ok: Bool, +nums: List<&2, Nat>, +dest: String) -> IO(Nat):
  match ok:
    case False{}:
      do IO<Nat>:
        _u : Unit <- IO.print("medium-fresh: WAL archive deferred (setup failed); will retry after next snapshot\n")
        IO.pure(Nat, 0n)
    case True{}: wal_archive_go(nums, dest, 0n)

# The clash is checked BEFORE the counter bump: a deferred archive must not
# advance the counter (the bump is only meaningful when the moves that
# follow will actually happen). Returns False on clash (defer) or a failed
# bump.
def wal_archive_bump_go(clash: Bool, +nums: List<&2, Nat>) -> IO(Bool):
  match clash:
    case True{}: IO.pure(Bool, False{})
    case False{}: wal_seg_set_current(Nat.add(nats_max(nums), 1n))

def wal_archive_precheck(+ym: String, +nums: List<&2, Nat>) -> IO(Bool):
  do IO<Bool>:
    mk : U32 <- FS.mkdir_p(wal_archive_dir() ++ "/" ++ ym)
    _sd : U32 <- FS.sync_dir(wal_archive_dir() ++ "/" ++ ym)
    _sp : U32 <- FS.sync_dir(wal_archive_dir())
    clash : Bool <- wal_archive_clash(wal_archive_dir() ++ "/" ++ ym, nums)
    bump : Bool <- wal_archive_bump_go(clash, nums)
    IO.pure(Bool, Bool.and(u32_ok(mk), bump))

def wal_archive_nums(+nums: List<&2, Nat>, +ym: String) -> IO(Nat):
  match nums:
    case Nil{}: IO.pure(Nat, 0n)
    case _ <> _:
      do IO<Nat>:
        ok : Bool <- wal_archive_precheck(ym, nums)
        wal_archive_checked(ok, nums, wal_archive_dir() ++ "/" ++ ym)

def wal_archive_covered(+now_sec: Nat) -> IO(Nat):
  do IO<Nat>:
    nums : List<&2, Nat> <- wal_segnums_dir(wal_active_dir())
    wal_archive_nums(nums, wal_yyyymm(now_sec))

# --- purge: delete archived segments older than the retention window ---
# Runs at boot: dry-run first (logged), then for real (logged). With the
# 10000-day default retention both remove nothing.

def wal_purge_retention_num(mn: Maybe<&1, Nat>) -> Nat:
  match mn:
    case None{}: wal_purge_retention_days_default()
    case Some{n}: n

def wal_purge_retention_env(mr: Result<&1, &1, U32 & String, String>) -> Nat:
  match mr:
    case Fail{e}: wal_purge_retention_days_default()
    case Done{+s}: wal_purge_retention_num(parse_nat_opt(s))

def wal_purge_retention_days() -> IO(Nat):
  do IO<Nat>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_WAL_PURGE_DAYS")
    IO.pure(Nat, wal_purge_retention_env(mr))

def wal_purge_old2(in_past: Bool, +age_s: Nat, +days: Nat) -> Bool:
  match in_past:
    case False{}: False{}
    case True{}: Bool.not(Nat.is_le(Nat.div(age_s, wal_c_day_secs()), days))

def wal_purge_old(+mt_s: Nat, +now_s: Nat, +days: Nat) -> Bool:
  wal_purge_old2(Nat.is_le(mt_s, now_s), Nat.sub(now_s, mt_s), days)


def wal_purge_unlink2(+dry: Bool, +full: String) -> IO(Bool):
  match dry:
    case True{}: IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        ok : U32 <- FS.unlink(full)
        # FS.unlink returns 1 on success (ENOENT counts as success: the
        # purge is idempotent), 0 on failure. Report honestly so the
        # "removed N" log count is real (Round 3 item 144 fix: it used to
        # report True unconditionally).
        IO.pure(Bool, Nat.is_eq(U32.to_nat(ok), 1n))

def wal_purge_unlink(do_it: Bool, +dry: Bool, +full: String) -> IO(Bool):
  match do_it:
    case False{}: IO.pure(Bool, False{})
    case True{}: wal_purge_unlink2(dry, full)

def wal_del_bump(gone: Bool, +deleted: Nat) -> Nat:
  match gone:
    case True{}: Nat.add(deleted, 1n)
    case False{}: deleted

def wal_purge_one(+full: String, +now_s: Nat, +days: Nat, +dry: Bool) -> IO(Bool):
  do IO<Bool>:
    mt : U32 <- FS.file_mtime(full)
    wal_purge_unlink(wal_purge_old(U32.to_nat(mt), now_s, days), dry, full)

def wal_purge_nums(+nums: List<&2, Nat>, +d: String, +now_s: Nat, +days: Nat, +dry: Bool, +deleted: Nat) -> IO(Nat):
  match nums:
    case Nil{}: IO.pure(Nat, deleted)
    case n <> t:
      do IO<Nat>:
        gone : Bool <- wal_purge_one(d ++ "/" ++ wal_seg_name(n), now_s, days, dry)
        wal_purge_nums(t, d, now_s, days, dry, wal_del_bump(gone, deleted))

def wal_purge_month(+y: Nat, +m: Nat, +now_s: Nat, +days: Nat, +dry: Bool, +deleted: Nat) -> IO(Nat):
  do IO<Nat>:
    nums : List<&2, Nat> <- wal_segnums_dir(wal_archive_dir() ++ "/" ++ wal_zpad4(y) ++ "/" ++ wal_zpad2(m))
    wal_purge_nums(nums, wal_archive_dir() ++ "/" ++ wal_zpad4(y) ++ "/" ++ wal_zpad2(m), now_s, days, dry, deleted)

def wal_purge_months(+ms: List<&2, Nat>, +y: Nat, +now_s: Nat, +days: Nat, +dry: Bool, +deleted: Nat) -> IO(Nat):
  match ms:
    case Nil{}: IO.pure(Nat, deleted)
    case m <> t:
      do IO<Nat>:
        d2 : Nat <- wal_purge_month(y, m, now_s, days, dry, deleted)
        wal_purge_months(t, y, now_s, days, dry, d2)

def wal_purge_year(+y: Nat, +now_s: Nat, +days: Nat, +dry: Bool, +deleted: Nat) -> IO(Nat):
  do IO<Nat>:
    ms : List<&2, Nat> <- wal_dirnums(wal_archive_dir() ++ "/" ++ wal_zpad4(y))
    wal_purge_months(ms, y, now_s, days, dry, deleted)

def wal_purge_years(+ys: List<&2, Nat>, +now_s: Nat, +days: Nat, +dry: Bool, +deleted: Nat) -> IO(Nat):
  match ys:
    case Nil{}: IO.pure(Nat, deleted)
    case y <> t:
      do IO<Nat>:
        d2 : Nat <- wal_purge_year(y, now_s, days, dry, deleted)
        wal_purge_years(t, now_s, days, dry, d2)

def wal_purge_days(+days: Nat, +dry: Bool) -> IO(Nat):
  do IO<Nat>:
    now_sec : Nat <- wal_now_sec()
    ys : List<&2, Nat> <- wal_dirnums(wal_archive_dir())
    wal_purge_years(ys, now_sec, days, dry, 0n)

def wal_purge_dry() -> IO(Nat):
  do IO<Nat>:
    days : Nat <- wal_purge_retention_days()
    wal_purge_days(days, True{})

def wal_purge() -> IO(Nat):
  do IO<Nat>:
    days : Nat <- wal_purge_retention_days()
    wal_purge_days(days, False{})

def wal_snap_ok(+snap: String) -> Bool:
  snap_trailer_ok(snap)

# --- purge key preservation (Round 3 item 144 fix) ---
# The purge deletes archived segments whose records may be the ONLY WAL
# copy of key records: the bootstrap admin key is written once at
# bootstrap and never re-recorded (unless rotated), so it always sits in
# the oldest archived segment — the first purge victim. The purge gate
# ("a valid snapshot exists") only proves the snapshot covers those
# records NOW; if that snapshot is later lost or corrupted (the exact
# scenario the snapshot+WAL dual exists to survive — cf. the defensive
# boot guard, items 137/138/143), the purged keys are unrecoverable.
# Demonstrated live: after a purge deleted the admin KEY record, a
# snapshot corruption left the admin credential permanently at 401, with
# ~1000 articles unrecoverable the same way.
# Fix: when the dry-run finds >=1 segment to delete, first re-append every
# LIVE key as a KEY line to the active WAL (fsync'd via wal_write), then
# delete. Replay is idempotent and last-write-wins per key, and the
# forwarded records ARE the live state, so appending them after all
# retained segments is correct. Revoked keys are absent from the live map,
# so nothing is resurrected. Data (article) records keep snapshot-coverage
# semantics: purged-then-snapshot-lost data is unrecoverable, and since
# item 182 (r55) the boot gate refuses loudly (FATAL) in that case rather
# than serving silently incomplete data. With the default 10000-day
# retention the dry-run is always 0 and this is a complete no-op.
def wal_purge_preserve_blob(+kvs: List<&2, Sigma<&2, &2, String, _ => Auth>>) -> String:
  match kvs:
    case Nil{}: ""
    case h <> t:
      (k, +a) = h
      "KEY" ++ s_tab() ++ apikey_serialize(a) ++ "\n" ++ wal_purge_preserve_blob(t)

def wal_purge_preserve_logged(ok: Bool, n: Nat) -> IO(Unit):
  match ok:
    case False{}:
      IO.print("medium-fresh: WAL purge: KEY PRESERVATION WRITE FAILED - skipping deletion of archived segments\n")
    case True{}:
      IO.print("medium-fresh: WAL purge: preserved " ++ Nat.show(n) ++ " live key record(s) in active WAL\n")

# Returns True when the live keys are safely re-anchored in the active WAL
# (or when there is nothing to preserve). The purge MUST NOT delete
# archived segments unless this returns True: if the preservation write
# fails (disk full, IO error), deletion is skipped and the failure is
# logged loudly. Fail-closed: an un-anchored key record must never have
# its last archived copy deleted.
def wal_purge_do_preserve_ok(+keys: Map<&2, Auth>) -> IO(Bool):
  do IO<Bool>:
    +ok : Bool <- wal_write(wal_purge_preserve_blob(Map.to_list(&2, Auth, keys)))
    _u : Unit <- wal_purge_preserve_logged(ok, Map.size(&2, Auth, keys))
    IO.pure(Bool, ok)

def wal_purge_maybe_preserve_ok(has_old: Bool, +keys: Map<&2, Auth>) -> IO(Bool):
  match has_old:
    case False{}: IO.pure(Bool, True{})
    case True{}: wal_purge_do_preserve_ok(keys)

def wal_purge_boot5(+n: Nat) -> IO(Nat):
  do IO<Nat>:
    _v : Unit <- IO.print("medium-fresh: WAL purge: removed " ++ Nat.show(n) ++ " archived segment(s)\n")
    IO.pure(Nat, n)

def wal_purge_log_path() -> String:
  "wal/purge.log"

# --- purge-log compaction (Round 3 item 191) ---
# wal/purge.log is the item-182 durable tombstone: append-only, one
# "PURGED\t<unix_sec>\t<count>\n" line per boot-with-purge. With the
# 10000-day default retention it never grows; once an operator lowers
# retention it grows ~20-25B per purging boot (item 188 C) - a slow,
# operator-driven leak with no cap. This section bounds it WITHOUT
# weakening the item-182 fail-closed boot gate.
#
# Design: in-place COMPACTION, not generation rotation. A generation rename
# (old -> purge.log.1, then write a fresh purge.log) has a crash window in
# which purge.log is absent or empty: the boot gate (wal_purge_log_has_entries)
# would then read "no purge happened" - a false negative that resurrects the
# r53 silent-data-loss bug. Compaction has no such window:
#   write purge.log.compacttmp (fsync) -> atomic rename over purge.log ->
#   fsync dir. The rename is the only destructive step and it happens last.
# Crash analysis:
#   - crash before rename: the original log is intact -> fail-closed preserved
#   - crash after rename: the cumulative line carries the signal forward
# Boot-gate semantics are UNCHANGED: ANY line starting with "PURGED\t"
# (individual or cumulative) is a load-bearing tombstone, so a missing/
# invalid snapshot plus any recorded purge still refuses loudly (FATAL).
# The cumulative count keeps the item-187 probe-level property "tombstone
# counts sum == files deleted" (the sum equals total segments purged ever).
# Audit note: individual purge-event lines folded away by a compaction lose
# their per-event timestamps; only the cumulative total survives. The count
# is monotonic across compactions.
# Compaction is itself fail-closed: on any failure (read/write/rename) the
# original log is untouched (rename is last) and the pending tombstone still
# appends to the original log, so the pending deletion's signal is never lost.
# A log with no PURGED lines at all is never compacted: writing a
# "PURGED\t0" line there would FABRICATE a tombstone (false FATAL later).

def wal_purge_log_max_default() -> Nat:
  65536n

def wal_purge_log_max_num(mn: Maybe<&1, Nat>) -> Nat:
  match mn:
    case None{}: wal_purge_log_max_default()
    case Some{n}: n

def wal_purge_log_max_env(mr: Result<&1, &1, U32 & String, String>) -> Nat:
  match mr:
    case Fail{e}: wal_purge_log_max_default()
    case Done{+s}: wal_purge_log_max_num(parse_nat_opt(s))

def wal_purge_log_max_bytes() -> IO(Nat):
  do IO<Nat>:
    mr : Result<&1, &1, U32 & String, String> <- IO.get_env("MEDIUM_WAL_PURGE_LOG_MAX_BYTES")
    IO.pure(Nat, wal_purge_log_max_env(mr))

def wal_purge_nat_of(mn: Maybe<&1, Nat>) -> Nat:
  match mn:
    case None{}: 0n
    case Some{n}: n

def wal_purge_log_fields_count(+fields: List<&2, String>) -> Nat:
  match fields:
    case Nil{}: 0n
    case _tag <> rest:
      match rest:
        case Nil{}: 0n
        case _ts <> rest2:
          match rest2:
            case Nil{}: 0n
            case cnt <> _: wal_purge_nat_of(parse_nat_opt(cnt))

# The tag check stays at line level (same as wal_purge_log_has_go): only a
# line starting with "PURGED\t" is a tombstone. The field split is only
# for extracting the count; a "PURGEDX\t..." junk line never reaches it.
def wal_purge_log_line_count(+line: String) -> Nat:
  Bool.pick(Nat, String.starts_with(line, "PURGED" ++ s_tab()),
    wal_purge_log_fields_count(split_char(line, ch_tab())), 0n)

def wal_purge_log_fold(+lines: List<&2, String>, +acc: Nat) -> Nat:
  match lines:
    case Nil{}: acc
    case h <> t:
      wal_purge_log_fold(t, Nat.add(acc, wal_purge_log_line_count(h)))

def wal_purge_log_compact_tmp() -> String:
  wal_purge_log_path() ++ ".compacttmp"

def wal_purge_log_compact_done(ok: Bool, +tmp: String) -> IO(Bool):
  match ok:
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL purge.log compaction: rename FAILED, keeping original log\n")
        _d : U32 <- FS.unlink(tmp)
        IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        _d : U32 <- FS.sync_dir(wal_dir())
        _u : Unit <- IO.print("medium-fresh: WAL purge.log compacted (cumulative tombstone)\n")
        IO.pure(Bool, True{})

def wal_purge_log_compact_promote(ok: Bool, +tmp: String) -> IO(Bool):
  match ok:
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL purge.log compaction: tmp write FAILED, keeping original log\n")
        IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        r : U32 <- FS.rename_seg(tmp, wal_purge_log_path())
        wal_purge_log_compact_done(u32_ok(r), tmp)

def wal_purge_log_compact_write(skip: Bool, +total: Nat, +now_s: Nat) -> IO(Bool):
  match skip:
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL purge.log compaction: no tombstones to fold, leaving log untouched\n")
        IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        +line : String = "PURGED" ++ s_tab() ++ Nat.show(now_s) ++ s_tab() ++ Nat.show(total) ++ "\n"
        +tmp : String = wal_purge_log_compact_tmp()
        ok : Bool <- snap_write_path(tmp, line)
        wal_purge_log_compact_promote(ok, tmp)

def wal_purge_log_compact_do() -> IO(Bool):
  do IO<Bool>:
    content : String <- snap_read_path(wal_purge_log_path())
    now_s : Nat <- wal_now_sec()
    +total : Nat = wal_purge_log_fold(split_char(content, ch_lf()), 0n)
    wal_purge_log_compact_write(Nat.is_eq(total, 0n), total, now_s)

def wal_purge_log_compact_decide(big: Bool) -> IO(Bool):
  match big:
    case False{}: IO.pure(Bool, True{})
    case True{}: wal_purge_log_compact_do()

# Missing file -> FS.file_size returns 0 -> below any cap -> no-op.
def wal_purge_log_compact_maybe() -> IO(Bool):
  do IO<Bool>:
    maxb : Nat <- wal_purge_log_max_bytes()
    sz : U32 <- FS.file_size(wal_purge_log_path())
    wal_purge_log_compact_decide(Nat.is_ge(U32.to_nat(sz), maxb))

# --- purge tombstone log (Round 3 item 182, r55) ---
# Every archived-segment deletion performed by the purge is recorded FIRST
# in wal/purge.log (append + fsync; the deletion is skipped if the log
# write fails - fail-closed, same philosophy as the item-144 key
# preservation). A snapshot that is missing/invalid at boot combined with
# ANY recorded purge means retired segments' records are unrecoverable:
# their only other copy was the snapshot. Boot then refuses loudly (FATAL)
# instead of serving silently incomplete data (demonstrated live on r53:
# 498/600 articles vanished with a clean boot and no error).
#
# Why a log and not filename inference: the purge deletes by mtime age,
# which need not be a prefix - manipulated mtimes can make it delete a
# MIDDLE segment while seg-0 remains, and seg-0's presence then proves
# nothing. The log records what the server itself deleted, immune to
# hostile segment filenames (item14 P6b's seg-999999.wal) and to
# non-prefix purges alike. Line format: "PURGED\t<unix_sec>\t<count>\n";
# only the leading "PURGED\t" tag is load-bearing at boot.

def wal_purge_log_append(+line: String) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(wal_purge_log_path(), "a")
    wal_write_open(r, line)

def wal_purge_tombstone_logged(ok: Bool) -> IO(Bool):
  match ok:
    case True{}:
      do IO<Bool>:
        _d : U32 <- FS.sync_dir(wal_dir())
        IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: WAL purge: TOMBSTONE WRITE FAILED - skipping deletion of archived segments\n")
        IO.pure(Bool, False{})

def wal_purge_tombstone_go(none: Bool, +dry: Nat) -> IO(Bool):
  match none:
    case True{}: IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        # Round 3 item 191: compact the tombstone log before appending, so it
        # stays bounded. Compaction failure is non-fatal here: the tombstone
        # still appends to the original log (fail-closed; the pending
        # deletion's signal is never lost).
        _c : Bool <- wal_purge_log_compact_maybe()
        now_s : Nat <- wal_now_sec()
        ok : Bool <- wal_purge_log_append("PURGED" ++ s_tab() ++ Nat.show(now_s) ++ s_tab() ++ Nat.show(dry) ++ "\n")
        wal_purge_tombstone_logged(ok)

def wal_purge_tombstone_write(+dry: Nat) -> IO(Bool):
  wal_purge_tombstone_go(Nat.is_eq(dry, 0n), dry)

def wal_purge_delete_after_tombstone(tombstoned: Bool, +days: Nat) -> IO(Nat):
  match tombstoned:
    case False{}: IO.pure(Nat, 0n)
    case True{}:
      do IO<Nat>:
        n : Nat <- wal_purge_days(days, False{})
        wal_purge_boot5(n)

def wal_purge_delete_tombstoned(+days: Nat, +dry: Nat) -> IO(Nat):
  do IO<Nat>:
    tombstoned : Bool <- wal_purge_tombstone_write(dry)
    wal_purge_delete_after_tombstone(tombstoned, days)

def wal_purge_maybe_delete(ok: Bool, +days: Nat, +dry: Nat) -> IO(Nat):
  match ok:
    case False{}: IO.pure(Nat, 0n)
    case True{}: wal_purge_delete_tombstoned(days, dry)

def wal_purge_log_has_go(+lines: List<&2, String>) -> Bool:
  match lines:
    case Nil{}: False{}
    case h <> t: Bool.or(String.starts_with(h, "PURGED" ++ s_tab()), wal_purge_log_has_go(t))

def wal_purge_log_has_entries() -> IO(Bool):
  do IO<Bool>:
    content : String <- snap_read_path(wal_purge_log_path())
    IO.pure(Bool, wal_purge_log_has_go(split_char(content, ch_lf())))

def wal_purge_boot4(+keys: Map<&2, Auth>, +days: Nat, +dry: Nat) -> IO(Nat):
  do IO<Nat>:
    _u : Unit <- IO.print("medium-fresh: WAL purge dry-run: " ++ Nat.show(dry) ++ " archived segment(s) older than " ++ Nat.show(days) ++ " days\n")
    ok : Bool <- wal_purge_maybe_preserve_ok(Bool.not(Nat.is_eq(dry, 0n)), keys)
    n : Nat <- wal_purge_maybe_delete(ok, days, dry)
    wal_purge_boot5(n)

def wal_purge_boot3(+keys: Map<&2, Auth>, +days: Nat) -> IO(Nat):
  do IO<Nat>:
    dry : Nat <- wal_purge_days(days, True{})
    wal_purge_boot4(keys, days, dry)

def wal_purge_boot2(+keys: Map<&2, Auth>) -> IO(Nat):
  do IO<Nat>:
    days : Nat <- wal_purge_retention_days()
    wal_purge_boot3(keys, days)

def wal_purge_boot(+keys: Map<&2, Auth>, snap_ok: Bool) -> IO(Nat):
  match snap_ok:
    case False{}:
      do IO<Nat>:
        _u : Unit <- IO.print("medium-fresh: WAL purge skipped (no valid snapshot)\n")
        IO.pure(Nat, 0n)
    case True{}: wal_purge_boot2(keys)

# --- persistence wiring: replay + snapshotting ---
# Replay order on startup: snapshot first, then WAL (WAL wins; all ops are
# idempotent). Snapshot cycle: save -> verify (content ends with the current
# SEQ line, proving the write completed) -> truncate WAL. The verify step
# makes truncation safe: we never discard the WAL unless the snapshot is
# known-good. Without it, a crash during truncation could lose the WAL tail.

def med_empty() -> MedState:
  MkMed{Map.new(&2, String), Map.new(&2, Auth), 1n, Nil{}, 0n, Nil{}, Map.new(&2, String), 0n, 0n, 0n, False{}, default_restart_rl(), default_key_rl()}

# --- defensive boot guard: snapshot-must-cover-archive (Round 3 item 138) ---
# The valid-snapshot boot path skips the archive on the load-bearing
# invariant that every archived segment is covered by the snapshot: the
# archive runs only after a verified snapshot save, and the single-threaded
# owner makes snapshot+archive atomic w.r.t. writes, so every archived
# record/event seq is <= the snapshot's. If the archive ever holds a NEWER
# seq than the snapshot (unreachable in real operation; producible only by
# out-of-band corruption or tampering with the snapshot files), the snapshot
# does NOT cover the archive and skipping it would silently drop data. The
# guard replays the archive too in that case - and logs loudly - instead of
# skipping it silently.
# The max-seq scan reuses wal_replay itself (torn lines dropped, item-136
# max-defense on st_seq, max-defense on evseq), so "max seq found" is exactly
# what a replay of that text would apply; both the record-id space (st_seq)
# and the event space (st_evseq) are compared, because a violation can hide
# in either. Provably a no-op on legitimate boots: the archive then holds
# only pre-snapshot seqs, so arch_max <= snap_max always and the active-only
# path is taken exactly as before (empty archive -> arch_max 1 <= snap_max).
# A false positive fails safe: the fallback is a superset replay and all
# replay ops are idempotent. Boot-cost note: the guard reads the full
# archive on every valid-snapshot boot (retention-bounded).

def wal_state_max_seq(+st: MedState) -> Nat:
  nats_max_ab(st_seq(st), st_evseq(st))

# --- archive high-water mark (Round 3 item 196) ---
# O(1) replacement for the item-138 guard's archive scan. After a verified
# snapshot, every archived segment holds only seqs <= wal_state_max_seq(st).
# We persist that max in wal/archive/COVERED before moving segments; boot
# compares it to the snapshot trailer seq. If COVERED > snap_seq, the
# snapshot may not cover the archive -> defensive replay of the archive.
# Crash-safe: written BEFORE the moves. A crash after the write but before
# the moves leaves COVERED high with segments still active; the just-written
# snapshot (seq S) then satisfies COVERED <= S unless evseq > S, in which
# case we take a safe false-positive archive replay. COVERED never
# underestimates the archive max (high-water mark), so a missed violation
# is impossible. Missing/unparseable COVERED (pre-fix archives) ->
# conservative: replay the archive rather than skipping it.
# Note: snap_seq_of is the trailer's st_seq, which can understate the true
# snapshot max when evseq > st_seq; understating only causes safe false
# positives, never missed violations.
def wal_covered_path() -> String:
  wal_archive_dir() ++ "/COVERED"

def wal_covered_write_nat(+cv: Nat) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, File> <- File.open(wal_covered_path(), "w")
    wal_write_open(r, Nat.show(cv) ++ "\n")

def wal_covered_read_head(+parts: List<&2, String>) -> Maybe<&1, Nat>:
  match parts:
    case Nil{}: None{}
    case h <> _t: parse_nat_opt(h)

def wal_covered_read_got(rr: File & Result<&1, &1, U32 & String, String>) -> IO(Maybe<&1, Nat>):
  (f2, res) = rr
  match res:
    case Fail{e}:
      do IO<Maybe<&1, Nat>>:
        _c : Unit <- File.close(f2)
        IO.pure(Maybe<&1, Nat>, None{})
    case Done{content}:
      do IO<Maybe<&1, Nat>>:
        _c : Unit <- File.close(f2)
        IO.pure(Maybe<&1, Nat>, wal_covered_read_head(split_char(content, ch_lf())))

def wal_covered_read_open(r: Result<&1, &1, U32 & String, File>) -> IO(Maybe<&1, Nat>):
  match r:
    case Fail{e}: IO.pure(Maybe<&1, Nat>, None{})
    case Done{f}:
      do IO<Maybe<&1, Nat>>:
        rr : File & Result<&1, &1, U32 & String, String> <- File.read(f, 64)
        wal_covered_read_got(rr)

def wal_covered_read() -> IO(Maybe<&1, Nat>):
  do IO<Maybe<&1, Nat>>:
    r : Result<&1, &1, U32 & String, File> <- File.open(wal_covered_path(), "r")
    wal_covered_read_open(r)

def wal_defend_branch(violated: Bool, +arch_max: Nat, +snap_max: Nat) -> IO(String):
  match violated:
    case False{}: wal_concat_active()
    case True{}:
      do IO<String>:
        _u : Unit <- IO.print("medium-fresh: DEFENSIVE BOOT: archive max seq " ++ Nat.show(arch_max) ++ " exceeds snapshot max seq " ++ Nat.show(snap_max) ++ "; replaying archived segments instead of skipping (snapshot does not cover the archive)\n")
        arch : String <- wal_concat_archive()
        act : String <- wal_concat_active()
        IO.pure(String, arch ++ act)

def wal_defend_covered(mcov: Maybe<&1, Nat>, +snap: String) -> IO(String):
  match mcov:
    case Some{+c}:
      wal_defend_branch(Nat.is_lt(snap_seq_of(snap), c), c, snap_seq_of(snap))
    case None{}:
      do IO<String>:
        _u : Unit <- IO.print("medium-fresh: DEFENSIVE BOOT: no archive high-water mark (pre-fix archive); replaying archived segments conservatively\n")
        arch : String <- wal_concat_archive()
        act : String <- wal_concat_active()
        IO.pure(String, arch ++ act)

def wal_defend_true(+snap: String) -> IO(String):
  do IO<String>:
    mcov : Maybe<&1, Nat> <- wal_covered_read()
    wal_defend_covered(mcov, snap)

def wal_read_all_defended_go(snap_ok: Bool, +snap: String) -> IO(String):
  match snap_ok:
    case False{}: wal_read_all(False{})
    case True{}: wal_defend_true(snap)

def wal_read_all_defended(+snap: String) -> IO(String):
  wal_read_all_defended_go(wal_snap_ok(snap), snap)

def snap_lines_seq_field(+fields: List<&2, String>) -> Nat:
  match fields:
    case Nil{}: 0n
    case seq_s <> _: rl_nat(seq_s)

def snap_lines_seq(+lines: List<&2, String>) -> Nat:
  snap_lines_seq_field(split_char(String.drop(snap_nonempty_last(lines, ""), 4n), ch_tab()))

def wal_defend_covered_lines(mcov: Maybe<&1, Nat>, +lines: List<&2, String>) -> IO(String):
  match mcov:
    case Some{+c}:
      wal_defend_branch(Nat.is_lt(snap_lines_seq(lines), c), c, snap_lines_seq(lines))
    case None{}:
      do IO<String>:
        _u : Unit <- IO.print("medium-fresh: DEFENSIVE BOOT: no archive high-water mark (pre-fix archive); replaying archived segments conservatively\n")
        arch : String <- wal_concat_archive()
        act : String <- wal_concat_active()
        IO.pure(String, arch ++ act)

def wal_read_all_defended_scan(+lines: List<&2, String>) -> IO(String):
  do IO<String>:
    mcov : Maybe<&1, Nat> <- wal_covered_read()
    wal_defend_covered_lines(mcov, lines)

# --- snapshot-loss loud failure (Round 3 item 182; r55 tombstone) ---
# If the snapshot is missing or fails trailer validation, refuse to boot
# when retired WAL data is provably unrecoverable. Two layers:
#
# 1. Purge tombstone (primary): every archived-segment deletion performed
#    by the purge is recorded first in wal/purge.log (append + fsync; the
#    deletion is skipped if the log write fails). ANY recorded purge means
#    retired segments were deleted whose only other copy was the snapshot,
#    so a missing/invalid snapshot makes their records unrecoverable.
#    This is exact - no filename inference - and covers non-prefix purges
#    (mtime manipulation deleting a middle segment while seg-0 remains)
#    as well as the classic oldest-first case. Immune to hostile segment
#    filenames (item14 P6b's seg-999999.wal): planting files never writes
#    the log.
# 2. seg-0 fallback: if the log shows no purge (pre-tombstone data, or the
#    log itself lost out-of-band) but segments exist without seg-0, the
#    oldest retired records are unaccounted for - refuse as well. A fresh
#    server (no segments at all) passes vacuously.
#
# Booting in either case would serve silently incomplete data (demonstrated
# live on r53: 498/600 articles vanished with a clean boot and no error).
# Refuse loudly instead (fail-closed, cf. item 144). Note this supersedes
# the old fail-open "retention trade-off" expectation (items 144/169):
# purge + snapshot loss is provably unrecoverable, so it must not boot.

def wal_list_append_go(+t: List<&2, Nat>, +ys: List<&2, Nat>) -> List<&2, Nat>:
  match t:
    case Nil{}: ys
    case h <> t2: h <> wal_list_append_go(t2, ys)

def wal_list_append(+xs: List<&2, Nat>, +ys: List<&2, Nat>) -> List<&2, Nat>:
  match xs:
    case Nil{}: ys
    case h <> t: h <> wal_list_append_go(t, ys)

def wal_arch_segnums_month(+y: Nat, +m: Nat, +acc: List<&2, Nat>) -> IO(List<&2, Nat>):
  do IO<List<&2, Nat>>:
    nums : List<&2, Nat> <- wal_segnums_dir(wal_archive_dir() ++ "/" ++ wal_zpad4(y) ++ "/" ++ wal_zpad2(m))
    IO.pure(List<&2, Nat>, wal_list_append(acc, nums))

def wal_arch_segnums_months(+ms: List<&2, Nat>, +y: Nat, +acc: List<&2, Nat>) -> IO(List<&2, Nat>):
  match ms:
    case Nil{}: IO.pure(List<&2, Nat>, acc)
    case m <> t:
      do IO<List<&2, Nat>>:
        a2 : List<&2, Nat> <- wal_arch_segnums_month(y, m, acc)
        wal_arch_segnums_months(t, y, a2)

def wal_arch_segnums_year(+y: Nat, +acc: List<&2, Nat>) -> IO(List<&2, Nat>):
  do IO<List<&2, Nat>>:
    ms : List<&2, Nat> <- wal_dirnums(wal_archive_dir() ++ "/" ++ wal_zpad4(y))
    wal_arch_segnums_months(ms, y, acc)

def wal_arch_segnums_years(+ys: List<&2, Nat>, +acc: List<&2, Nat>) -> IO(List<&2, Nat>):
  match ys:
    case Nil{}: IO.pure(List<&2, Nat>, acc)
    case y <> t:
      do IO<List<&2, Nat>>:
        a2 : List<&2, Nat> <- wal_arch_segnums_year(y, acc)
        wal_arch_segnums_years(t, a2)

def wal_all_arch_segnums() -> IO(List<&2, Nat>):
  do IO<List<&2, Nat>>:
    ys : List<&2, Nat> <- wal_dirnums(wal_archive_dir())
    wal_arch_segnums_years(ys, Nil{})

def wal_has_seg0_go(+xs: List<&2, Nat>) -> Bool:
  match xs:
    case Nil{}: False{}
    case h <> t: Bool.or(Nat.is_eq(h, 0n), wal_has_seg0_go(t))

def wal_cover_ok_go(+xs: List<&2, Nat>) -> Bool:
  match xs:
    case Nil{}: True{}
    case _ <> _: wal_has_seg0_go(xs)

# A recorded purge with a missing/invalid snapshot is provably
# unrecoverable: the purged segments' only other copy was the snapshot.
# Otherwise fall back to the seg-0 heuristic (pre-tombstone purges, or a
# tombstone lost out-of-band): with segments present but seg-0 absent, the
# oldest retired records are unaccounted for.
def wal_cover_after_tombstone(tombstoned: Bool) -> IO(Bool):
  match tombstoned:
    case True{}: IO.pure(Bool, False{})
    case False{}:
      do IO<Bool>:
        +arch : List<&2, Nat> <- wal_all_arch_segnums()
        +act : List<&2, Nat> <- wal_segnums_dir(wal_active_dir())
        all : List<&2, Nat> = wal_list_append(arch, act)
        # Empty (fresh server) passes vacuously; otherwise seg-0 must exist.
        IO.pure(Bool, wal_cover_ok_go(all))

def wal_cover_ok() -> IO(Bool):
  do IO<Bool>:
    tombstoned : Bool <- wal_purge_log_has_entries()
    wal_cover_after_tombstone(tombstoned)

def snap_verify(+content: String, +expect_seq: Nat) -> Bool:
  Bool.and(snap_trailer_ok(content), Nat.is_eq(snap_seq_of(content), expect_seq))

# Segmented-WAL snapshot cycle (Round 3 item 14): instead of truncating the
# single bocht.wal, every active segment is archived (moved) into
# wal/archive/YYYY/MM/ AFTER the snapshot has been written, fsync'd and
# verified. The counter is bumped past the archived segment numbers first
# (inside wal_archive_covered), so a new segment number is never reused.
# The archive aborts (and retries after the next snapshot) if the counter
# bump fails or a destination name clash is detected - a crash mid-move
# therefore leaves each segment either active or archived, never deleted.
def snap_cycle_archived_go(is_zero: Bool, +moved: Nat) -> IO(Bool):
  match is_zero:
    case True{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: snapshot saved and verified, WAL archived (no active segments)\n")
        IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        _u : Unit <- IO.print("medium-fresh: snapshot saved and verified, WAL archived (" ++ Nat.show(moved) ++ " segment(s))\n")
        IO.pure(Bool, True{})

def snap_cycle_archived(+moved: Nat) -> IO(Bool):
  snap_cycle_archived_go(Nat.is_eq(moved, 0n), moved)

def snap_cycle_archived_st(+moved: Nat, +st: MedState) -> IO(MedState):
  do IO<MedState>:
    _b : Bool <- snap_cycle_archived(moved)
    IO.pure(MedState, st_with_snapseq(st, st_seq(st)))

def snap_cycle_trunc(ok: Bool, +st: MedState) -> IO(MedState):
  match ok:
    case False{}: IO.pure(MedState, st)
    case True{}:
      do IO<MedState>:
        # Item 196: persist the archive high-water mark BEFORE moving
        # segments (crash-safe: a high COVERED with segments still active
        # can only cause a safe false-positive defensive replay).
        _c : Bool <- wal_covered_write_nat(wal_state_max_seq(st))
        now_sec : Nat <- wal_now_sec()
        moved : Nat <- wal_archive_covered(now_sec)
        snap_cycle_archived_st(moved, st)

# --- revoked-key tombstone compaction (Round 3 item 15) ---
# Revocation marks keys in place (Map.set: no per-revoke growth) but a
# revoked key is a permanent tombstone — nothing ever reclaims it, so the
# keys map (and every snapshot serializing it) grows monotonically with
# creates. At snapshot time we reclaim: every revoked key is dropped from the
# live map, with one fsync'd KEYDEL WAL line per drop written BEFORE the
# snapshot. Crash windows:
# - crash after KEYDEL, before the snapshot validates: restart replays the
#   old snapshot (still lists the revoked keys) + the KEYDEL lines, which
#   drop them again. Revoked keys stay rejected either way (auth maps a
#   missing key to the same 401 as a revoked one), so this window is safe.
# - a KEYDEL write fails (disk full): compaction is skipped for this cycle
#   and retried at the next snapshot; the map keeps the revoked keys.
# Compaction is O(keys) per snapshot (every 500 seq) and writes zero WAL
# lines when nothing is revoked. The archived WAL keeps the full KEY/KEYDEL
# history, so the audit trail is preserved.

def key_compact_collect(+kvs: List<&2, Sigma<&2, &2, String, _ => Auth>>, +dropped: List<&2, String>) -> List<&2, String>:
  match kvs:
    case Nil{}: dropped
    case h <> t:
      (v, +a) = h
      key_compact_collect(t, Bool.pick(List<&2, String>, auth_revoked(a), v <> dropped, dropped))

def key_compact_wal_go(+vs: List<&2, String>) -> IO(Bool):
  match vs:
    case Nil{}: IO.pure(Bool, True{})
    case v <> t:
      do IO<Bool>:
        ok : Bool <- wal_keydel(v)
        rest : Bool <- key_compact_wal_go(t)
        IO.pure(Bool, Bool.and(ok, rest))

def key_compact_del_go(+kvs: List<&2, Sigma<&2, &2, String, _ => Auth>>, +m: Map<&2, Auth>) -> Map<&2, Auth>:
  match kvs:
    case Nil{}: m
    case h <> t:
      (v, +a) = h
      key_compact_del_go(t, Bool.pick(Map<&2, Auth>, auth_revoked(a), Map.del(&2, Auth, m, v), m))

def key_compact_pick(ok: Bool, +keys: Map<&2, Auth>) -> Map<&2, Auth>:
  match ok:
    case True{}: key_compact_del_go(Map.to_list(&2, Auth, keys), keys)
    case False{}: keys

def key_compact(+keys: Map<&2, Auth>) -> IO(Map<&2, Auth>):
  do IO<Map<&2, Auth>>:
    ok : Bool <- key_compact_wal_go(key_compact_collect(Map.to_list(&2, Auth, keys), Nil{}))
    IO.pure(Map<&2, Auth>, key_compact_pick(ok, keys))

def key_compact_st(+st: MedState) -> IO(MedState):
  do IO<MedState>:
    ckeys : Map<&2, Auth> <- key_compact(st_keys(st))
    IO.pure(MedState, st_with_keys(st, ckeys))

def snap_cycle_go(+st2: MedState) -> IO(MedState):
  do IO<MedState>:
    ok : Bool <- snapshot_save(st2)
    snap_cycle_trunc(ok, st2)

def snap_cycle(+st: MedState) -> IO(MedState):
  do IO<MedState>:
    st2 : MedState <- key_compact_st(st)
    snap_cycle_go(st2)

def snap_interval() -> Nat:
  500n

def snap_due(+st: MedState) -> Bool:
  Bool.and(Bool.not(Nat.is_eq(st_seq(st), 0n)),
    Bool.not(Nat.is_lt(st_seq(st), Nat.add(st_snapseq(st), snap_interval()))))

def maybe_snapshot_go(due: Bool, +st: MedState) -> IO(MedState):
  match due:
    case False{}: IO.pure(MedState, st)
    case True{}: snap_cycle(st)

def maybe_snapshot(+st: MedState) -> IO(MedState):
  maybe_snapshot_go(snap_due(st), st)

# med_evt.bend — fresh Medium service, part 7: typed commit events + subscribers.
# Every mutation emits MkEvt{seq, tenant, etype, payload}. The evlog is a
# bounded ring (1000 entries); the bounded-log helpers (evt_cap/evt_push/...)
# live in med_store.bend because WAL replay rebuilds the log on startup.
# Authenticated clients poll GET /v1/events?cursor=N for tenant-filtered
# replay; when no new events exist the socket parks as a MkPend until the
# next event or timeout.

def evt_head_opt(+log: List<&2, Evt>) -> Maybe<&1, Evt>:
  match log:
    case Nil{}: None{}
    case h <> _: Some{h}

def evt_emit_go(+st: MedState, +e: Evt) -> MedState:
  st_with_ev(st, evt_push(st_evlog(st), e), Nat.add(st_evseq(st), 1n))

def evt_emit(+st: MedState, +tenant: String, +etype: String, +payload: String) -> MedState:
  evt_emit_go(st, MkEvt{Nat.add(st_evseq(st), 1n), tenant, etype, payload})

def evt_to_json(+e: Evt) -> String:
  match e:
    case MkEvt{s, t, k, p}:
      "{\"seq\":" ++ Nat.show(s) ++ ",\"tenant\":\"" ++ json_esc(t) ++ "\",\"type\":\"" ++ json_esc(k) ++ "\",\"payload\":" ++ p ++ "}"

def evt_filter_cons(keep: Bool, +h: Evt, +acc: List<&2, String>) -> List<&2, String>:
  match keep:
    case True{}: evt_to_json(h) <> acc
    case False{}: acc

def evt_filter_go(+log: List<&2, Evt>, +tenant: String, +cursor: Nat, +acc: List<&2, String>) -> List<&2, String>:
  match log:
    case Nil{}: acc
    case h <> t:
      evt_filter_go(t, tenant, cursor, evt_filter_cons(Bool.and(Nat.is_lt(cursor, evt_seq(h)), String.eq(evt_tenant(h), tenant)), h, acc))

def evt_filter(+log: List<&2, Evt>, +tenant: String, +cursor: Nat) -> List<&2, String>:
  evt_filter_go(log, tenant, cursor, Nil{})

def evt_max_seq(+log: List<&2, Evt>, +cur: Nat) -> Nat:
  match log:
    case Nil{}: cur
    case h <> t: evt_max_seq(t, Nat.max(cur, evt_seq(h)))

# --- slow-poller truncation signal (Round 3 item 140) ---
# The evlog is a bounded 1000-entry ring; a client whose cursor predates the
# oldest buffered event has irrecoverably missed events. The poll response
# used to skip them silently and jump the cursor forward, making the loss
# undetectable. Poll responses (immediate and wakeup) now carry
# "truncated":true whenever the caller's cursor is older than the oldest
# buffered event, so slow pollers can re-sync (e.g. refetch state) instead
# of silently missing events. The flag is additive and only appears when
# the cursor is strictly older than the ring floor, so fresh cursors are
# unaffected.

def evt_oldest_seq_go(+log: List<&2, Evt>, +acc: Nat) -> Nat:
  match log:
    case Nil{}: acc
    case h <> t: evt_oldest_seq_go(t, evt_seq(h))

def evt_oldest_seq(+log: List<&2, Evt>) -> Nat:
  evt_oldest_seq_go(log, 0n)

def evt_trunc_flag(+log: List<&2, Evt>, +cursor: Nat) -> String:
  Bool.pick(String, Nat.is_lt(cursor, evt_oldest_seq(log)), ",\"truncated\":true", "")

# --- subscribers ---

def pend_add(+st: MedState, +sub: PendSub) -> MedState:
  st_with_pend(st, sub <> st_pend(st))

def pend_expire_cons(expired: Bool, +h: PendSub, +acc: List<&2, PendSub>) -> List<&2, PendSub>:
  match expired:
    case True{}: acc
    case False{}: h <> acc

def pend_expire_collect(+subs: List<&2, PendSub>, +now: Nat, +keep: List<&2, PendSub>, +expired: List<&2, PendSub>) -> List<&2, PendSub> & List<&2, PendSub>:
  match subs:
    case Nil{}: (keep, expired)
    case h <> t:
      pend_expire_collect(t, now,
        Bool.pick(List<&2, PendSub>, Nat.is_lt(Nat.add(pend_born(h), Nat.mul(250n, 100n)), now), keep, h <> keep),
        Bool.pick(List<&2, PendSub>, Nat.is_lt(Nat.add(pend_born(h), Nat.mul(250n, 100n)), now), h <> expired, expired))

def pend_len(+subs: List<&2, PendSub>) -> Nat:
  match subs:
    case Nil{}: 0n
    case _ <> t: Nat.add(1n, pend_len(t))

def pend_cap() -> Nat:
  100n

# Round 3 item 177: per-tenant parked-subscription cap. Any single tenant may
# hold at most 25 parked subs; the global 100-slot ceiling (pend_cap) remains
# as a backstop. This contains a FIN-park wedge (item 173) to the offending
# tenant: one tenant's burn can no longer wedge every other tenant's event
# feed until the 25s lazy sweep.
def pend_cap_tenant() -> Nat:
  25n

def pend_expire_keep_go(ke: List<&2, PendSub> & List<&2, PendSub>) -> List<&2, PendSub>:
  match ke:
    case (keep, _expired): keep

def pend_expire_keep(+st: MedState, +now: Nat) -> List<&2, PendSub>:
  pend_expire_keep_go(pend_expire_collect(st_pend(st), now, Nil{}, Nil{}))

def pend_expire(+st: MedState, +now: Nat) -> MedState:
  st_with_pend(st, pend_expire_keep(st, now))

def pend_for_tenant_cons(mine: Bool, +h: PendSub, +acc: List<&2, PendSub>) -> List<&2, PendSub>:
  match mine:
    case True{}: h <> acc
    case False{}: acc

def pend_for_tenant_go(+subs: List<&2, PendSub>, +tenant: String, +acc: List<&2, PendSub>) -> List<&2, PendSub>:
  match subs:
    case Nil{}: acc
    case h <> t:
      pend_for_tenant_go(t, tenant, pend_for_tenant_cons(String.eq(pend_tenant(h), tenant), h, acc))

def pend_for_tenant(+subs: List<&2, PendSub>, +tenant: String) -> List<&2, PendSub>:
  pend_for_tenant_go(subs, tenant, Nil{})

def pend_without_tenant_cons(mine: Bool, +h: PendSub, +acc: List<&2, PendSub>) -> List<&2, PendSub>:
  match mine:
    case True{}: acc
    case False{}: h <> acc

def pend_without_tenant_go(+subs: List<&2, PendSub>, +tenant: String, +acc: List<&2, PendSub>) -> List<&2, PendSub>:
  match subs:
    case Nil{}: acc
    case h <> t:
      pend_without_tenant_go(t, tenant, pend_without_tenant_cons(String.eq(pend_tenant(h), tenant), h, acc))

def pend_without_tenant(+subs: List<&2, PendSub>, +tenant: String) -> List<&2, PendSub>:
  pend_without_tenant_go(subs, tenant, Nil{})

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
        lr : Result<&1, &1, U32 & String, Listener> <- TCP.listen(18081)
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

