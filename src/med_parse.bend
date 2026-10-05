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
