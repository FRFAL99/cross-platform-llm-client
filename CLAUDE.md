# CLAUDE.md

Context for working on this repository. The owner is Francesco (GitHub `FRFAL99`); talk to him in Italian. Code, comments and commit messages stay in English.

## What this is

PrivateLM: a Flutter app, forked from `orailnoor/cross-platform-llm-client`, with one purpose:

1. **Run a model on the phone**: GGUF via llama.cpp (`local_plugins/llama_flutter_android`), GPU offload (Vulkan), automatic settings from the device RAM.
2. **Run it across a cluster of phones** (`ClusterService`, llama.cpp RPC over the same Wi-Fi).
3. **Serve it** as an OpenAI-compatible API (`openai_server_service_io.dart`) so Francesco's own apps and scripts can use it: localhost by default, network mode requires an API key.

The chat screen exists to try the model. Anything else is out of scope (Francesco, 2026-11-20): no cloud providers, no features unrelated to running and serving the local model. Ask before adding something that doesn't serve these three points.

Everything runs on the user's devices. The only network calls are the ones the user starts: model downloads (Hugging Face), the manual update check (GitHub), and the cluster and server on the local network.

## Stack and layout

- Flutter 3.47.9 (pinned in CI; Flutter 3.50+ needs Gradle 9.3.1 and the Android project is on Gradle 8.14), Dart 3.13. State: GetX. Storage: Hive. HTTP: Dio + `package:http`.
- `lib/controllers` (GetX controllers), `lib/services` (inference, cluster, storage, download, server), `lib/views`, `lib/widgets`, `lib/core` (constants, routes, theme, UI kit), `lib/models`.
- Platform splits use conditional imports (`*_native.dart` / `*_web.dart` / `*_stub.dart`).
- Native code lives in `local_plugins/llama_flutter_android` (llama.cpp, vendored and lightly patched for the phone cluster). It is large; don't touch it unless the task is about it.

## Rules and decisions

- **No cloud providers**: OpenAI, Anthropic, Gemini, OpenRouter and custom endpoints were removed (CloudService, cloud model picker, inference mode). Don't bring them back.
- **Secrets**: credentials never go in plain Hive. `HiveService.secretKeys` (today only the server API key) routes them to `flutter_secure_storage` (Keystore/Keychain); add any new credential setting to that set.
- **Updates**: in-app updates read GitHub Releases of `AppConstants.githubRepo`, which must point to this fork. The automatic check is off by default; the user checks manually.
- **No hidden network calls**: fonts (Inter, Fira Code) are bundled in `assets/fonts` (no `google_fonts`), speech-to-text is on-device only, PDF text uses `pdfrx` (PDFium) instead of Syncfusion, and the cluster pairs by IP (no camera/ML Kit QR scanner). Don't add analytics, crash reporting or packages that fetch at runtime.
- **Removed, don't bring back**: cloud providers, Task/ExecutionService (let the LLM run ADB shell commands), image generation (Stable Diffusion, Core ML, Stability AI), the LiteRT engine, Firebase/Crashlytics, the boot receiver.
- One local engine only: llama.cpp with GGUF models.
- **Phone cluster** is core. Its RPC workers have no authentication, so it is only for a trusted network; adding authentication is on the roadmap.
- **Chat storage**: messages live in a Hive `LazyBox` with a chatId → message ids index box; images are files under `chat_images/` (see `ChatImageStore`). Bump `HiveService._messageStorageVersion` and extend `_migrateMessages` when the layout changes.
- Removed features' Hive keys are deleted on startup (`HiveService._removedFeatureKeys`, `_removedSecretKeys`).
- New settings keys go in `AppConstants`. `HiveService.init` wipes unknown `server_*` keys: register new ones there.

## Roadmap (agreed order)

1. Done: cleanup and security, privacy pass (no hidden Google calls), removal of cloud providers, faster chat storage. Still open: the "uncensored" models in the catalogue; splitting huge files (`model_view.dart`, `chat_view.dart`, `model_controller.dart`).
2. Server: make it solid for other apps (streaming, tool/function calling if the model supports it, keep running in the background, clear connection info and examples).
3. Cluster: authentication for RPC workers, reliability when a worker drops, clearer setup.
4. Then: on-device tokens/s benchmark (phone and cluster), context management for long chats.

## Working conventions

- Commits follow Conventional Commits with a scope, e.g. `feat(cluster): ...`, `fix(server): ...`, `chore: ...`.
- Work on a branch and open a PR against `main`; keep PRs focused.
- Run `flutter analyze` and `flutter test` before pushing. CI (`.github/workflows/android.yml`) builds every PR; a `vX.Y.Z` tag matching `pubspec.yaml` publishes signed APKs to GitHub Releases (needs the `ANDROID_KEY*` secrets). Tests live in `test/` and use Hive in a temp directory. Nobody has built the iOS/macOS apps since the cleanup: run `pod install` and an Xcode build before an iOS release.
