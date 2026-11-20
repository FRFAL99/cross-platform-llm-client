import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/constants.dart';
import 'chat_image_store.dart';

class HiveService extends GetxService {
  late Box _sessionsBox;

  /// Messages are read on demand (a lazy box), so opening the app doesn't
  /// load every message of every chat into memory.
  late LazyBox _messagesBox;

  /// chatId -> ids of its messages, so a chat loads without scanning all
  /// messages.
  late Box _messageIndexBox;
  late Box _settingsBox;

  Box get sessionsBox => _sessionsBox;
  Box get settingsBox => _settingsBox;

  /// Bumped when the message storage layout changes; see [_migrateMessages].
  static const _messageStorageVersion = 1;

  /// Settings that hold credentials. They live in the OS secure storage
  /// (Android Keystore / iOS & macOS Keychain) instead of the plain Hive box.
  static const secretKeys = {
    AppConstants.keyServerApiKey,
    AppConstants.keyClusterWorkerCode,
    AppConstants.keyClusterPairingCodes,
  };

  /// Settings of removed features (Stable Diffusion and Stability AI image
  /// generation, LiteRT, cloud providers). Deleted on startup so no stale
  /// data or keys remain.
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
    'inference_mode',
    'cloud_provider',
    'custom_cloud_name',
    'custom_cloud_base_url',
    'custom_cloud_profiles',
    'custom_cloud_profile_index',
    'custom_cloud_model',
    'openai_model',
    'anthropic_model',
    'google_model',
    'openrouter_model',
    'kimi_model',
    'nvidia_model',
    'deepseek_model',
  ];

  /// Cached model lists of the removed cloud providers.
  static const _removedFeatureKeyPrefixes = ['cloud_model_cache_'];

  /// API keys of the removed cloud providers. Deleted from secure storage
  /// and Hive.
  static const _removedSecretKeys = [
    'openai_api_key',
    'anthropic_api_key',
    'google_api_key',
    'openrouter_api_key',
    'custom_cloud_api_key',
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
    _messagesBox = await Hive.openLazyBox(AppConstants.chatMessagesBox);
    _messageIndexBox = await Hive.openBox(AppConstants.chatMessageIndexBox);
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
    await _settingsBox.deleteAll(_settingsBox.keys.where((key) =>
        key is String && _removedFeatureKeyPrefixes.any(key.startsWith)));
    await _settingsBox.deleteAll(_removedSecretKeys);
    await _loadSecrets();
    await _migrateMessages();
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
    final ids = _messageIdsFor(id);
    for (final key in ids) {
      final msg = await _messagesBox.get(key);
      if (msg is Map) await ChatImageStore.delete(msg['imageFile'] as String?);
    }
    await _messagesBox.deleteAll(ids);
    await _messageIndexBox.delete(id);
  }

  // ─── Chat Messages ─────────────────────────────

  List<String> _messageIdsFor(String chatId) =>
      ((_messageIndexBox.get(chatId) as List?) ?? const [])
          .whereType<String>()
          .toList();

  Future<List<Map<dynamic, dynamic>>> getMessagesForChat(String chatId) async {
    final result = <Map<dynamic, dynamic>>[];
    for (final id in _messageIdsFor(chatId)) {
      final msg = await _messagesBox.get(id);
      if (msg is Map) result.add(Map<dynamic, dynamic>.from(msg));
    }
    return result;
  }

  Future<void> saveMessage(String id, Map<String, dynamic> data) async {
    await _messagesBox.put(id, data);
    final chatId = data['chatId'];
    if (chatId is! String) return;
    final ids = _messageIdsFor(chatId);
    if (!ids.contains(id)) {
      await _messageIndexBox.put(chatId, [...ids, id]);
    }
  }

  /// One-time upgrade of messages saved by older versions: builds the
  /// per-chat index and moves base64 images out of the records into files.
  /// Reads each message once, then never again at startup.
  Future<void> _migrateMessages() async {
    final version =
        _settingsBox.get(AppConstants.keyMessageStorageVersion) as int? ?? 0;
    if (version >= _messageStorageVersion) return;

    final index = <String, List<String>>{};
    for (final key in _messagesBox.keys.toList()) {
      final msg = await _messagesBox.get(key);
      if (msg is! Map || key is! String) continue;
      final chatId = msg['chatId'];
      if (chatId is String) (index[chatId] ??= []).add(key);

      final image = msg['imageBase64'];
      if (ChatImageStore.isSupported && image is String && image.isNotEmpty) {
        try {
          final path = await ChatImageStore.save(key, base64Decode(image));
          final updated = Map<dynamic, dynamic>.from(msg)
            ..remove('imageBase64')
            ..['imageFile'] = path;
          await _messagesBox.put(key, updated);
        } catch (e) {
          // Keep the image in the record; it still displays.
          debugPrint('Could not move image of message $key to a file: $e');
        }
      }
    }
    await _messageIndexBox.clear();
    await _messageIndexBox.putAll(index);
    // Reclaim the space the images and old record versions used.
    await _messagesBox.compact();
    await _settingsBox.put(
        AppConstants.keyMessageStorageVersion, _messageStorageVersion);
  }
}
