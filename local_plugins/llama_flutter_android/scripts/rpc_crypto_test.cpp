// Known-answer tests for ggml-rpc/privatelm-crypto.h (RFC 7748, RFC 8439).
//   g++ -std=c++17 -O2 -I<ggml>/src/ggml-rpc rpc_crypto_test.cpp -o rpc_crypto_test
#include "privatelm-crypto.h"

#include <chrono>
#include <cstdio>
#include <string>
#include <vector>

using namespace privatelm_crypto;

static std::vector<uint8_t> hex(const char * s) {
    std::vector<uint8_t> out;
    for (; s[0] && s[1]; s += 2) {
        while (*s == ' ' || *s == ':') s++;
        if (!s[0] || !s[1]) break;
        out.push_back((uint8_t)std::stoi(std::string(s, 2), nullptr, 16));
    }
    return out;
}

static int failures = 0;
static void check(const char * name, const uint8_t * got, const std::vector<uint8_t> & want) {
    const bool ok = std::memcmp(got, want.data(), want.size()) == 0;
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    if (!ok) failures++;
}

int main() {
    const char * sunscreen =
        "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, "
        "sunscreen would be it.";
    const size_t sun_len = std::strlen(sunscreen);

    // RFC 8439 2.4.2
    {
        uint8_t key[32];
        for (int i = 0; i < 32; i++) key[i] = (uint8_t)i;
        const auto nonce = hex("000000000000004a00000000");
        std::vector<uint8_t> data(sunscreen, sunscreen + sun_len);
        chacha20_xor(key, 1, nonce.data(), data.data(), data.size());
        check("chacha20 2.4.2", data.data(), hex(
            "6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0b"
            "f91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d8"
            "07ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab7793736"
            "5af90bbf74a35be6b40b8eedf2785e42874d"));
    }
    // RFC 8439 2.5.2
    {
        const auto key = hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b");
        const char * msg = "Cryptographic Forum Research Group";
        uint8_t tag[16];
        poly1305 p(key.data());
        p.update((const uint8_t *)msg, std::strlen(msg));
        p.finish(tag);
        check("poly1305 2.5.2", tag, hex("a8061dc1305136c6c22b8baf0c0127a9"));
    }
    // RFC 8439 2.8.2
    {
        auto key = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
        const auto nonce = hex("070000004041424344454647");
        const auto aad = hex("50515253c0c1c2c3c4c5c6c7");
        std::vector<uint8_t> data(sunscreen, sunscreen + sun_len);
        uint8_t tag[16];
        aead_seal(key.data(), nonce.data(), aad.data(), aad.size(), data.data(), data.size(), tag);
        check("aead 2.8.2 ciphertext", data.data(), hex(
            "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6"
            "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36"
            "92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc"
            "3ff4def08e4b7a9de576d26586cec64b6116"));
        check("aead 2.8.2 tag", tag, hex("1ae10b594f09e26a7e902ecbd0600691"));
        auto copy = data;
        const bool opened = aead_open(key.data(), nonce.data(), aad.data(), aad.size(), copy.data(), copy.size(), tag);
        const bool ok = opened && std::memcmp(copy.data(), sunscreen, sun_len) == 0;
        std::printf("%s aead open\n", ok ? "ok  " : "FAIL");
        failures += !ok;
        copy = data;
        copy[5] ^= 1;
        const bool rejected = !aead_open(key.data(), nonce.data(), aad.data(), aad.size(), copy.data(), copy.size(), tag);
        std::printf("%s aead rejects a flipped bit\n", rejected ? "ok  " : "FAIL");
        failures += !rejected;
    }
    // RFC 7748 6.1
    {
        const auto a = hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
        const auto b = hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
        uint8_t pa[32], pb[32], s1[32], s2[32];
        x25519_public(pa, a.data());
        x25519_public(pb, b.data());
        check("x25519 alice public", pa, hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"));
        check("x25519 bob public", pb, hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"));
        x25519(s1, a.data(), pb);
        x25519(s2, b.data(), pa);
        check("x25519 shared (alice)", s1, hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"));
        check("x25519 shared (bob)", s2, hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"));
        uint8_t zero_point[32] = {}, out[32];
        const bool refused = !x25519(out, a.data(), zero_point);
        std::printf("%s x25519 refuses a low-order point\n", refused ? "ok  " : "FAIL");
        failures += !refused;
    }
    // RFC 7748 5.2, one iteration
    {
        uint8_t k[32] = {9}, u[32] = {9}, out[32];
        x25519(out, k, u);
        check("x25519 iteration 1", out, hex("422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079"));
    }
    // Throughput, for the record.
    {
        std::vector<uint8_t> buf(64 << 20, 7);
        uint8_t key[32] = {1}, nonce[12] = {}, tag[16];
        const auto t0 = std::chrono::steady_clock::now();
        for (size_t off = 0; off < buf.size(); off += 65536)
            aead_seal(key, nonce, nullptr, 0, buf.data() + off, 65536, tag);
        const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        std::printf("seal: %.0f MB/s\n", buf.size() / s / 1e6);
    }
    std::printf("%s\n", failures ? "FAILED" : "all passed");
    return failures ? 1 : 0;
}
