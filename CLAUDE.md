# CLAUDE.md

Context for working on this repository. The owner is Francesco (GitHub `FRFAL99`); talk to him in Italian. Code, comments and commit messages stay in English.

## What this is

PrivateLM: a Flutter chat client for LLMs, forked from `orailnoor/cross-platform-llm-client`. This fork is being cleaned up and refocused on a small, private, reliable core:

- **Local chat** with GGUF models via llama.cpp (`local_plugins/llama_flutter_android`), GPU offload (Vulkan) and automatic settings from the device RAM.
- **Cloud providers** through one OpenAI-compatible streaming client (`CloudService`), plus Anthropic and Gemini.
- **Local OpenAI-compatible server** (`openai_server_service_io.dart`): localhost only by default; network mode requires an API key.

Privacy is the product. Nothing should leave the device unless the user picked a cloud provider.

## Stack and layout

- Flutter 3.47.9 (pinned in CI; Flutter 3.50+ needs Gradle 9.3.1 and the Android project is on Gradle 8.14), Dart 3.13. State: GetX. Storage: Hive. HTTP: Dio + `package:http`.
- `lib/controllers` (GetX controllers), `lib/services` (inference, cloud, storage, download, server), `lib/views`, `lib/widgets`, `lib/core` (constants, routes, theme, UI kit), `lib/models`.
- Platform splits use conditional imports (`*_native.dart` / `*_web.dart` / `*_stub.dart`).
- Native code lives in `local_plugins/llama_flutter_android` (llama.cpp, vendored and lightly patched for the phone cluster). It is large; don't touch it unless the task is about it.

## Rules and decisions

- **Secrets**: API keys never go in plain Hive. `HiveService.secretKeys` routes them to `flutter_secure_storage` (Keystore/Keychain); add any new credential setting to that set.
- **Updates**: in-app updates read GitHub Releases of `AppConstants.githubRepo`, which must point to this fork. The automatic check is off by default; the user checks manually.
- **No hidden network calls**: nothing contacts a third party unless the user set it up. Fonts (Inter, Fira Code) are bundled in `assets/fonts` (no `google_fonts`), speech-to-text is on-device only, PDF text uses `pdfrx` (PDFium) instead of Syncfusion, and the cluster pairs by IP (no camera/ML Kit QR scanner). Don't add analytics, crash reporting or packages that fetch at runtime.
- **Cloud providers**: OpenAI, Anthropic, Gemini, OpenRouter and Custom API (any OpenAI-compatible endpoint). The Kimi, NVIDIA and DeepSeek presets were removed: use Custom API for them.
- **Removed, don't bring back**: Task/ExecutionService (let the LLM run ADB shell commands), image generation (Stable Diffusion, Core ML, Stability AI), the LiteRT engine, Firebase/Crashlytics, the boot receiver.
- One local engine only: llama.cpp with GGUF models.
- **Phone cluster** (`ClusterService`, llama.cpp RPC across phones on the same Wi-Fi) stays for now, off by default. Its RPC workers have no authentication, so use it only on a trusted network. No new work on it until the PC connection (Ollama / LM Studio) exists; then decide whether to keep it.
- Removed features' Hive keys are deleted on startup (`HiveService._removedFeatureKeys`).
- New settings keys go in `AppConstants`. `HiveService.init` wipes unknown `server_*` keys: register new ones there.

## Roadmap (agreed order)

1. Cleanup and security (done in the first cleanup PR): auto-update target, secure API keys, dead code, image generation, LiteRT, Firebase. Still open: the "uncensored" models in the catalogue.
2. Fixes: trim cloud chat history to the context window; streaming for Anthropic and Gemini; Hive message storage that doesn't scan every message of every chat (and images out of messages); split huge files (`model_view.dart`, `chat_view.dart`, `model_controller.dart`).
3. Features, most useful first: connect to Ollama / LM Studio on the home network; chat with documents (PDF extraction exists, add retrieval); local-only switch that blocks all network calls; context management (sliding window, auto-summary); profiles (system prompt + parameters); chat search and Markdown export; on-device tokens/s benchmark.

## Working conventions

- Commits follow Conventional Commits with a scope, e.g. `feat(cluster): ...`, `fix(cloud): ...`, `chore: ...`.
- Work on a branch and open a PR against `main`; keep PRs focused.
- Run `flutter analyze` and `flutter test` before pushing. CI (`.github/workflows/android.yml`) builds every PR; a `vX.Y.Z` tag matching `pubspec.yaml` publishes signed APKs to GitHub Releases (needs the `ANDROID_KEY*` secrets). Tests live in `test/` and use Hive in a temp directory. Nobody has built the iOS/macOS apps since the cleanup: run `pod install` and an Xcode build before an iOS release.
