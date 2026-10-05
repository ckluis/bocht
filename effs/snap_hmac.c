// FS.hmac_sha256_hex — HMAC-SHA256(key, msg), lowercase hex.
//
// Round 3 item 197 (T7 residual): the snapshot trailer carries
//   SEQ\t<seq>\t<count>\t<mac>
// where mac = HMAC-SHA256(key, body ++ "SEQ\t" ++ seq ++ "\t" ++ count)
// and key comes from MEDIUM_SNAPSHOT_HMAC_KEY (out-of-band env, never the
// waldir). A pure-Bend HMAC was measured at ~2 KiB/s native (a 128 KiB
// single pass took >65 s) — infeasible for boot-time verification of
// multi-MiB snapshots; this effect runs at GB/s.
//
// Self-contained FIPS 180-4 SHA-256 + RFC 2104 HMAC (key > 64 bytes is
// hashed first; key is zero-padded to the 64-byte block; ipad 0x36,
// opad 0x5c). Returns exactly 64 lowercase hex chars. Follows the
// walfs_mtime.c effect pattern.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static uint32_t sh_rotr(uint32_t x, unsigned n) {
  return (x >> n) | (x << (32 - n));
}

static const uint32_t sh_k[64] = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

typedef struct {
  uint32_t h[8];
  uint64_t len;
  uint8_t buf[64];
  size_t buflen;
} sh_ctx;

static void sh_init(sh_ctx *c) {
  c->h[0] = 0x6a09e667; c->h[1] = 0xbb67ae85;
  c->h[2] = 0x3c6ef372; c->h[3] = 0xa54ff53a;
  c->h[4] = 0x510e527f; c->h[5] = 0x9b05688c;
  c->h[6] = 0x1f83d9ab; c->h[7] = 0x5be0cd19;
  c->len = 0;
  c->buflen = 0;
}

static void sh_block(sh_ctx *c, const uint8_t *p) {
  uint32_t w[64];
  for (int i = 0; i < 16; i++) {
    w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) |
           ((uint32_t)p[4 * i + 2] << 8) | (uint32_t)p[4 * i + 3];
  }
  for (int i = 16; i < 64; i++) {
    uint32_t s0 = sh_rotr(w[i - 15], 7) ^ sh_rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 = sh_rotr(w[i - 2], 17) ^ sh_rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = c->h[0], b = c->h[1], cc = c->h[2], d = c->h[3];
  uint32_t e = c->h[4], f = c->h[5], g = c->h[6], h = c->h[7];
  for (int i = 0; i < 64; i++) {
    uint32_t S1 = sh_rotr(e, 6) ^ sh_rotr(e, 11) ^ sh_rotr(e, 25);
    uint32_t ch = (e & f) ^ (~e & g);
    uint32_t t1 = h + S1 + ch + sh_k[i] + w[i];
    uint32_t S0 = sh_rotr(a, 2) ^ sh_rotr(a, 13) ^ sh_rotr(a, 22);
    uint32_t mj = (a & b) ^ (a & cc) ^ (b & cc);
    uint32_t t2 = S0 + mj;
    h = g; g = f; f = e; e = d + t1; d = cc; cc = b; b = a; a = t1 + t2;
  }
  c->h[0] += a; c->h[1] += b; c->h[2] += cc; c->h[3] += d;
  c->h[4] += e; c->h[5] += f; c->h[6] += g; c->h[7] += h;
}

static void sh_update(sh_ctx *c, const uint8_t *p, size_t n) {
  c->len += n;
  while (n > 0) {
    size_t take = 64 - c->buflen;
    if (take > n) take = n;
    memcpy(c->buf + c->buflen, p, take);
    c->buflen += take;
    p += take;
    n -= take;
    if (c->buflen == 64) {
      sh_block(c, c->buf);
      c->buflen = 0;
    }
  }
}

static void sh_final(sh_ctx *c, uint8_t out[32]) {
  uint64_t bits = c->len * 8;
  uint8_t pad = 0x80;
  sh_update(c, &pad, 1);
  uint8_t z = 0;
  while (c->buflen != 56) sh_update(c, &z, 1);
  uint8_t lb[8];
  for (int i = 0; i < 8; i++) lb[i] = (uint8_t)(bits >> (56 - 8 * i));
  sh_update(c, lb, 8);
  for (int i = 0; i < 8; i++) {
    out[4 * i]     = (uint8_t)(c->h[i] >> 24);
    out[4 * i + 1] = (uint8_t)(c->h[i] >> 16);
    out[4 * i + 2] = (uint8_t)(c->h[i] >> 8);
    out[4 * i + 3] = (uint8_t)(c->h[i]);
  }
}

static void sh_once(const uint8_t *p, size_t n, uint8_t out[32]) {
  sh_ctx c;
  sh_init(&c);
  sh_update(&c, p, n);
  sh_final(&c, out);
}

static void hmac_sha256(const uint8_t *key, size_t klen,
                        const uint8_t *msg, size_t mlen,
                        uint8_t out[32]) {
  uint8_t kb[64];
  if (klen > 64) {
    sh_once(key, klen, kb);
    memset(kb + 32, 0, 32);
  } else {
    memcpy(kb, key, klen);
    memset(kb + klen, 0, 64 - klen);
  }
  uint8_t ipad[64], opad[64];
  for (int i = 0; i < 64; i++) {
    ipad[i] = kb[i] ^ 0x36;
    opad[i] = kb[i] ^ 0x5c;
  }
  sh_ctx c;
  uint8_t inner[32];
  sh_init(&c);
  sh_update(&c, ipad, 64);
  sh_update(&c, msg, mlen);
  sh_final(&c, inner);
  sh_init(&c);
  sh_update(&c, opad, 64);
  sh_update(&c, inner, 32);
  sh_final(&c, out);
  memset(kb, 0, sizeof kb);
  memset(ipad, 0, sizeof ipad);
  memset(opad, 0, sizeof opad);
  memset(inner, 0, sizeof inner);
}

Term fs_hmac_sha256_hex_run(Env e, Term* f, IoWork* w) {
  size_t klen = 0, mlen = 0;
  char *key = io_cstr(e, f[0], &klen);
  char *msg = io_cstr(e, f[1], &mlen);
  uint8_t digest[32];
  hmac_sha256((const uint8_t *)key, klen, (const uint8_t *)msg, mlen, digest);
  free(key);
  free(msg);
  char hex[65];
  static const char hd[] = "0123456789abcdef";
  for (int i = 0; i < 32; i++) {
    hex[2 * i] = hd[digest[i] >> 4];
    hex[2 * i + 1] = hd[digest[i] & 15];
  }
  hex[64] = '\0';
  memset(digest, 0, sizeof digest);
  (void)w;
  return io_str(e, hex, 64);
}

static void __attribute__((constructor)) fs_hmac_sha256_hex_use(void) {
  io_eff(CID_FS_HMAC_SHA256_HEX, fs_hmac_sha256_hex_run, 0);
}
