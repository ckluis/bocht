# med_test.bend — focused unit tests for fresh Medium service.
# Tests pure functions using REAL names from the modules.
#
# Every assert returns IO(Nat): the number of failures (0 or 1).
# main() sums all failures, prints the total, and calls IO.die(1, ...)
# when the total is nonzero, so a failing run exits nonzero.

# --- assert helpers (each answers with 0 or 1 failures) ---

def assert_eq_str_go(eq: Bool, +name: String, +got: String, +want: String) -> IO(Nat):
  match eq:
    case True{}:
      do IO<Nat>:
        _u : Unit <- IO.print("PASS " ++ name ++ "\n")
        IO.pure(Nat, 0n)
    case False{}:
      do IO<Nat>:
        _u : Unit <- IO.print("FAIL " ++ name ++ ": got [" ++ got ++ "] want [" ++ want ++ "]\n")
        IO.pure(Nat, 1n)

def assert_eq_str(+name: String, +got: String, +want: String) -> IO(Nat):
  assert_eq_str_go(String.eq(got, want), name, got, want)

def assert_true(+name: String, +cond: Bool) -> IO(Nat):
  match cond:
    case True{}:
      do IO<Nat>:
        _u : Unit <- IO.print("PASS " ++ name ++ "\n")
        IO.pure(Nat, 0n)
    case False{}:
      do IO<Nat>:
        _u : Unit <- IO.print("FAIL " ++ name ++ "\n")
        IO.pure(Nat, 1n)

def assert_false(+name: String, +cond: Bool) -> IO(Nat):
  match cond:
    case True{}:
      do IO<Nat>:
        _u : Unit <- IO.print("FAIL " ++ name ++ "\n")
        IO.pure(Nat, 1n)
    case False{}:
      do IO<Nat>:
        _u : Unit <- IO.print("PASS " ++ name ++ "\n")
        IO.pure(Nat, 0n)

# --- pure helpers (do-block binds get each value exactly once) ---

def nat_sum4(a: Nat, b: Nat, c: Nat, d: Nat) -> Nat:
  Nat.add(Nat.add(a, b), Nat.add(c, d))

def nat_sum6(a: Nat, b: Nat, c: Nat, d: Nat, e: Nat, f: Nat) -> Nat:
  Nat.add(nat_sum4(a, b, c, d), Nat.add(e, f))

def nat_sum7(a: Nat, b: Nat, c: Nat, d: Nat, e: Nat, f: Nat, g: Nat) -> Nat:
  Nat.add(nat_sum6(a, b, c, d, e, f), g)

def fail_msg(tot: Nat) -> String:
  "med_test: " ++ Nat.show(tot) ++ " failure(s)"

def finish_or_die(tot: Nat) -> IO(Unit):
  match tot:
    case 0n: IO.pure(Unit, Unit{})
    case 1n+rest:
      do IO<Unit>:
        +msg : String = fail_msg(Nat.add(1n, rest))
        _u : Unit <- IO.print(msg ++ "\n")
        IO.die(Unit, 1, msg)

def report_and_die(+tot: Nat) -> IO(Unit):
  do IO<Unit>:
    _u : Unit <- IO.print("=== med_test: done, failures: " ++ Nat.show(tot) ++ " ===\n")
    _d : Unit <- finish_or_die(tot)
    IO.pure(Unit, Unit{})

# --- auth verifier strictness (uses auth_is_verifier) ---

def test_verifier_strict() -> IO(Nat):
  do IO<Nat>:
    +v64 : String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    f1 : Nat <- assert_true("verifier_valid", auth_is_verifier("v1$" ++ v64))
    f2 : Nat <- assert_false("verifier_short", auth_is_verifier("v1$abc"))
    f3 : Nat <- assert_false("verifier_uppercase", auth_is_verifier("v1$0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef"))
    f4 : Nat <- assert_false("verifier_no_prefix", auth_is_verifier(v64))
    f5 : Nat <- assert_false("verifier_wrong_prefix", auth_is_verifier("v2$" ++ v64))
    f6 : Nat <- assert_false("verifier_63hex", auth_is_verifier("v1$0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde"))
    f7 : Nat <- assert_false("verifier_65hex", auth_is_verifier("v1$" ++ v64 ++ "0"))
    IO.pure(Nat, nat_sum7(f1, f2, f3, f4, f5, f6, f7))

def test_verifier_of() -> IO(Nat):
  do IO<Nat>:
    +v : String = verifier_of("mysecret123")
    f1 : Nat <- assert_true("verifier_of_shape", auth_is_verifier(v))
    # The verifier itself is not a valid raw secret input (it starts with v1$)
    f2 : Nat <- assert_true("verifier_starts_v1", String.starts_with(v, "v1$"))
    IO.pure(Nat, Nat.add(f1, f2))

# --- SHA-256 vectors (uses sha256_hex) ---

def test_sha_vectors() -> IO(Nat):
  do IO<Nat>:
    f1 : Nat <- assert_eq_str("sha_empty", sha256_hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    f2 : Nat <- assert_eq_str("sha_abc", sha256_hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    IO.pure(Nat, Nat.add(f1, f2))

# --- request line parsing (uses parse_req_line) ---

def test_req_line_hr(+hr: HeadRes) -> IO(Nat):
  match hr:
    case MkHr{method, path}:
      do IO<Nat>:
        f1 : Nat <- assert_eq_str("req_method", method, "GET")
        f2 : Nat <- assert_eq_str("req_path", path, "/v1/users/123")
        IO.pure(Nat, Nat.add(f1, f2))

def test_req_line_mhr(mhr: Maybe<&1, HeadRes>) -> IO(Nat):
  match mhr:
    case None{}:
      do IO<Nat>:
        _u : Unit <- IO.print("FAIL request_line_parse_none\n")
        IO.pure(Nat, 1n)
    case Some{hr}: test_req_line_hr(hr)

def test_req_line_bad(mhr: Maybe<&1, HeadRes>) -> IO(Nat):
  match mhr:
    case None{}:
      do IO<Nat>:
        _u : Unit <- IO.print("PASS request_line_bad_reject\n")
        IO.pure(Nat, 0n)
    case Some{_}:
      do IO<Nat>:
        _u : Unit <- IO.print("FAIL request_line_bad_reject\n")
        IO.pure(Nat, 1n)

def test_request_line() -> IO(Nat):
  do IO<Nat>:
    f1 : Nat <- test_req_line_mhr(parse_req_line("GET /v1/users/123 HTTP/1.1"))
    f2 : Nat <- test_req_line_bad(parse_req_line("BADLINE"))
    IO.pure(Nat, Nat.add(f1, f2))

# --- json_esc regression (escape order + linear time) ---

def test_esc_field(mf: Maybe<&1, String>, +name: String, +want: String) -> IO(Nat):
  match mf:
    case None{}:
      do IO<Nat>:
        _u : Unit <- IO.print("FAIL " ++ name ++ ": got NONE want [" ++ want ++ "]\n")
        IO.pure(Nat, 1n)
    case Some{got}: assert_eq_str(name, got, want)

def test_json_esc() -> IO(Nat):
  do IO<Nat>:
    f1 : Nat <- assert_eq_str("esc_quote", json_esc("he\"llo"), "he\\\"llo")
    f2 : Nat <- assert_eq_str("esc_bs", json_esc("a\\b"), "a\\\\b")
    f3 : Nat <- assert_eq_str("esc_nl", json_esc("a\nb"), "a\\nb")
    f4 : Nat <- assert_eq_str("esc_plain", json_esc("plain"), "plain")
    f5 : Nat <- assert_eq_str("esc_mix", json_esc("x\"y\\z"), "x\\\"y\\\\z")
    f6 : Nat <- test_esc_field(jf_field("{\"tenant\":\"acme\",\"role\":\"member\"}", "tenant"), "jf_tenant", "acme")
    f7 : Nat <- test_esc_field(jf_field("{\"tenant\":\"acme\",\"role\":\"member\"}", "role"), "jf_role", "member")
    f8 : Nat <- test_esc_field(jf_field("{\"a\":\"x\\\"y\"}", "a"), "jf_escquote", "x\"y")
    f9 : Nat <- test_esc_field(jf_field("{\"a\":\"x\\\\y\"}", "a"), "jf_escbs", "x\\y")
    IO.pure(Nat, nat_sum4(nat_sum4(f1, f2, f3, f4), nat_sum4(f5, f6, f7, f8), f9, 0n))

# --- main ---

def test_title_valid() -> IO(Nat):
  do IO<Nat>:
    f1 : Nat <- assert_true("title_spaces", valid_title("Hello World: A Story!"))
    f2 : Nat <- assert_true("title_punct", valid_title("What? Yes — 100% (v2.0)"))
    f3 : Nat <- assert_true("title_tab_reject", Bool.not(valid_title("a\tb")))
    f4 : Nat <- assert_true("title_nl_reject", Bool.not(valid_title("a\nb")))
    f5 : Nat <- assert_true("title_empty_reject", Bool.not(valid_title("")))
    f6 : Nat <- assert_eq_str("esc_tab", json_esc("a\tb"), "a\\tb")
    f7 : Nat <- assert_eq_str("esc_cr", json_esc("a\rb"), "a\\rb")
    IO.pure(Nat, nat_sum4(nat_sum4(f1, f2, f3, f4), nat_sum4(f5, f6, f7, 0n), 0n, 0n))

def main() -> IO(Unit):
  do IO<Unit>:
    _u1 : Unit <- IO.print("=== med_test: auth verifier ===\n")
    f1 : Nat <- test_verifier_strict()
    f2 : Nat <- test_verifier_of()
    _u4 : Unit <- IO.print("=== med_test: sha ===\n")
    f3 : Nat <- test_sha_vectors()
    _u6 : Unit <- IO.print("=== med_test: parser ===\n")
    f4 : Nat <- test_request_line()
    _u8 : Unit <- IO.print("=== med_test: json esc/field ===\n")
    f5 : Nat <- test_json_esc()
    _u9 : Unit <- IO.print("=== med_test: title validation ===\n")
    f6 : Nat <- test_title_valid()
    _u7 : Unit <- report_and_die(nat_sum6(f1, f2, f3, f4, f5, f6))
    IO.pure(Unit, Unit{})
