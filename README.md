# OneLM

Run an LLM on your own phone, or across several phones, and use it from your other apps.

OneLM does three things:

1. **Runs GGUF models on the phone** with llama.cpp, using the GPU (Vulkan) when it can and picking settings from the device RAM.
2. **Splits a model across phones** on the same Wi-Fi (phone cluster), so a model too big for one phone can still run.
3. **Serves the loaded model as an OpenAI-compatible API**, so your own scripts and apps can use it. It listens on localhost by default; network mode requires an API key.

A chat screen is included to try the model. Everything runs on your devices: there are no cloud providers, analytics or crash reporting.

This is a fork of [orailnoor/cross-platform-llm-client](https://github.com/orailnoor/cross-platform-llm-client), cut down to that core.

## Install on Android

1. On your phone, open the [latest release](https://github.com/FRFAL99/cross-platform-llm-client/releases/latest).
2. Download `OneLM-<version>-arm64-v8a.apk` (almost every recent phone). Use `armeabi-v7a` only on old 32-bit phones.
3. Open the file and allow your browser or file manager to install unknown apps when Android asks.
4. To update, use Settings › App updates › Check for updates. The automatic check is off by default, so the app doesn't contact GitHub unless you ask.

OneLM was called PrivateLM before. It has its own package name now (`io.github.frfal99.onelm`), so it installs next to PrivateLM instead of updating it. Models, chats and settings don't carry over: uninstall PrivateLM once you've moved to OneLM.

## Use it

- **Models**: download a GGUF model from the catalogue (Hugging Face) or import a `.gguf` file, then load it. Every download is checked against its SHA-256 (pinned in the catalogue, or the one Hugging Face publishes for the file) and deleted if it doesn't match.
- **Phone cluster** (Settings › Phone cluster): on each extra phone choose *Worker*; on the main phone choose *Master* and add each worker with the address and **pairing code** it shows (or *Find nearby*, then the code). The next model load spreads the layers across the phones.
  - Only a master that knows a worker's pairing code can use it. The phones exchange one-time X25519 keys and prove they know the code with HMAC-SHA256 over the exchange, so the code never crosses the network. Everything after that (model weights, activations, results) is encrypted and authenticated with ChaCha20-Poly1305, with fresh keys for every connection. Someone listening on the Wi-Fi learns nothing, even if they later learn the code; tampered data is refused. Both phones need this version: an older worker is reported as "different OneLM version". *New pairing code* on the worker locks out masters that knew the old one.
  - Encryption costs some speed when the model is first sent to the workers (roughly 300 MB/s per phone on a desktop CPU). Generation sends little data and is hardly affected.
  - If a worker drops out (Wi-Fi off, battery, app closed), the model reloads on the phones that are left and the answer in progress starts again there, so the chat and API clients still get their answer. The workers that stayed keep their part of the model in a local cache, so the reload sends little over Wi-Fi. A streaming API response that already sent text can't be taken back: it ends with an error and the client retries. A worker that vanishes without closing the connection is noticed within about 30 seconds.
  - Workers paired with an older version show *Code* in the list: tap them and enter the code once. Workers must run this version too.
- **API server** (Server tab): start it and point any OpenAI client at `http://<phone>:8080/v1`. Turn on network mode to reach it from other devices on the Wi-Fi; it then requires the API key shown in the app. The Server tab has copy-ready examples (curl, Python, JavaScript).

- **Speed test** (Settings › Speed test): measures the loaded model on this phone or across the cluster, like llama-bench (pp512 prompt reading, tg128 generation), and keeps a history so you can compare models, quantizations and cluster setups.
- **Long chats**: when the conversation no longer fits in the context window (counted with the model's own tokenizer), the model summarizes the oldest messages and the summary takes their place, so the chat keeps its earlier facts. The summary is saved with the chat and updated as it grows; the chat shows how many messages it covers. Turn it off in Settings › Summarize older messages to only leave the oldest messages out, as before. Raise *Context size* in Settings to keep more messages word for word. API server requests are not summarized: clients send their own history.

### API server

| Endpoint | Notes |
|---|---|
| `POST /v1/chat/completions` | `stream`, `max_tokens`, `stop`, `temperature`, `top_p`, `tools` / `tool_choice`, `response_format` (`json_object`, `json_schema`), `stream_options.include_usage`, one image per request with a vision model |
| `POST /v1/completions` | plain prompt completion, streaming supported |
| `GET /v1/models` | the loaded model; any `model` name in a request is served by it |
| `GET /health` | no key needed |

- **One request at a time.** Others wait in a queue (up to 8, for up to 5 minutes) and then get `429` with `Retry-After`.
- **Tool calling**: tools are described with the `<tools>` / `<tool_call>` convention and the reply is parsed back into OpenAI `tool_calls`. On Android a llama.cpp grammar makes every call valid JSON with a known function name and arguments that match its `parameters`: from the first token with `tool_choice: "required"` or a named function, from `<tool_call>` on with `auto` (the model may also just answer). Use a model trained for it (Qwen 2.5/3, Hermes, Llama 3.1+, Mistral). Tool results go back as `role: "tool"` messages as usual.
- **JSON mode**: on Android, `json_object` and `json_schema` are enforced with a grammar, so the reply always parses. Schemas support `type`, `properties`, `required`, `items`, `enum`, `const`, `anyOf`/`oneOf`, `allOf`, local `$ref` and string/array lengths; `pattern`, `format` and number bounds aren't enforced. A schema it can't read is only described to the model (the app log says so). Reasoning models skip their thinking under a grammar.
- **Usage**: responses include `usage` (prompt and completion tokens); streams add a final usage chunk when `stream_options.include_usage` is true.
- **Background (Android).** While the server runs, it keeps answering with the screen off, another app in front, or OneLM swiped away from recent apps (foreground service, wake lock, Wi-Fi lock; the app keeps its Flutter engine while the server runs). Stop it in the Server tab or with **Stop server** on its notification. Allow OneLM to run without battery limits when the Server tab asks. Force-stopping the app stops it too.

## Network use

The app only goes online when you ask it to: downloading a model from Hugging Face, checking for updates on GitHub, and the cluster and server on your local network. Fonts are bundled, voice input runs on the device and PDF text is extracted on the device.

---

## Technical Architecture

### Stack

- **Framework:** Flutter 3.47.9, Dart 3.13
- **State Management:** GetX
- **Local Storage:** Hive (chat messages in a lazy box with a per-chat index; images as files)
- **Networking:** Dio (downloads) + `package:http`

### Layout

- `InferenceService` → `inference_android.dart`: llama.cpp through `local_plugins/llama_flutter_android` (Vulkan GPU offload, device-tier thread count, native chat templates, vision projectors).
- `ClusterService`: llama.cpp RPC workers and layer split across phones.
- `OpenAIServerService`: the OpenAI-compatible HTTP server.
- `DownloadService`, `HiveService`, `DeviceInfoService`, `UpdateService`.

---

## Supported Platforms

| Platform | Local Inference | Notes                                              |
| -------- | --------------- | -------------------------------------------------- |
| Android  | ✅ Yes          | Main target; minSdk 28                             |
| iOS      | ✅ Yes          | Metal GPU; not built since the cleanup. Its cluster worker uses an older llama.cpp and can't join an Android master |
| Web      | ❌ No           | No local inference                                 |

### iOS / iPad (Installation via AltServer)
The iOS/iPad release is distributed as a sideloadable IPA file. Due to the RAM requirements for local models, iPad is the recommended iOS target, but it can be installed on iPhones.

Here is how you can install the app using AltStore and AltServer:

**Prerequisites:**
* Ensure **AltServer** is installed and running on your Mac or Windows PC.
* Your iOS device must be connected to the same Wi-Fi network as your computer, or connected directly via a USB cable.
* You must have **AltStore** successfully installed on your iOS device.

**Installation Steps:**
1. **Download the IPA:** Go to the [Releases](https://github.com/FRFAL99/cross-platform-llm-client/releases) page on your iOS device (using Safari) and download the latest `OneLM-iOS.zip` package, extract it to get the `.ipa` file.
2. **Open in AltStore:**
   * Locate the extracted `.ipa` file in your device's "Files" app.
   * Tap the **Share** button and select **AltStore** from the list of apps.
   * *Alternatively*, you can open the AltStore app, go to the **My Apps** tab, tap the **"+" (plus)** icon in the top-left corner, and select the downloaded IPA file.
3. **Install:** AltStore will begin installing the app. You may be prompted to enter your Apple ID credentials if this is your first time.
4. **Enable Developer Mode:** On iOS 16 and later, ensure "Developer Mode" is enabled in your device's Settings (`Settings > Privacy & Security > Developer Mode`) to launch the sideloaded app.
5. **Launch:** Once installation is finished, OneLM will appear in the **My Apps** tab in AltStore and on your device's home screen!

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

The `Android` GitHub Actions workflow runs `flutter analyze` and `flutter test`
on every pull request; it does not build APKs there. To get a debug-signed APK
from a branch (or to check that native code still compiles), run the workflow
by hand from the Actions tab. Pushing a tag `vX.Y.Z` that matches `version:` in `pubspec.yaml` builds signed per-ABI APKs
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

## License and credits

MIT — see [LICENSE](./LICENSE) for details.

OneLM (formerly PrivateLM) is a fork of [orailnoor/cross-platform-llm-client](https://github.com/orailnoor/cross-platform-llm-client)
by orailnoor and techjarves (MIT). Inference runs on [llama.cpp](https://github.com/ggml-org/llama.cpp)
(MIT, the ggml authors), through a modified copy of the `llama_flutter_android`
plugin (MIT, dragneel2074). Third-party components, fonts and the licenses of
the catalogue models are listed in [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md);
the app shows them under Settings › About › Open-source licenses.

Models are downloaded from Hugging Face and keep their own licenses: check a
model's license before using it commercially (Qwen2.5-3B, for example, is for
non-commercial use only).
