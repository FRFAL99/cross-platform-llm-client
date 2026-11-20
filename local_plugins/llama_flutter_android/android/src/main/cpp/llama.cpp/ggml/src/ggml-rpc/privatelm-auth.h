// PrivateLM patch: pairing-code authentication and encryption for the
// phone cluster.
//
// ggml's RPC server has no authentication and sends everything in the
// clear. A worker now holds a pairing code. Before the RPC HELLO, worker
// and master exchange ephemeral X25519 keys and prove to each other, with
// HMAC-SHA256 over the whole exchange, that they know the code; the code
// itself never crosses the network. Both sides then derive one key per
// direction from the X25519 secret, and every byte after the handshake
// travels in ChaCha20-Poly1305 records (see transport.cpp).
//
//   worker -> master : "PLM2" | nonce_w (32) | pub_w (32)
//   master -> worker : nonce_m (32) | pub_m (32) | HMAC(code, "PrivateLM master" | T)
//   worker -> master : status (1: ok, 0: wrong code) | HMAC(code, "PrivateLM worker" | T)
//   T = nonce_w | pub_w | nonce_m | pub_m
//   key(dir) = HMAC(X25519(secret, peer pub), "PrivateLM key " dir | T), dir = m2w or w2m
//
// The MACs bind the ephemeral keys, so only someone who knows the code can
// sit in the middle; someone who only listens learns nothing, even if they
// later guess the code. Earlier apps speak "PLM1" (no encryption) and are
// refused, so both phones must run this version.
#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <random>
#include <string>

#include "privatelm-crypto.h"

namespace privatelm_auth {

static constexpr uint8_t kMagic[4] = {'P', 'L', 'M', '2'};
static constexpr size_t kKeySize = 32;
static constexpr size_t kNonceSize = 32;
static constexpr size_t kMacSize = 32;

using digest = std::array<uint8_t, 32>;

// ── SHA-256 (FIPS 180-4) ────────────────────────────────────────────────

struct sha256 {
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                     0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    uint8_t buf[64] = {};
    size_t buf_len = 0;
    uint64_t total = 0;

    static uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

    void block(const uint8_t * p) {
        static const uint32_t k[64] = {
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
        uint32_t w[64];
        for (int i = 0; i < 16; i++) {
            w[i] = (uint32_t)p[i * 4] << 24 | (uint32_t)p[i * 4 + 1] << 16 |
                   (uint32_t)p[i * 4 + 2] << 8 | (uint32_t)p[i * 4 + 3];
        }
        for (int i = 16; i < 64; i++) {
            const uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            const uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int i = 0; i < 64; i++) {
            const uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            const uint32_t ch = (e & f) ^ (~e & g);
            const uint32_t t1 = hh + s1 + ch + k[i] + w[i];
            const uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            const uint32_t t2 = s0 + maj;
            hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }

    void update(const void * data, size_t len) {
        const uint8_t * p = (const uint8_t *)data;
        total += len;
        while (len > 0) {
            const size_t n = std::min(len, sizeof(buf) - buf_len);
            std::memcpy(buf + buf_len, p, n);
            buf_len += n; p += n; len -= n;
            if (buf_len == sizeof(buf)) { block(buf); buf_len = 0; }
        }
    }

    digest finish() {
        const uint64_t bits = total * 8;
        const uint8_t pad = 0x80;
        update(&pad, 1);
        const uint8_t zero = 0;
        while (buf_len != 56) update(&zero, 1);
        uint8_t len_be[8];
        for (int i = 0; i < 8; i++) len_be[i] = (uint8_t)(bits >> (56 - 8 * i));
        update(len_be, 8);
        digest out;
        for (int i = 0; i < 8; i++) {
            out[i * 4] = (uint8_t)(h[i] >> 24); out[i * 4 + 1] = (uint8_t)(h[i] >> 16);
            out[i * 4 + 2] = (uint8_t)(h[i] >> 8); out[i * 4 + 3] = (uint8_t)h[i];
        }
        return out;
    }
};

// ── HMAC-SHA256 (RFC 2104) ──────────────────────────────────────────────

struct span { const void * p; size_t n; };

inline digest hmac(const uint8_t * key, size_t key_len, std::initializer_list<span> parts) {
    uint8_t k[64] = {};
    if (key_len > sizeof(k)) {
        sha256 kh;
        kh.update(key, key_len);
        const digest d = kh.finish();
        std::memcpy(k, d.data(), d.size());
    } else {
        std::memcpy(k, key, key_len);
    }
    uint8_t ipad[64], opad[64];
    for (int i = 0; i < 64; i++) { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c; }
    sha256 inner;
    inner.update(ipad, sizeof(ipad));
    for (const auto & part : parts) inner.update(part.p, part.n);
    const digest ih = inner.finish();
    sha256 outer;
    outer.update(opad, sizeof(opad));
    outer.update(ih.data(), ih.size());
    privatelm_crypto::wipe(k, sizeof(k));
    privatelm_crypto::wipe(ipad, sizeof(ipad));
    privatelm_crypto::wipe(opad, sizeof(opad));
    return outer.finish();
}

inline digest hmac(const std::string & key, std::initializer_list<span> parts) {
    return hmac((const uint8_t *)key.data(), key.size(), parts);
}

inline bool equal(const uint8_t * a, const uint8_t * b, size_t n) {
    return privatelm_crypto::equal(a, b, n);
}

inline void random_bytes(uint8_t * out, size_t n) {
    std::random_device rd;  // /dev/urandom on Android and Apple
    for (size_t i = 0; i < n; i += 4) {
        const uint32_t v = rd();
        for (size_t j = 0; j < 4 && i + j < n; j++) out[i + j] = (uint8_t)(v >> (8 * j));
    }
}

static const char kMasterLabel[] = "PrivateLM master";
static const char kWorkerLabel[] = "PrivateLM worker";
static const char kKeyM2W[] = "PrivateLM key m2w";
static const char kKeyW2M[] = "PrivateLM key w2m";

/// Keys for the encrypted channel after a successful handshake.
struct session_keys {
    uint8_t send[kKeySize];
    uint8_t recv[kKeySize];
};

// ── Handshake over any byte stream ──────────────────────────────────────

enum result { OK = 0, IO_ERROR = 1, WRONG_CODE = 2, NOT_PRIVATELM = 3 };

// Transcript T = nonce_w | pub_w | nonce_m | pub_m.
static constexpr size_t kHalf = kNonceSize + kKeySize;
using transcript = std::array<uint8_t, 2 * kHalf>;

inline digest mac(const std::string & code, const char * label, const transcript & t) {
    return hmac(code, {{label, std::strlen(label)}, {t.data(), t.size()}});
}

/// Derives both directions' keys; false if the peer's key is unusable.
inline bool derive(const uint8_t secret[kKeySize], const uint8_t peer_pub[kKeySize], const transcript & t,
                   bool is_master, session_keys * keys) {
    uint8_t shared[kKeySize];
    if (!privatelm_crypto::x25519(shared, secret, peer_pub)) return false;
    const digest m2w = hmac(shared, sizeof(shared), {{kKeyM2W, sizeof(kKeyM2W) - 1}, {t.data(), t.size()}});
    const digest w2m = hmac(shared, sizeof(shared), {{kKeyW2M, sizeof(kKeyW2M) - 1}, {t.data(), t.size()}});
    privatelm_crypto::wipe(shared, sizeof(shared));
    std::memcpy(keys->send, (is_master ? m2w : w2m).data(), kKeySize);
    std::memcpy(keys->recv, (is_master ? w2m : m2w).data(), kKeySize);
    return true;
}

/// Worker side. `send`/`recv` move exactly n bytes and return false on
/// error. On OK, [keys] holds the session keys.
template <typename Send, typename Recv, typename Flush>
result serve(const std::string & code, Send send, Recv recv, Flush flush, session_keys * keys) {
    transcript t;
    uint8_t secret[kKeySize];
    random_bytes(secret, sizeof(secret));
    random_bytes(t.data(), kNonceSize);
    privatelm_crypto::x25519_public(t.data() + kNonceSize, secret);

    uint8_t hello[sizeof(kMagic) + kHalf];
    std::memcpy(hello, kMagic, sizeof(kMagic));
    std::memcpy(hello + sizeof(kMagic), t.data(), kHalf);
    if (!send(hello, sizeof(hello)) || !flush()) return IO_ERROR;

    uint8_t reply[kHalf + kMacSize];
    if (!recv(reply, sizeof(reply))) return IO_ERROR;
    std::memcpy(t.data() + kHalf, reply, kHalf);
    const digest expected = mac(code, kMasterLabel, t);
    bool ok = equal(expected.data(), reply + kHalf, kMacSize);
    if (ok) ok = derive(secret, t.data() + kHalf + kNonceSize, t, false, keys);
    privatelm_crypto::wipe(secret, sizeof(secret));

    uint8_t answer[1 + kMacSize] = {};
    answer[0] = ok ? 1 : 0;
    if (ok) {
        const digest proof = mac(code, kWorkerLabel, t);
        std::memcpy(answer + 1, proof.data(), kMacSize);
    }
    if (!send(answer, sizeof(answer)) || !flush()) return IO_ERROR;
    return ok ? OK : WRONG_CODE;
}

/// Master side. On OK, [keys] holds the session keys.
template <typename Send, typename Recv, typename Flush>
result connect(const std::string & code, Send send, Recv recv, Flush flush, session_keys * keys) {
    uint8_t hello[sizeof(kMagic) + kHalf];
    if (!recv(hello, sizeof(kMagic))) return IO_ERROR;
    if (std::memcmp(hello, kMagic, sizeof(kMagic)) != 0) return NOT_PRIVATELM;
    if (!recv(hello + sizeof(kMagic), kHalf)) return IO_ERROR;

    transcript t;
    std::memcpy(t.data(), hello + sizeof(kMagic), kHalf);
    uint8_t secret[kKeySize];
    random_bytes(secret, sizeof(secret));
    random_bytes(t.data() + kHalf, kNonceSize);
    privatelm_crypto::x25519_public(t.data() + kHalf + kNonceSize, secret);

    uint8_t reply[kHalf + kMacSize];
    std::memcpy(reply, t.data() + kHalf, kHalf);
    const digest m = mac(code, kMasterLabel, t);
    std::memcpy(reply + kHalf, m.data(), kMacSize);
    if (!send(reply, sizeof(reply)) || !flush()) {
        privatelm_crypto::wipe(secret, sizeof(secret));
        return IO_ERROR;
    }

    uint8_t answer[1 + kMacSize];
    const bool got = recv(answer, sizeof(answer));
    bool ok = got && answer[0] == 1;
    // A worker that accepts without proving it knows the code is an impostor.
    if (ok) ok = equal(mac(code, kWorkerLabel, t).data(), answer + 1, kMacSize);
    if (ok) ok = derive(secret, t.data() + kNonceSize, t, true, keys);
    privatelm_crypto::wipe(secret, sizeof(secret));
    if (!got) return IO_ERROR;
    return ok ? OK : WRONG_CODE;
}

}  // namespace privatelm_auth
