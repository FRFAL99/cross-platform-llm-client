# PrivateLM

Run an LLM on your own phone, or across several phones, and use it from your other apps.

PrivateLM does three things:

1. **Runs GGUF models on the phone** with llama.cpp, using the GPU (Vulkan) when it can and picking settings from the device RAM.
2. **Splits a model across phones** on the same Wi-Fi (phone cluster), so a model too big for one phone can still run.
3. **Serves the loaded model as an OpenAI-compatible API**, so your own scripts and apps can use it. It listens on localhost by default; network mode requires an API key.

A chat screen is included to try the model. Everything runs on your devices: there are no cloud providers, analytics or crash reporting.

This is a fork of [orailnoor/cross-platform-llm-client](https://github.com/orailnoor/cross-platform-llm-client), cut down to that core.

## Install on Android

1. On your phone, open the [latest release](https://github.com/FRFAL99/cross-platform-llm-client/releases/latest).
2. Download `PrivateLM-<version>-arm64-v8a.apk` (almost every recent phone). Use `armeabi-v7a` only on old 32-bit phones.
3. Open the file and allow your browser or file manager to install unknown apps when Android asks.
4. To update, use Settings › App updates › Check for updates. The automatic check is off by default, so the app doesn't contact GitHub unless you ask.

If you installed the upstream PrivateLM before, uninstall it first: it uses the same package name but a different signing key, so Android refuses to update it.

## Use it

- **Models**: download a GGUF model from the catalogue (Hugging Face) or import a `.gguf` file, then load it.
- **Phone cluster** (Settings › Phone cluster): on each extra phone choose *Worker*; on the main phone choose *Master* and add each worker by the address it shows (or *Find nearby*). The next model load spreads the layers across the phones. Workers accept unauthenticated connections, so use it only on a trusted Wi-Fi.
- **API server** (Server tab): start it and point any OpenAI client at `http://<phone>:<port>/v1` (`/v1/chat/completions`, `/v1/completions`, `/v1/models`). Turn on network mode to reach it from other devices on the Wi-Fi; it then requires the API key shown in the app.

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
| iOS      | ✅ Yes          | Metal GPU; not built since the cleanup, can be a cluster worker |
| Web      | ❌ No           | No local inference                                 |

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
