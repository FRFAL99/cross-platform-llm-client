# PrivateLM

A private, cross-platform AI chat client built with Flutter. It runs GGUF models on your phone with llama.cpp and can also use cloud providers, giving you full control over where your conversations go.

This is a fork of [orailnoor/cross-platform-llm-client](https://github.com/orailnoor/cross-platform-llm-client), trimmed to a small core: local chat, cloud chat and a local OpenAI-compatible server. Image generation, the LiteRT engine, the task runner and Firebase were removed.

## Install on Android

1. On your phone, open the [latest release](https://github.com/FRFAL99/cross-platform-llm-client/releases/latest).
2. Download `PrivateLM-<version>-arm64-v8a.apk` (almost every recent phone). Use `armeabi-v7a` only on old 32-bit phones.
3. Open the file and allow your browser or file manager to install unknown apps when Android asks.
4. To update, use Settings › App updates › Check for updates. The automatic check is off by default, so the app doesn't contact GitHub unless you ask.

If you installed the upstream PrivateLM before, uninstall it first: it uses the same package name but a different signing key, so Android refuses to update it.

---

## What It Does

- **Local Inference on Android** — Download and run GGUF models directly on your phone using GPU-accelerated inference (Vulkan). No internet required after download.
- **Cloud Providers** — Switch to OpenAI, Anthropic, Google Gemini, OpenRouter or any OpenAI-compatible endpoint (DeepSeek, Kimi, NVIDIA NIM, Ollama, LM Studio…) when you need more power. They are contacted only once you add an API key.
- **Local API Server** — Serve the loaded model as an OpenAI-compatible endpoint (localhost by default; network mode requires an API key).
- **Phone Cluster (experimental)** — Split one GGUF model across phones on the same Wi-Fi; add a worker by entering the address it shows. Workers accept unauthenticated connections, so use it only on a trusted network.
- **No hidden network calls** — Fonts are bundled, voice input runs on the device, PDF text is extracted on the device (PDFium), and there is no analytics or crash reporting.
- **Multimodal Chat** — Send text and images in conversations. Vision support works with both local models (Qwen2-VL) and cloud providers.
- **Persistent Sessions** — All chats and settings are stored locally via Hive; API keys go to the OS secure storage (Keystore/Keychain). Nothing leaves your device unless you explicitly choose cloud mode.
- **Smart Auto-Configuration** — On first launch, the app detects your device's RAM and recommends optimal context size and token limits automatically.

---

## Technical Architecture

### Stack

- **Framework:** Flutter 3.x (Dart >=3.3.0)
- **State Management:** GetX
- **Local Storage:** Hive
- **Networking:** Dio + `package:http`

### Inference Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│                        UI Layer                              │
│   ChatView / ModelView / ServerView / SettingsView          │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                    Controllers (GetX)                        │
│   ChatController · ModelController · ServerController       │
│   SettingsController · HomeController                       │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                      Services                                │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │ InferenceService│  │  CloudService   │  │DownloadSvc  │ │
│  │  (local GGUF)   │  │ (OpenAI/Claude/ │  │ (model dl)  │ │
│  │                 │  │ Gemini/custom)  │  │             │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │  HiveService    │  │ DeviceInfoSvc   │  │ UpdateSvc   │ │
│  │  ( persistence) │  │  (RAM/GPU tier) │  │ (GH release)│ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Local Inference (Android)

The app uses `llama_flutter_android`, a custom Flutter plugin wrapping `llama.cpp` for ARM64 devices. At runtime it:

1. **Detects GPU capabilities** via Vulkan to determine offload layers.
2. **Selects thread count** based on device tier (ultra / high / mid / low).
3. **Loads the GGUF model** with progress streaming.
4. **Generates tokens** via `generateChat()` with native chat-template support (ChatML, Llama-3, Gemma, Phi).
5. **Falls back** to manual prompt construction if native templates fail.

Idle detection (5s) and hard timeouts (180s) keep the UX responsive even on underpowered hardware.

### Cloud Inference

`CloudService` normalizes three API shapes into a single interface:

- **OpenAI** — standard `/v1/chat/completions`
- **Anthropic** — Messages API with separate system param
- **Google Gemini** — `generateContent` with inline image base64
- **OpenRouter and Custom API** — any OpenAI-compatible endpoint, with your own base URL

API keys are stored in the OS secure storage (Android Keystore / iOS Keychain) and never transmitted anywhere except to the provider's endpoint.

### Cross-Platform Abstraction

Local inference is conditionally compiled:

- **Android** → `inference_android.dart` (full llama.cpp engine)
- **Web** → `inference_stub.dart` (cloud-only, local coming soon)
- **iOS** → `inference_android.dart` (full llama.cpp engine via Metal GPU)

The `InferenceService` exposes `supportsLocalInference` so the UI can hide local-model UI on unsupported platforms.

---

## Supported Platforms

| Platform | Local Inference | Cloud APIs | Notes                           |
| -------- | --------------- | ---------- | ------------------------------- |
| Android  | ✅ Yes          | ✅ Yes     | CPU offload via NEON; minSdk 28 |
| iOS      | ✅ Yes          | ✅ Yes     | Metal GPU acceleration          |
| Web      | ❌ No           | ✅ Yes     | Cloud-only (local coming soon)  |

### iOS / iPad (Installation via AltServer)
The iOS/iPad release is distributed as a sideloadable IPA file. Due to the RAM requirements for local models, iPad is the recommended iOS target, but it can be installed on iPhones.

Here is how you can install the app using AltStore and AltServer:

**Prerequisites:**
* Ensure **AltServer** is installed and running on your Mac or Windows PC.
* Your iOS device must be connected to the same Wi-Fi network as your computer, or connected directly via a USB cable.
* You must have **AltStore** successfully installed on your iOS device.

**Installation Steps:**
1. **Download the IPA:** Go to the [Releases](https://github.com/FRFAL99/cross-platform-llm-client/releases) page on your iOS device (using Safari) and download the latest `PrivateLM-iOS.zip` package, extract it to get the `.ipa` file.
2. **Open in AltStore:**
   * Locate the extracted `.ipa` file in your device's "Files" app.
   * Tap the **Share** button and select **AltStore** from the list of apps.
   * *Alternatively*, you can open the AltStore app, go to the **My Apps** tab, tap the **"+" (plus)** icon in the top-left corner, and select the downloaded IPA file.
3. **Install:** AltStore will begin installing the app. You may be prompted to enter your Apple ID credentials if this is your first time.
4. **Enable Developer Mode:** On iOS 16 and later, ensure "Developer Mode" is enabled in your device's Settings (`Settings > Privacy & Security > Developer Mode`) to launch the sideloaded app.
5. **Launch:** Once installation is finished, PrivateLM will appear in the **My Apps** tab in AltStore and on your device's home screen!

*Note: Sideloaded apps via AltStore expire after 7 days, but AltStore will attempt to automatically refresh them in the background when connected to the same Wi-Fi as your computer running AltServer.*

---

## Build Configuration

### Prerequisites

- Flutter SDK >=3.3.0
- Android SDK (API 26+)
- JDK 17
- NDK (bundled with Android SDK)

### Android

```bash
flutter pub get
flutter build apk --debug
```

### Releases

The `Android` GitHub Actions workflow builds every pull request. Pushing a tag
`vX.Y.Z` that matches `version:` in `pubspec.yaml` builds signed per-ABI APKs
and publishes them as a GitHub Release, which the in-app updater picks up.

One-time setup: create a keystore and store it in the repository secrets
(Settings › Secrets and variables › Actions).

```bash
keytool -genkeypair -v -keystore privatelm-release.jks -alias privatelm \
  -keyalg RSA -keysize 4096 -validity 10000
base64 -w0 privatelm-release.jks   # value for ANDROID_KEYSTORE_BASE64
```

Secrets: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS` (`privatelm`), `ANDROID_KEY_PASSWORD`. Keep a backup of
the `.jks` file: losing it means users must uninstall to update.

To release: bump `version:` in `pubspec.yaml` (both parts, e.g.
`1.1.1+9`), merge, then `git tag v1.1.1 && git push origin v1.1.1`.

### Local release build

Release APKs require a stable signing key. Copy
`android/key.properties.example` to `android/key.properties`, fill in the
keystore values, and keep both the key and its backup. Android accepts an APK
upgrade only when it is signed with the same key as the installed APK.

```bash
cp android/key.properties.example android/key.properties
flutter build apk --release --split-per-abi
```

Never rotate the signing key between GitHub releases. The per-ABI APKs must
also keep increasing the build number in `pubspec.yaml`.

### iOS

```bash
flutter pub get
cd ios
pod install
flutter build ios
```

### Web

```bash
flutter pub get
flutter build web --release
```

---

## License

MIT — see [LICENSE](./LICENSE) for details.
