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
