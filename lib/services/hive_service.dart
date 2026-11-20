import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/constants.dart';

class HiveService extends GetxService {
  late Box _sessionsBox;
  late Box _messagesBox;
  late Box _settingsBox;

  Box get sessionsBox => _sessionsBox;
  Box get messagesBox => _messagesBox;
  Box get settingsBox => _settingsBox;

  /// Settings that hold credentials. They live in the OS secure storage
  /// (Android Keystore / iOS & macOS Keychain) instead of the plain Hive box.
  static const secretKeys = {
    AppConstants.keyOpenaiKey,
    AppConstants.keyAnthropicKey,
    AppConstants.keyGoogleKey,
    AppConstants.keyOpenRouterKey,
    AppConstants.keyCustomCloudKey,
    AppConstants.keyServerApiKey,
  };

  /// Settings of removed features (Stable Diffusion and Stability AI image
  /// generation, LiteRT, the Kimi / NVIDIA / DeepSeek cloud presets). Deleted on startup so no stale data or keys remain.
  static const _removedFeatureKeys = [
    'stability_api_key',
    'stability_model',
    'image_model_path',
    'image_model_name',
    'image_steps',
    'image_gen_force_cpu',
    'image_gen_backend',
    'image_gen_gpu_guard_mb',
    'image_gen_size',
    'image_gen_quantization',
    'litert_gpu_warning_accepted',
    'litert_gpu_load_pending',
    'litert_gpu_crash_detected',
    'last_loaded_context_size',
    'batch_mode_warning_accepted',
    'kimi_model',
    'nvidia_model',
    'deepseek_model',
    'cloud_model_cache_nvidia',
    'cloud_model_cache_time_nvidia',
    'cloud_model_cache_deepseek',
    'cloud_model_cache_time_deepseek',
  ];

  /// API keys of removed cloud presets (Kimi, NVIDIA NIM, DeepSeek; they work
  /// through the Custom API provider). Deleted from secure storage and Hive.
  static const _removedSecretKeys = [
    'kimi_api_key',
    'nvidia_api_key',
    'deepseek_api_key',
  ];

  static const _secureOpTimeout = Duration(seconds: 3);
  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// In-memory copy of the secrets, so [getSetting] can stay synchronous.
  final Map<String, String> _secretCache = {};

  /// False when the platform has no usable secure storage (tests, some
  /// desktop builds without keychain entitlements). Secrets then stay in Hive.
  bool _secureAvailable = true;

  Future<HiveService> init() async {
    _sessionsBox = await Hive.openBox(AppConstants.chatSessionsBox);
    _messagesBox = await Hive.openBox(AppConstants.chatMessagesBox);
    // The experimental task feature was removed; drop its leftover data.
    try {
      await Hive.deleteBoxFromDisk(AppConstants.tasksBox);
    } catch (_) {}
    _settingsBox = await Hive.openBox(AppConstants.settingsBox);
    // Preserve current local-server settings and purge obsolete provider data.
    // Any new server_* setting must be added here or it is wiped on launch.
    const currentServerKeys = {
      AppConstants.keyServerApiKey,
      AppConstants.keyServerUseApiKey,
      AppConstants.keyServerAllowNetwork,
    };
    final obsoleteServerKeys = _settingsBox.keys.where((key) =>
        key is String &&
        key.startsWith('server_') &&
        !currentServerKeys.contains(key));
    await _settingsBox.deleteAll(obsoleteServerKeys);
    await _settingsBox.deleteAll(_removedFeatureKeys);
    await _settingsBox.deleteAll(_removedSecretKeys);
    await _loadSecrets();
    if (_secureAvailable) {
      for (final key in _removedSecretKeys) {
        try {
          await _secure.delete(key: key).timeout(_secureOpTimeout);
        } catch (_) {}
      }
    }
    return this;
  }

  /// Loads secrets from secure storage and moves any plaintext secret left in
  /// Hive by older versions into secure storage.
  Future<void> _loadSecrets() async {
    for (final key in secretKeys) {
      try {
        final stored = await _secure.read(key: key).timeout(_secureOpTimeout);
        final legacy = _settingsBox.get(key);
        if (legacy is String && legacy.isNotEmpty) {
          // Hive copy is the newest value when present: migrate it.
          await _secure
              .write(key: key, value: legacy)
              .timeout(_secureOpTimeout);
          _secretCache[key] = legacy;
          await _settingsBox.delete(key);
        } else if (stored != null) {
          _secretCache[key] = stored;
        }
      } catch (e) {
        debugPrint('Secure storage unavailable, keeping secrets in Hive: $e');
        await _fallbackToHive();
        return;
      }
    }
  }

  // ─── Settings helpers ───────────────────────────

  /// Stops using secure storage for this run without losing values already
  /// loaded: they are written back to Hive so reads keep working.
  Future<void> _fallbackToHive() async {
    _secureAvailable = false;
    for (final entry in _secretCache.entries) {
      await _settingsBox.put(entry.key, entry.value);
    }
    _secretCache.clear();
  }

  T? getSetting<T>(String key, {T? defaultValue}) {
    if (_secureAvailable && secretKeys.contains(key)) {
      return (_secretCache[key] ?? defaultValue) as T?;
    }
    return _settingsBox.get(key, defaultValue: defaultValue) as T?;
  }

  Future<void> setSetting(String key, dynamic value) async {
    if (_secureAvailable && secretKeys.contains(key)) {
      final text = value?.toString() ?? '';
      try {
        if (text.isEmpty) {
          await _secure.delete(key: key).timeout(_secureOpTimeout);
          _secretCache.remove(key);
        } else {
          await _secure.write(key: key, value: text).timeout(_secureOpTimeout);
          _secretCache[key] = text;
        }
        await _settingsBox.delete(key);
        return;
      } catch (e) {
        debugPrint('Secure storage write failed, falling back to Hive: $e');
        await _fallbackToHive();
      }
    }
    await _settingsBox.put(key, value);
  }

  // ─── Chat Sessions ─────────────────────────────

  List<Map<dynamic, dynamic>> getAllSessions() {
    return _sessionsBox.values
        .map((v) => Map<dynamic, dynamic>.from(v))
        .toList();
  }

  Future<void> saveSession(String id, Map<String, dynamic> data) async {
    await _sessionsBox.put(id, data);
  }

  Future<void> deleteSession(String id) async {
    await _sessionsBox.delete(id);
    // Delete all messages for this session
    final keysToDelete = <dynamic>[];
    for (var key in _messagesBox.keys) {
      final msg = _messagesBox.get(key);
      if (msg is Map && msg['chatId'] == id) {
        keysToDelete.add(key);
      }
    }
    await _messagesBox.deleteAll(keysToDelete);
  }

  // ─── Chat Messages ─────────────────────────────

  List<Map<dynamic, dynamic>> getMessagesForChat(String chatId) {
    return _messagesBox.values
        .where((v) => v is Map && v['chatId'] == chatId)
        .map((v) => Map<dynamic, dynamic>.from(v))
        .toList();
  }

  Future<void> saveMessage(String id, Map<String, dynamic> data) async {
    await _messagesBox.put(id, data);
  }
}
