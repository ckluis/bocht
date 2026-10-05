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
