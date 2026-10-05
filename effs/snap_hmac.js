// FS.hmac_sha256_hex — JS backend stub.
//
// Best-effort pure-JS HMAC-SHA256 (FIPS 180-4 + RFC 2104), so snapshot
// trailers written under `bend run` carry a valid, verifiable MAC just
// like the native backend (see snap_hmac.c). The campaign builds and
// tests the native binary exclusively.

function fs_hmac_sha256_hex(key, msg) {
  var K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ];
  function rotr(x, n) { return (x >>> n) | (x << (32 - n)); }
  function sha256Bytes(bytes) {
    var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
    var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
    var l = bytes.length;
    var bitLenHi = Math.floor((l * 8) / 4294967296);
    var bitLenLo = (l * 8) >>> 0;
    var padded = bytes.slice();
    padded.push(0x80);
    while ((padded.length % 64) !== 56) padded.push(0x00);
    padded.push((bitLenHi >>> 24) & 0xff, (bitLenHi >>> 16) & 0xff,
                (bitLenHi >>> 8) & 0xff, bitLenHi & 0xff,
                (bitLenLo >>> 24) & 0xff, (bitLenLo >>> 16) & 0xff,
                (bitLenLo >>> 8) & 0xff, bitLenLo & 0xff);
    var w = new Array(64);
    for (var b = 0; b < padded.length; b += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = ((padded[b + 4 * i] << 24) | (padded[b + 4 * i + 1] << 16) |
                (padded[b + 4 * i + 2] << 8) | padded[b + 4 * i + 3]) >>> 0;
      }
      for (i = 16; i < 64; i++) {
        var s0 = (rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3)) >>> 0;
        var s1 = (rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10)) >>> 0;
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
      }
      var a = h0, bb = h1, cc = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
      for (i = 0; i < 64; i++) {
        var S1 = (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) >>> 0;
        var ch = ((e & f) ^ (~e & g)) >>> 0;
        var t1 = (h + S1 + ch + K[i] + w[i]) >>> 0;
        var S0 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) >>> 0;
        var mj = ((a & bb) ^ (a & cc) ^ (bb & cc)) >>> 0;
        var t2 = (S0 + mj) >>> 0;
        h = g; g = f; f = e; e = (d + t1) >>> 0;
        d = cc; cc = bb; bb = a; a = (t1 + t2) >>> 0;
      }
      h0 = (h0 + a) >>> 0; h1 = (h1 + bb) >>> 0;
      h2 = (h2 + cc) >>> 0; h3 = (h3 + d) >>> 0;
      h4 = (h4 + e) >>> 0; h5 = (h5 + f) >>> 0;
      h6 = (h6 + g) >>> 0; h7 = (h7 + h) >>> 0;
    }
    var out = [];
    [h0, h1, h2, h3, h4, h5, h6, h7].forEach(function (hh) {
      out.push((hh >>> 24) & 0xff, (hh >>> 16) & 0xff, (hh >>> 8) & 0xff, hh & 0xff);
    });
    return out;
  }
  function utf8(s) {
    // Snapshot bodies and keys are ASCII by construction; encode as
    // UTF-8 for generality.
    var out = [];
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
      else out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    }
    return out;
  }
  function hmac(keyBytes, msgBytes) {
    var kb = keyBytes.length > 64 ? sha256Bytes(keyBytes) : keyBytes.slice();
    while (kb.length < 64) kb.push(0x00);
    var ipad = [], opad = [];
    for (var i = 0; i < 64; i++) {
      ipad.push(kb[i] ^ 0x36);
      opad.push(kb[i] ^ 0x5c);
    }
    var inner = sha256Bytes(ipad.concat(msgBytes));
    return sha256Bytes(opad.concat(inner));
  }
  var digest = hmac(utf8(String(key)), utf8(String(msg)));
  return digest.map(function (b) {
    return (b < 16 ? "0" : "") + b.toString(16);
  }).join("");
}
