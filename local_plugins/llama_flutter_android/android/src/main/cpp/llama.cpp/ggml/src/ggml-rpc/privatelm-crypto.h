// PrivateLM patch: the crypto the phone cluster needs, with no dependency
// (Android's NDK has no OpenSSL): X25519 key agreement (RFC 7748) and the
// ChaCha20-Poly1305 AEAD (RFC 8439). Plain portable C++, checked against
// the RFC test vectors in scripts/rpc_pairing_test.cpp.
//
// X25519 follows TweetNaCl (public domain); Poly1305 follows
// poly1305-donna's 32-bit version (public domain).
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace privatelm_crypto {

// ── helpers ─────────────────────────────────────────────────────────────

inline uint32_t load32(const uint8_t * p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

inline void store32(uint8_t * p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

inline void store64(uint8_t * p, uint64_t v) {
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}

/// Constant-time comparison.
inline bool equal(const uint8_t * a, const uint8_t * b, size_t n) {
    uint8_t diff = 0;
    for (size_t i = 0; i < n; i++) diff |= a[i] ^ b[i];
    return diff == 0;
}

inline void wipe(void * p, size_t n) {
    volatile uint8_t * v = (volatile uint8_t *)p;
    while (n--) *v++ = 0;
}

// ── ChaCha20 (RFC 8439 §2.3–2.4) ────────────────────────────────────────

inline uint32_t rotl(uint32_t v, int c) { return (v << c) | (v >> (32 - c)); }

#define PLM_QR(a, b, c, d)                       \
    a += b; d ^= a; d = rotl(d, 16);             \
    c += d; b ^= c; b = rotl(b, 12);             \
    a += b; d ^= a; d = rotl(d, 8);              \
    c += d; b ^= c; b = rotl(b, 7);

inline void chacha20_block(const uint8_t key[32], uint32_t counter, const uint8_t nonce[12],
                           uint8_t out[64]) {
    uint32_t s[16] = {0x61707865, 0x3320646e, 0x79622d32, 0x6b206574};
    for (int i = 0; i < 8; i++) s[4 + i] = load32(key + 4 * i);
    s[12] = counter;
    for (int i = 0; i < 3; i++) s[13 + i] = load32(nonce + 4 * i);
    uint32_t x[16];
    std::memcpy(x, s, sizeof(x));
    for (int i = 0; i < 10; i++) {
        PLM_QR(x[0], x[4], x[8], x[12]) PLM_QR(x[1], x[5], x[9], x[13])
        PLM_QR(x[2], x[6], x[10], x[14]) PLM_QR(x[3], x[7], x[11], x[15])
        PLM_QR(x[0], x[5], x[10], x[15]) PLM_QR(x[1], x[6], x[11], x[12])
        PLM_QR(x[2], x[7], x[8], x[13]) PLM_QR(x[3], x[4], x[9], x[14])
    }
    for (int i = 0; i < 16; i++) store32(out + 4 * i, x[i] + s[i]);
}

#undef PLM_QR

/// XORs [data] with the ChaCha20 key stream starting at block [counter].
inline void chacha20_xor(const uint8_t key[32], uint32_t counter, const uint8_t nonce[12],
                         uint8_t * data, size_t n) {
    uint8_t block[64];
    while (n > 0) {
        chacha20_block(key, counter++, nonce, block);
        const size_t take = n < 64 ? n : 64;
        for (size_t i = 0; i < take; i++) data[i] ^= block[i];
        data += take;
        n -= take;
    }
    wipe(block, sizeof(block));
}

// ── Poly1305 (RFC 8439 §2.5) ────────────────────────────────────────────

struct poly1305 {
    uint32_t r[5], h[5] = {0, 0, 0, 0, 0}, pad[4];
    uint8_t buf[16];
    size_t left = 0;

    explicit poly1305(const uint8_t key[32]) {
        r[0] = load32(key + 0) & 0x3ffffff;
        r[1] = (load32(key + 3) >> 2) & 0x3ffff03;
        r[2] = (load32(key + 6) >> 4) & 0x3ffc0ff;
        r[3] = (load32(key + 9) >> 6) & 0x3f03fff;
        r[4] = (load32(key + 12) >> 8) & 0x00fffff;
        for (int i = 0; i < 4; i++) pad[i] = load32(key + 16 + 4 * i);
    }

    void blocks(const uint8_t * m, size_t bytes, uint32_t hibit) {
        const uint32_t r0 = r[0], r1 = r[1], r2 = r[2], r3 = r[3], r4 = r[4];
        const uint32_t s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;
        uint32_t h0 = h[0], h1 = h[1], h2 = h[2], h3 = h[3], h4 = h[4];
        while (bytes >= 16) {
            h0 += load32(m + 0) & 0x3ffffff;
            h1 += (load32(m + 3) >> 2) & 0x3ffffff;
            h2 += (load32(m + 6) >> 4) & 0x3ffffff;
            h3 += (load32(m + 9) >> 6);
            h4 += (load32(m + 12) >> 8) | hibit;

            uint64_t d0 = (uint64_t)h0 * r0 + (uint64_t)h1 * s4 + (uint64_t)h2 * s3 + (uint64_t)h3 * s2 + (uint64_t)h4 * s1;
            uint64_t d1 = (uint64_t)h0 * r1 + (uint64_t)h1 * r0 + (uint64_t)h2 * s4 + (uint64_t)h3 * s3 + (uint64_t)h4 * s2;
            uint64_t d2 = (uint64_t)h0 * r2 + (uint64_t)h1 * r1 + (uint64_t)h2 * r0 + (uint64_t)h3 * s4 + (uint64_t)h4 * s3;
            uint64_t d3 = (uint64_t)h0 * r3 + (uint64_t)h1 * r2 + (uint64_t)h2 * r1 + (uint64_t)h3 * r0 + (uint64_t)h4 * s4;
            uint64_t d4 = (uint64_t)h0 * r4 + (uint64_t)h1 * r3 + (uint64_t)h2 * r2 + (uint64_t)h3 * r1 + (uint64_t)h4 * r0;

            uint32_t c = (uint32_t)(d0 >> 26); h0 = (uint32_t)d0 & 0x3ffffff;
            d1 += c; c = (uint32_t)(d1 >> 26); h1 = (uint32_t)d1 & 0x3ffffff;
            d2 += c; c = (uint32_t)(d2 >> 26); h2 = (uint32_t)d2 & 0x3ffffff;
            d3 += c; c = (uint32_t)(d3 >> 26); h3 = (uint32_t)d3 & 0x3ffffff;
            d4 += c; c = (uint32_t)(d4 >> 26); h4 = (uint32_t)d4 & 0x3ffffff;
            h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
            h1 += c;

            m += 16;
            bytes -= 16;
        }
        h[0] = h0; h[1] = h1; h[2] = h2; h[3] = h3; h[4] = h4;
    }

    void update(const uint8_t * m, size_t bytes) {
        if (bytes == 0) return;
        if (left) {
            size_t want = 16 - left;
            if (want > bytes) want = bytes;
            std::memcpy(buf + left, m, want);
            left += want; m += want; bytes -= want;
            if (left < 16) return;
            blocks(buf, 16, 1u << 24);
            left = 0;
        }
        const size_t whole = bytes & ~(size_t)15;
        if (whole) { blocks(m, whole, 1u << 24); m += whole; bytes -= whole; }
        if (bytes) { std::memcpy(buf, m, bytes); left = bytes; }
    }

    void finish(uint8_t mac[16]) {
        if (left) {
            buf[left++] = 1;
            while (left < 16) buf[left++] = 0;
            blocks(buf, 16, 0);
        }
        uint32_t h0 = h[0], h1 = h[1], h2 = h[2], h3 = h[3], h4 = h[4];
        uint32_t c = h1 >> 26; h1 &= 0x3ffffff;
        h2 += c; c = h2 >> 26; h2 &= 0x3ffffff;
        h3 += c; c = h3 >> 26; h3 &= 0x3ffffff;
        h4 += c; c = h4 >> 26; h4 &= 0x3ffffff;
        h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
        h1 += c;

        uint32_t g0 = h0 + 5; c = g0 >> 26; g0 &= 0x3ffffff;
        uint32_t g1 = h1 + c; c = g1 >> 26; g1 &= 0x3ffffff;
        uint32_t g2 = h2 + c; c = g2 >> 26; g2 &= 0x3ffffff;
        uint32_t g3 = h3 + c; c = g3 >> 26; g3 &= 0x3ffffff;
        uint32_t g4 = h4 + c - (1u << 26);

        uint32_t mask = (g4 >> 31) - 1;  // all ones when h >= p
        g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask;
        mask = ~mask;
        h0 = (h0 & mask) | g0; h1 = (h1 & mask) | g1; h2 = (h2 & mask) | g2;
        h3 = (h3 & mask) | g3; h4 = (h4 & mask) | g4;

        h0 = h0 | (h1 << 26);
        h1 = (h1 >> 6) | (h2 << 20);
        h2 = (h2 >> 12) | (h3 << 14);
        h3 = (h3 >> 18) | (h4 << 8);

        uint64_t f = (uint64_t)h0 + pad[0]; h0 = (uint32_t)f;
        f = (uint64_t)h1 + pad[1] + (f >> 32); h1 = (uint32_t)f;
        f = (uint64_t)h2 + pad[2] + (f >> 32); h2 = (uint32_t)f;
        f = (uint64_t)h3 + pad[3] + (f >> 32); h3 = (uint32_t)f;
        store32(mac + 0, h0); store32(mac + 4, h1); store32(mac + 8, h2); store32(mac + 12, h3);
        wipe(this, sizeof(*this));
    }
};

// ── ChaCha20-Poly1305 AEAD (RFC 8439 §2.8) ──────────────────────────────

static constexpr size_t kTagSize = 16;

inline void aead_tag(const uint8_t key[32], const uint8_t nonce[12], const uint8_t * aad, size_t aad_len,
                     const uint8_t * ct, size_t ct_len, uint8_t tag[16]) {
    uint8_t block[64];
    chacha20_block(key, 0, nonce, block);
    poly1305 mac(block);
    wipe(block, sizeof(block));
    static const uint8_t zeros[16] = {};
    mac.update(aad, aad_len);
    if (aad_len % 16) mac.update(zeros, 16 - aad_len % 16);
    mac.update(ct, ct_len);
    if (ct_len % 16) mac.update(zeros, 16 - ct_len % 16);
    uint8_t lens[16];
    store64(lens, aad_len);
    store64(lens + 8, ct_len);
    mac.update(lens, 16);
    mac.finish(tag);
}

/// Encrypts [data] in place and writes its tag.
inline void aead_seal(const uint8_t key[32], const uint8_t nonce[12], const uint8_t * aad, size_t aad_len,
                      uint8_t * data, size_t n, uint8_t tag[16]) {
    chacha20_xor(key, 1, nonce, data, n);
    aead_tag(key, nonce, aad, aad_len, data, n, tag);
}

/// Checks the tag, then decrypts [data] in place. False (data untouched)
/// when the record was altered.
inline bool aead_open(const uint8_t key[32], const uint8_t nonce[12], const uint8_t * aad, size_t aad_len,
                      uint8_t * data, size_t n, const uint8_t tag[16]) {
    uint8_t expected[16];
    aead_tag(key, nonce, aad, aad_len, data, n, expected);
    if (!equal(expected, tag, 16)) return false;
    chacha20_xor(key, 1, nonce, data, n);
    return true;
}

// ── X25519 (RFC 7748), after TweetNaCl ──────────────────────────────────

typedef int64_t gf[16];

inline void car25519(gf o) {
    for (int i = 0; i < 16; i++) {
        o[i] += (int64_t)1 << 16;
        const int64_t c = o[i] >> 16;
        o[(i + 1) * (i < 15)] += c - 1 + 37 * (c - 1) * (i == 15);
        o[i] -= c * 65536;
    }
}

inline void sel25519(gf p, gf q, int b) {
    const int64_t c = ~(int64_t)(b - 1);
    for (int i = 0; i < 16; i++) {
        const int64_t t = c & (p[i] ^ q[i]);
        p[i] ^= t;
        q[i] ^= t;
    }
}

inline void pack25519(uint8_t * o, const gf n) {
    gf m, t;
    for (int i = 0; i < 16; i++) t[i] = n[i];
    car25519(t);
    car25519(t);
    car25519(t);
    for (int j = 0; j < 2; j++) {
        m[0] = t[0] - 0xffed;
        for (int i = 1; i < 15; i++) {
            m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
            m[i - 1] &= 0xffff;
        }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
        const int b = (int)((m[15] >> 16) & 1);
        m[14] &= 0xffff;
        sel25519(t, m, 1 - b);
    }
    for (int i = 0; i < 16; i++) {
        o[2 * i] = (uint8_t)(t[i] & 0xff);
        o[2 * i + 1] = (uint8_t)(t[i] >> 8);
    }
}

inline void unpack25519(gf o, const uint8_t * n) {
    for (int i = 0; i < 16; i++) o[i] = n[2 * i] + ((int64_t)n[2 * i + 1] << 8);
    o[15] &= 0x7fff;
}

inline void fadd(gf o, const gf a, const gf b) { for (int i = 0; i < 16; i++) o[i] = a[i] + b[i]; }
inline void fsub(gf o, const gf a, const gf b) { for (int i = 0; i < 16; i++) o[i] = a[i] - b[i]; }

inline void fmul(gf o, const gf a, const gf b) {
    int64_t t[31] = {};
    for (int i = 0; i < 16; i++)
        for (int j = 0; j < 16; j++) t[i + j] += a[i] * b[j];
    for (int i = 0; i < 15; i++) t[i] += 38 * t[i + 16];
    for (int i = 0; i < 16; i++) o[i] = t[i];
    car25519(o);
    car25519(o);
}

inline void finv(gf o, const gf in) {
    gf c;
    for (int a = 0; a < 16; a++) c[a] = in[a];
    for (int a = 253; a >= 0; a--) {
        fmul(c, c, c);
        if (a != 2 && a != 4) fmul(c, c, in);
    }
    for (int a = 0; a < 16; a++) o[a] = c[a];
}

/// q = n * p. Returns false for a peer key that gives an all-zero secret
/// (a low-order point), which must be refused.
inline bool x25519(uint8_t q[32], const uint8_t n[32], const uint8_t p[32]) {
    uint8_t z[32];
    int64_t x[80];
    gf a, b, c, d, e, f;
    static const gf k121665 = {0xDB41, 1};
    for (int i = 0; i < 31; i++) z[i] = n[i];
    z[31] = (n[31] & 127) | 64;
    z[0] &= 248;
    unpack25519(x, p);
    for (int i = 0; i < 16; i++) {
        b[i] = x[i];
        d[i] = a[i] = c[i] = 0;
    }
    a[0] = d[0] = 1;
    for (int i = 254; i >= 0; --i) {
        const int r = (z[i >> 3] >> (i & 7)) & 1;
        sel25519(a, b, r);
        sel25519(c, d, r);
        fadd(e, a, c);
        fsub(a, a, c);
        fadd(c, b, d);
        fsub(b, b, d);
        fmul(d, e, e);
        fmul(f, a, a);
        fmul(a, c, a);
        fmul(c, b, e);
        fadd(e, a, c);
        fsub(a, a, c);
        fmul(b, a, a);
        fsub(c, d, f);
        fmul(a, c, k121665);
        fadd(a, a, d);
        fmul(c, c, a);
        fmul(a, d, f);
        fmul(d, b, x);
        fmul(b, e, e);
        sel25519(a, b, r);
        sel25519(c, d, r);
    }
    for (int i = 0; i < 16; i++) {
        x[i + 16] = a[i];
        x[i + 32] = c[i];
    }
    finv(x + 32, x + 32);
    fmul(x + 16, x + 16, x + 32);
    pack25519(q, x + 16);
    wipe(z, sizeof(z));
    uint8_t acc = 0;
    for (int i = 0; i < 32; i++) acc |= q[i];
    return acc != 0;
}

inline void x25519_public(uint8_t pub[32], const uint8_t secret[32]) {
    static const uint8_t base[32] = {9};
    x25519(pub, secret, base);
}

}  // namespace privatelm_crypto
