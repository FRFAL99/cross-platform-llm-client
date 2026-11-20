import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import '../core/constants.dart';
import '../core/ui.dart';
import '../services/app_log_service.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';
import '../services/cluster_service.dart';
import '../services/openai_server_service.dart';

class ServerController extends GetxController {
  final HiveService _hive = Get.find<HiveService>();
  final InferenceService inference = Get.find<InferenceService>();
  final OpenAiServerService _server = OpenAiServerService();

  final isRunning = false.obs;
  final isStarting = false.obs;
  final localUrl = RxnString();
  final serverStatus = 'Server stopped'.obs;
  final lastError = RxnString();

  final useApiKey = false.obs;
  final apiKey = ''.obs;

  /// Off by default: the server only listens on this device. When on, other
  /// devices on the network can reach it and an API key is always required.
  final allowNetwork = false.obs;

  /// Android: false when battery optimization may pause the server in the
  /// background. Null where it doesn't apply.
  final batteryUnrestricted = RxnBool();

  late final TextEditingController apiKeyCtrl;
  AppLifecycleListener? _lifecycle;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static const int port = 8080;

  @override
  void onInit() {
    super.onInit();
    useApiKey.value =
        _hive.getSetting<bool>(AppConstants.keyServerUseApiKey) ?? false;
    apiKey.value = _hive.getSetting<String>(AppConstants.keyServerApiKey) ?? '';
    allowNetwork.value =
        _hive.getSetting<bool>(AppConstants.keyServerAllowNetwork) ?? false;

    apiKeyCtrl = TextEditingController(text: apiKey.value);
    unawaited(refreshBatteryStatus());
    // The battery prompt is a system screen: re-check when the user is back.
    _lifecycle = AppLifecycleListener(onResume: refreshBatteryStatus);
    if (_isAndroid) {
      LlamaCluster.onStopServerRequested = () => unawaited(stopServer());
    }
  }

  Future<void> refreshBatteryStatus() async {
    if (!_isAndroid) return;
    try {
      batteryUnrestricted.value = await LlamaCluster.isBatteryUnrestricted();
    } catch (_) {}
  }

  /// Opens Android's prompt to let the app run without battery limits.
  Future<void> requestBatteryUnrestricted() async {
    if (!_isAndroid) return;
    try {
      await LlamaCluster.requestBatteryUnrestricted();
    } catch (_) {}
  }

  void _setKeepAlive(bool on) {
    if (!_isAndroid) return;
    LlamaCluster.setServerKeepAlive(on).catchError((_) {});
  }

  bool get requiresApiKey => allowNetwork.value || useApiKey.value;

  String? get _effectiveApiKey {
    final key = apiKey.value.trim();
    return requiresApiKey && key.isNotEmpty ? key : null;
  }

  bool get hasLocalModel => inference.isModelLoaded.value;

  String get modelName => inference.loadedModelName.value.isEmpty
      ? 'No model loaded'
      : inference.loadedModelName.value;

  Future<void> toggleServer(bool enabled) async {
    if (enabled) {
      await startServer();
    } else {
      await stopServer();
    }
  }

  Future<void> startServer() async {
    if (isRunning.value || isStarting.value) return;
    lastError.value = null;
    if (!hasLocalModel) {
      lastError.value = 'Load a local GGUF model first.';
      showToast('Server not started', lastError.value!,
          tone: ToastTone.warning);
      return;
    }

    isStarting.value = true;
    serverStatus.value = 'Starting server...';
    await saveSettings();

    try {
      await _server.start(
        port: port,
        apiKey: _effectiveApiKey,
        allowNetwork: allowNetwork.value,
        onLog: (message) => serverStatus.value = message,
      );
      localUrl.value = _server.localUrl;
      isRunning.value = true;
      serverStatus.value = 'Server running';
      _setKeepAlive(true);
      if (allowNetwork.value && Get.isRegistered<ClusterService>()) {
        Get.find<ClusterService>().serving.value = true;
      }
    } catch (e) {
      lastError.value = '$e';
      serverStatus.value = 'Server failed';
      Get.find<AppLogService>().error('API server failed', details: e);
      showToast('Server failed', '$e', tone: ToastTone.error);
    } finally {
      isStarting.value = false;
    }
  }

  Future<void> stopServer() async {
    isStarting.value = false;
    await _server.stop();
    _setKeepAlive(false);
    isRunning.value = false;
    localUrl.value = null;
    serverStatus.value = 'Server stopped';
    if (Get.isRegistered<ClusterService>()) {
      Get.find<ClusterService>().serving.value = false;
    }
  }

  /// Persists settings and applies the key to a running server. A required
  /// but empty key is replaced with a generated one so auth is never
  /// silently disabled.
  Future<void> saveSettings() async {
    if (requiresApiKey && apiKey.value.trim().isEmpty) {
      _setApiKey(_newApiKey());
    }
    await _hive.setSetting(AppConstants.keyServerUseApiKey, useApiKey.value);
    await _hive.setSetting(AppConstants.keyServerApiKey, apiKey.value.trim());
    await _hive.setSetting(
        AppConstants.keyServerAllowNetwork, allowNetwork.value);
    _server.updateApiKey(_effectiveApiKey);
  }

  Future<void> setUseApiKey(bool enabled) async {
    if (!enabled && allowNetwork.value) return;
    useApiKey.value = enabled;
    await saveSettings();
  }

  Future<void> setAllowNetwork(bool enabled) async {
    allowNetwork.value = enabled;
    await saveSettings();
    if (isRunning.value) {
      // Switching between loopback and all interfaces needs a rebind.
      await stopServer();
      await startServer();
    }
  }

  void onApiKeyEdited(String value) {
    apiKey.value = value;
    // Don't push an empty key while one is required; saveSettings will
    // generate a replacement when the field is submitted.
    if (!requiresApiKey || value.trim().isNotEmpty) {
      _server.updateApiKey(_effectiveApiKey);
    }
  }

  Future<void> generateApiKey() async {
    _setApiKey(_newApiKey());
    useApiKey.value = true;
    await saveSettings();
  }

  void _setApiKey(String key) {
    apiKey.value = key;
    apiKeyCtrl.text = key;
  }

  String _newApiKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return 'onelm_${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  Future<void> copyText(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    showToast('Copied', '$label copied.', tone: ToastTone.success);
  }

  String get baseUrl => localUrl.value ?? 'http://localhost:$port';

  String get openAiBaseUrl => '$baseUrl/v1';

  /// The key clients should send, or a placeholder when none is required
  /// (OpenAI SDKs refuse an empty key).
  String get clientApiKey => requiresApiKey && apiKey.value.trim().isNotEmpty
      ? apiKey.value.trim()
      : 'not-needed';

  @override
  void onClose() {
    apiKeyCtrl.dispose();
    _lifecycle?.dispose();
    if (_isAndroid) LlamaCluster.onStopServerRequested = null;
    unawaited(stopServer());
    super.onClose();
  }
}
