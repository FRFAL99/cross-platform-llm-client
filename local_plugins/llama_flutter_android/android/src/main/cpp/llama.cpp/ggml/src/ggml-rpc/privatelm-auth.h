// PrivateLM patch: pairing-code authentication for the phone cluster.
//
// ggml's RPC server has no authentication: anyone on the network could load
// tensors into a worker. A worker now holds a pairing code and, before the
// RPC HELLO, runs a mutual challenge-response with HMAC-SHA256 so that only
// a master that knows the code can use it (and the master knows it reached
// the phone it paired with). The code itself never crosses the network.
//
//   worker -> master : "PLM1" | nonce_w (32)
//   master -> worker : nonce_m (32) | HMAC(code, "PrivateLM master" | nonce_w | nonce_m)
//   worker -> master : status (1: ok, 0: wrong code) | HMAC(code, "PrivateLM worker" | nonce_m | nonce_w)
//
// Traffic after the handshake is not encrypted: the cluster is still meant
// for a home network.
#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <random>
#include <string>

namespace privatelm_auth {

static constexpr uint8_t kMagic[4] = {'P', 'L', 'M', '1'};
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

inline digest hmac(const std::string & key, const char * label,
                   const uint8_t * a, const uint8_t * b, size_t n) {
    uint8_t k[64] = {};
    if (key.size() > sizeof(k)) {
        sha256 kh;
        kh.update(key.data(), key.size());
        const digest d = kh.finish();
        std::memcpy(k, d.data(), d.size());
    } else {
        std::memcpy(k, key.data(), key.size());
    }
    uint8_t ipad[64], opad[64];
    for (int i = 0; i < 64; i++) { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c; }
    sha256 inner;
    inner.update(ipad, sizeof(ipad));
    inner.update(label, std::strlen(label));
    inner.update(a, n);
    inner.update(b, n);
    const digest ih = inner.finish();
    sha256 outer;
    outer.update(opad, sizeof(opad));
    outer.update(ih.data(), ih.size());
    return outer.finish();
}

inline bool equal(const uint8_t * a, const uint8_t * b, size_t n) {
    uint8_t diff = 0;
    for (size_t i = 0; i < n; i++) diff |= a[i] ^ b[i];
    return diff == 0;
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

// ── Handshake over any byte stream ──────────────────────────────────────

enum result { OK = 0, IO_ERROR = 1, WRONG_CODE = 2, NOT_PRIVATELM = 3 };

/// Worker side. `send`/`recv` move exactly n bytes and return false on error.
template <typename Send, typename Recv, typename Flush>
result serve(const std::string & code, Send send, Recv recv, Flush flush) {
    uint8_t hello[sizeof(kMagic) + kNonceSize];
    std::memcpy(hello, kMagic, sizeof(kMagic));
    uint8_t * nonce_w = hello + sizeof(kMagic);
    random_bytes(nonce_w, kNonceSize);
    if (!send(hello, sizeof(hello)) || !flush()) return IO_ERROR;

    uint8_t reply[kNonceSize + kMacSize];
    if (!recv(reply, sizeof(reply))) return IO_ERROR;
    const uint8_t * nonce_m = reply;
    const digest expected = hmac(code, kMasterLabel, nonce_w, nonce_m, kNonceSize);
    const bool ok = equal(expected.data(), reply + kNonceSize, kMacSize);

    uint8_t answer[1 + kMacSize] = {};
    answer[0] = ok ? 1 : 0;
    if (ok) {
        const digest proof = hmac(code, kWorkerLabel, nonce_m, nonce_w, kNonceSize);
        std::memcpy(answer + 1, proof.data(), kMacSize);
    }
    if (!send(answer, sizeof(answer)) || !flush()) return IO_ERROR;
    return ok ? OK : WRONG_CODE;
}

/// Master side.
template <typename Send, typename Recv, typename Flush>
result connect(const std::string & code, Send send, Recv recv, Flush flush) {
    uint8_t hello[sizeof(kMagic) + kNonceSize];
    if (!recv(hello, sizeof(hello))) return IO_ERROR;
    if (std::memcmp(hello, kMagic, sizeof(kMagic)) != 0) return NOT_PRIVATELM;
    const uint8_t * nonce_w = hello + sizeof(kMagic);

    uint8_t reply[kNonceSize + kMacSize];
    uint8_t * nonce_m = reply;
    random_bytes(nonce_m, kNonceSize);
    const digest mac = hmac(code, kMasterLabel, nonce_w, nonce_m, kNonceSize);
    std::memcpy(reply + kNonceSize, mac.data(), kMacSize);
    if (!send(reply, sizeof(reply)) || !flush()) return IO_ERROR;

    uint8_t answer[1 + kMacSize];
    if (!recv(answer, sizeof(answer))) return IO_ERROR;
    if (answer[0] != 1) return WRONG_CODE;
    const digest expected = hmac(code, kWorkerLabel, nonce_m, nonce_w, kNonceSize);
    // A worker that accepts without proving it knows the code is an impostor.
    return equal(expected.data(), answer + 1, kMacSize) ? OK : WRONG_CODE;
}

}  // namespace privatelm_auth
