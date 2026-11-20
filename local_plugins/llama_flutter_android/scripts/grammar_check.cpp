// Host check for PrivateLM's JSON/tool grammars (lib/services/server/json_grammar.dart).
// Build against a host build of the vendored llama.cpp (static libllama + ggml):
//   g++ -std=c++17 -I<llama.cpp>/src -I<llama.cpp>/include -I<llama.cpp>/ggml/include \
//       grammar_check.cpp libllama.a libggml*.a -lpthread -ldl -fopenmp -o grammar_check
// Cases come from tool/grammar_cases.dart.
#include "llama-grammar.h"
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

static std::vector<uint32_t> utf8(const std::string & s) {
    std::vector<uint32_t> out;
    for (size_t i = 0; i < s.size();) {
        unsigned char c = s[i];
        int n = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
        uint32_t cp = n == 1 ? c : c & (0xFF >> (n + 1));
        for (int k = 1; k < n; k++) cp = (cp << 6) | (s[i + k] & 0x3F);
        out.push_back(cp);
        i += n;
    }
    return out;
}

static bool matches(const std::string & gbnf, const std::string & text) {
    llama_grammar * g = llama_grammar_init_impl(nullptr, gbnf.c_str(), "root", false, nullptr, 0, nullptr, 0);
    if (!g) return false;
    for (uint32_t cp : utf8(text)) {
        llama_grammar_accept(g, cp);
        if (g->stacks.empty()) { llama_grammar_free_impl(g); return false; }
    }
    bool done = false;
    for (auto & st : g->stacks) if (st.empty()) done = true;
    llama_grammar_free_impl(g);
    return done;
}

static std::string unescape(std::string s) {
    const std::string mark = "\u23CE";
    for (size_t p; (p = s.find(mark)) != std::string::npos;) s.replace(p, mark.size(), "\n");
    return s;
}

// File format: blocks separated by "=== name", grammar lines until "---",
// then cases "+ text" (must match) or "- text" (must not).
int main(int argc, char ** argv) {
    std::ifstream f(argv[1]);
    std::string line, name, gbnf;
    bool in_cases = false;
    int fails = 0, total = 0;
    while (std::getline(f, line)) {
        if (line.rfind("=== ", 0) == 0) {
            name = line.substr(4); gbnf.clear(); in_cases = false;
            continue;
        }
        if (line == "---") {
            in_cases = true;
            llama_grammar_parser p;
            if (!p.parse(gbnf.c_str()) || p.rules.empty()) {
                printf("FAIL %s: grammar does not parse\n%s\n", name.c_str(), gbnf.c_str());
                fails++;
            }
            continue;
        }
        if (!in_cases) { gbnf += line + "\n"; continue; }
        if (line.size() < 2) continue;
        const bool want = line[0] == '+';
        const std::string text = unescape(line.substr(2));
        total++;
        if (matches(gbnf, text) != want) {
            printf("FAIL %s: %s %s\n", name.c_str(), want ? "should match" : "should not match", text.c_str());
            fails++;
        }
    }
    printf("%d cases, %d failures\n", total, fails);
    return fails ? 1 : 0;
}
