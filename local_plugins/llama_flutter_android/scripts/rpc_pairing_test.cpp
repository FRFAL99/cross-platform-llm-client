// Host test for the phone cluster's pairing and dropped-worker handling
// (PrivateLM patches in ggml-rpc). Not part of the app build.
//
// Build ggml with RPC on a Linux/macOS host, then this file:
//   cp -r android/src/main/cpp/llama.cpp/ggml /tmp/ggml && touch /tmp/ggml/ggml.pc.in
//   cmake -S /tmp/ggml -B /tmp/ggml-build -G Ninja -DGGML_RPC=ON -DGGML_NATIVE=OFF \
//         -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release && cmake --build /tmp/ggml-build
//   g++ -std=c++17 scripts/rpc_pairing_test.cpp -I/tmp/ggml/include \
//       -L/tmp/ggml-build/src -L/tmp/ggml-build/src/ggml-rpc \
//       -lggml -lggml-base -lggml-cpu -lggml-rpc -pthread -o /tmp/rpc_pairing_test
//   LD_LIBRARY_PATH=/tmp/ggml-build/src:/tmp/ggml-build/src/ggml-rpc /tmp/rpc_pairing_test
//
// Checks: right code accepted, wrong code rejected, unreachable and busy
// workers reported, a worker of the older protocol (PLM1) refused, a graph
// computed over RPC with tensors larger than one encrypted record, nothing
// readable on the wire (through a recording proxy), a tampered record
// refused without crashing either side, and a worker killed mid-use no
// longer aborts the master ("RPC worker lost" is logged instead).
#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-rpc.h"
#include "ggml-cpu.h"
#include "ggml-alloc.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <thread>
#include <chrono>
#include <atomic>
#include <algorithm>
#include <mutex>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

static std::atomic<int> g_lost_logged{0};
static void logcb(ggml_log_level, const char * text, void *) {
    if (strstr(text, "RPC worker lost")) g_lost_logged++;
    if (strstr(text, "RPC")) fprintf(stderr, "[log] %s", text);
}

using set_server_code_t = void (*)(const char *);
using set_client_code_t = void (*)(const char *, const char *);
using check_t = int (*)(const char *, const char *, int);

static void * proc(const char * name) { return ggml_backend_reg_get_proc_address(ggml_backend_rpc_reg(), name); }

struct job { ggml_context * ctx; ggml_tensor *a, *b, *c; ggml_cgraph * g; };
static job make(ggml_backend_t be, int n = 4) {
    ggml_init_params p = { 4 * ggml_tensor_overhead() + ggml_graph_overhead(), nullptr, true };
    job j; j.ctx = ggml_init(p);
    j.a = ggml_new_tensor_1d(j.ctx, GGML_TYPE_F32, n);
    j.b = ggml_new_tensor_1d(j.ctx, GGML_TYPE_F32, n);
    j.c = ggml_add(j.ctx, j.a, j.b);
    j.g = ggml_new_graph(j.ctx);
    ggml_build_forward_expand(j.g, j.c);
    ggml_backend_alloc_ctx_tensors(j.ctx, be);
    return j;
}
static float compute(ggml_backend_t be, job & j) {
    ggml_tensor *a = j.a, *b = j.b, *c = j.c; ggml_cgraph * g = j.g;
    float va[4] = {1, 2, 3, 4}, vb[4] = {10, 20, 30, 40}, out[4] = {};
    ggml_backend_tensor_set(a, va, 0, sizeof(va));
    ggml_backend_tensor_set(b, vb, 0, sizeof(vb));
    ggml_backend_graph_compute(be, g);
    ggml_backend_tensor_get(c, out, 0, sizeof(out));
    return out[0] + out[1] + out[2] + out[3];
}

// A recognizable value: its bytes must never show up on the wire.
static const float kMarker = 1234.5678f;

// Sends n markers + n twos through RPC; true if every result is right.
static bool compute_big(ggml_backend_t be, job & j, int n) {
    std::vector<float> va(n, kMarker), vb(n, 2.0f), out(n, 0.0f);
    ggml_backend_tensor_set(j.a, va.data(), 0, n * sizeof(float));
    ggml_backend_tensor_set(j.b, vb.data(), 0, n * sizeof(float));
    ggml_backend_graph_compute(be, j.g);
    ggml_backend_tensor_get(j.c, out.data(), 0, n * sizeof(float));
    for (float v : out) if (v != kMarker + 2.0f) return false;
    return true;
}

static int listen_on(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in a = {};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(fd, (sockaddr *)&a, sizeof(a));
    listen(fd, 4);
    return fd;
}

static int connect_to(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a = {};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (sockaddr *)&a, sizeof(a)) != 0) { close(fd); return -1; }
    return fd;
}

// Forwards one connection from listen_port to target_port, recording what
// the master sends. With flip_at > 0, flips that byte of the master's stream.
struct proxy {
    std::vector<uint8_t> m2w;
    std::mutex mu;
    size_t flip_at = 0;
    void run(int listen_port, int target_port) {
        std::thread([this, listen_port, target_port] {
            int lfd = listen_on(listen_port);
            while (true) {
                int c = accept(lfd, nullptr, nullptr);
                if (c < 0) return;
                int w = connect_to(target_port);
                if (w < 0) { close(c); continue; }
                std::thread([this, c, w] {  // master -> worker
                    uint8_t buf[65536];
                    size_t total = 0;
                    ssize_t n;
                    while ((n = recv(c, buf, sizeof(buf), 0)) > 0) {
                        {
                            std::lock_guard<std::mutex> lock(mu);
                            m2w.insert(m2w.end(), buf, buf + n);
                        }
                        if (flip_at && total <= flip_at && flip_at < total + (size_t)n) buf[flip_at - total] ^= 0x40;
                        total += (size_t)n;
                        if (send(w, buf, n, MSG_NOSIGNAL) != n) break;
                    }
                    shutdown(w, SHUT_RDWR); shutdown(c, SHUT_RDWR);
                }).detach();
                std::thread([c, w] {  // worker -> master
                    uint8_t buf[65536];
                    ssize_t n;
                    while ((n = recv(w, buf, sizeof(buf), 0)) > 0) {
                        if (send(c, buf, n, MSG_NOSIGNAL) != n) break;
                    }
                    shutdown(w, SHUT_RDWR); shutdown(c, SHUT_RDWR);
                }).detach();
            }
        }).detach();
    }
    bool contains_marker() {
        std::lock_guard<std::mutex> lock(mu);
        uint8_t pattern[16];
        for (int i = 0; i < 4; i++) std::memcpy(pattern + 4 * i, &kMarker, 4);
        return std::search(m2w.begin(), m2w.end(), pattern, pattern + 16) != m2w.end();
    }
};

static pid_t start_worker(const char * ep, const char * code) {
    pid_t pid = fork();
    if (pid == 0) {
        ggml_log_set(logcb, nullptr);
        ((void (*)(const char *))ggml_backend_reg_get_proc_address(
            ggml_backend_rpc_reg(), "ggml_backend_rpc_set_server_code"))(code);
        ggml_backend_dev_t cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
        ggml_backend_rpc_start_server(ep, nullptr, 2, 1, &cpu);
        _exit(1);
    }
    return pid;
}

int main() {
    ggml_log_set(logcb, nullptr);
    const char * ep = "127.0.0.1:50999";
    pid_t pid = start_worker(ep, "ABCD-EFGH-JKLM");
    // A second worker behind a proxy that tampers with one record.
    pid_t pid2 = start_worker("127.0.0.1:50996", "ABCD-EFGH-JKLM");
    // An older worker: greets with "PLM1".
    std::thread([] {
        int lfd = listen_on(50995);
        int c = accept(lfd, nullptr, nullptr);
        uint8_t hello[36] = {'P', 'L', 'M', '1'};
        send(c, hello, sizeof(hello), MSG_NOSIGNAL);
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        close(c); close(lfd);
    }).detach();
    proxy recorder, tamper;
    recorder.run(50994, 50999);
    tamper.flip_at = 2000;  // well past the handshake
    tamper.run(50993, 50996);
    std::this_thread::sleep_for(std::chrono::milliseconds(800));
    auto check = (check_t)proc("ggml_backend_rpc_check_server");
    auto setc = (set_client_code_t)proc("ggml_backend_rpc_set_client_code");
    int fails = 0;
    auto expect = [&](const char * what, int got, int want) {
        printf("%-34s got %d want %d %s\n", what, got, want, got == want ? "OK" : "FAIL");
        if (got != want) fails++;
    };
    expect("check right code", check(ep, "ABCD-EFGH-JKLM", 2000), 0);
    expect("check wrong code", check(ep, "ABCD-EFGH-XXXX", 2000), 2);
    expect("check unreachable port", check("127.0.0.1:50998", "x", 1000), 1);
    expect("check older worker (PLM1)", check("127.0.0.1:50995", "ABCD-EFGH-JKLM", 1000), 3);

    // Tampered stream: the worker must refuse the record; the master sees
    // a lost worker instead of crashing.
    {
        const char * tep = "127.0.0.1:50993";
        setc(tep, "ABCD-EFGH-JKLM");
        ggml_backend_t tbe = ggml_backend_dev_init(
            ggml_backend_reg_dev_get(ggml_backend_rpc_add_server(tep), 0), nullptr);
        job tj = make(tbe, 4096);
        const int lost_before = g_lost_logged.load();
        const bool ok = compute_big(tbe, tj, 4096);
        expect("tampered record: no right result", ok ? 1 : 0, 0);
        expect("tampered record: worker lost", g_lost_logged.load() > lost_before ? 1 : 0, 1);
        kill(pid2, SIGKILL);
        waitpid(pid2, nullptr, 0);
    }

    // Through the recording proxy: big tensors (several 64 KiB records)
    // come back right, and the marker never appears in the clear.
    const char * pep = "127.0.0.1:50994";
    setc(pep, "ABCD-EFGH-JKLM");
    ggml_backend_reg_t reg = ggml_backend_rpc_add_server(pep);
    ggml_backend_dev_t dev = ggml_backend_reg_dev_get(reg, 0);
    ggml_backend_t be = ggml_backend_dev_init(dev, nullptr);
    job big = make(be, 300000);
    expect("1.2 MB tensors round trip", compute_big(be, big, 300000) ? 1 : 0, 1);
    expect("marker never on the wire", recorder.contains_marker() ? 1 : 0, 0);
    {
        std::lock_guard<std::mutex> lock(recorder.mu);
        expect("wire carried the tensors (> 2 MB)", recorder.m2w.size() > 2000000 ? 1 : 0, 1);
    }
    job j = make(be);
    expect("compute over RPC (sum*1)", (int)compute(be, j), 110);
    expect("check while busy", check(ep, "ABCD-EFGH-JKLM", 1500), 4);

    kill(pid, SIGKILL);
    waitpid(pid, nullptr, 0);
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    float r = compute(be, j);  // must not abort
    expect("compute after worker died = 0", (int)r, 0);
    expect("lost logged", g_lost_logged.load() >= 2 ? 1 : 0, 1);
    r = compute(be, j);
    expect("second compute still no abort", (int)r, 0);
    printf(fails ? "FAILED %d\n" : "ALL OK\n", fails);
    fflush(stdout); _exit(fails ? 1 : 0);
}
