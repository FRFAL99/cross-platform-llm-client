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
// workers reported, a graph computed over RPC, and a worker killed mid-use
// no longer aborts the master ("RPC worker lost" is logged instead).
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

static bool g_lost_logged = false;
static void logcb(ggml_log_level, const char * text, void *) {
    if (strstr(text, "RPC worker lost")) g_lost_logged = true;
    if (strstr(text, "RPC")) fprintf(stderr, "[log] %s", text);
}

using set_server_code_t = void (*)(const char *);
using set_client_code_t = void (*)(const char *, const char *);
using check_t = int (*)(const char *, const char *, int);

static void * proc(const char * name) { return ggml_backend_reg_get_proc_address(ggml_backend_rpc_reg(), name); }

struct job { ggml_context * ctx; ggml_tensor *a, *b, *c; ggml_cgraph * g; };
static job make(ggml_backend_t be) {
    ggml_init_params p = { 4 * ggml_tensor_overhead() + ggml_graph_overhead(), nullptr, true };
    job j; j.ctx = ggml_init(p);
    j.a = ggml_new_tensor_1d(j.ctx, GGML_TYPE_F32, 4);
    j.b = ggml_new_tensor_1d(j.ctx, GGML_TYPE_F32, 4);
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

int main() {
    ggml_log_set(logcb, nullptr);
    const char * ep = "127.0.0.1:50999";
    pid_t pid = fork();
    if (pid == 0) {
        ggml_log_set(logcb, nullptr);
        ((set_server_code_t)proc("ggml_backend_rpc_set_server_code"))("ABCD-EFGH-JKLM");
        ggml_backend_dev_t cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
        ggml_backend_rpc_start_server("127.0.0.1:50999", nullptr, 2, 1, &cpu);
        _exit(1);
    }
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

    setc(ep, "ABCD-EFGH-JKLM");
    ggml_backend_reg_t reg = ggml_backend_rpc_add_server(ep);
    ggml_backend_dev_t dev = ggml_backend_reg_dev_get(reg, 0);
    ggml_backend_t be = ggml_backend_dev_init(dev, nullptr);
    job j = make(be);
    expect("compute over RPC (sum*1)", (int)compute(be, j), 110);
    expect("check while busy", check(ep, "ABCD-EFGH-JKLM", 1500), 4);

    kill(pid, SIGKILL);
    waitpid(pid, nullptr, 0);
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    float r = compute(be, j);  // must not abort
    expect("compute after worker died = 0", (int)r, 0);
    expect("lost logged", g_lost_logged ? 1 : 0, 1);
    r = compute(be, j);
    expect("second compute still no abort", (int)r, 0);
    printf(fails ? "FAILED %d\n" : "ALL OK\n", fails);
    fflush(stdout); _exit(fails ? 1 : 0);
}
