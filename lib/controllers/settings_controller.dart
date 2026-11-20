import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../core/constants.dart';
import '../core/haptics.dart';
import '../core/ui.dart';
import '../services/hive_service.dart';

class SettingsController extends GetxController {
  final HiveService _hive = Get.find<HiveService>();

  // Observable settings
  final themeMode = ThemeMode.system.obs;
  final inferenceMode = 'local'.obs; // 'local' or 'cloud'
  final cloudProvider = 'openrouter'.obs;
  final openaiKey = ''.obs;
  final anthropicKey = ''.obs;
  final googleKey = ''.obs;
  final openRouterKey = ''.obs;
  final customCloudName = 'Custom API'.obs;
  final customCloudBaseUrl = ''.obs;
  final customCloudKey = ''.obs;
  final customCloudProfiles = <Map<String, String>>[].obs;
  final customCloudProfileIndex = (-1).obs;
  final openaiModel = 'gpt-5.2'.obs;
  final anthropicModel = 'claude-sonnet-4-6'.obs;
  final googleModel = 'gemini-2.5-flash'.obs;
  final openRouterModel = 'openai/gpt-4o-mini'.obs;
  final customCloudModel = ''.obs;
  final globalSystemPrompt = AppConstants.systemPrompt.obs;
  final temperature = 0.1.obs;
  final maxTokens = 512.obs;
  final contextSize = 2048.obs;
  final performanceMode = AppConstants.defaultPerformanceMode.obs;

  final fontScale = AppConstants.defaultFontScale.obs;
  final hapticsEnabled = true.obs;
  final appVersion = ''.obs;

  // Persistent text controllers for settings fields
  final openaiKeyController = TextEditingController();
  final anthropicKeyController = TextEditingController();
  final googleKeyController = TextEditingController();
  final openRouterKeyController = TextEditingController();
  final customCloudNameController = TextEditingController();
  final customCloudBaseUrlController = TextEditingController();
  final customCloudKeyController = TextEditingController();
  final globalSystemPromptController = TextEditingController();

  /// Strings that end a local model's reply (one per line in Settings).
  final stopSequences = <String>[].obs;
  final stopSequencesController = TextEditingController();

  final openaiModelController = TextEditingController();
  final anthropicModelController = TextEditingController();
  final googleModelController = TextEditingController();
  final openRouterModelController = TextEditingController();
  final customCloudModelController = TextEditingController();

  Timer? _apiKeyDebounceTimer;
  Timer? _modelDebounceTimer;

  @override
  void onInit() {
    super.onInit();
    _loadSettings();
    unawaited(_loadAppVersion());
  }

  Future<void> _loadAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      appVersion.value = packageInfo.version;
    } catch (_) {
      appVersion.value = '';
    }
  }

  @override
  void onClose() {
    openaiKeyController.dispose();
    anthropicKeyController.dispose();
    googleKeyController.dispose();
    openRouterKeyController.dispose();
    customCloudNameController.dispose();
    customCloudBaseUrlController.dispose();
    customCloudKeyController.dispose();
    globalSystemPromptController.dispose();
    stopSequencesController.dispose();
    openaiModelController.dispose();
    anthropicModelController.dispose();
    googleModelController.dispose();
    openRouterModelController.dispose();
    customCloudModelController.dispose();
    _apiKeyDebounceTimer?.cancel();
    _modelDebounceTimer?.cancel();
    super.onClose();
  }

  void _loadSettings() {
    final savedTheme = _hive.getSetting<String>('theme_mode');
    themeMode.value = _themeModeFromString(savedTheme);
    inferenceMode.value = _hive.getSetting(AppConstants.keyInferenceMode,
            defaultValue: 'local') ??
        'local';
    cloudProvider.value = _hive.getSetting(AppConstants.keyCloudProvider,
            defaultValue: 'openrouter') ??
        'openrouter';
    openaiKey.value = _hive.getSetting(AppConstants.keyOpenaiKey) ?? '';
    anthropicKey.value = _hive.getSetting(AppConstants.keyAnthropicKey) ?? '';
    googleKey.value = _hive.getSetting(AppConstants.keyGoogleKey) ?? '';
    openRouterKey.value = _hive.getSetting(AppConstants.keyOpenRouterKey) ?? '';
    customCloudName.value = _hive.getSetting(AppConstants.keyCustomCloudName,
            defaultValue: 'Custom API') ??
        'Custom API';
    customCloudBaseUrl.value =
        _hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '';
    customCloudKey.value =
        _hive.getSetting(AppConstants.keyCustomCloudKey) ?? '';
    openaiModel.value = _hive.getSetting(AppConstants.keyOpenaiModel,
            defaultValue: 'gpt-5.2') ??
        'gpt-5.2';
    anthropicModel.value = _hive.getSetting(AppConstants.keyAnthropicModel,
            defaultValue: 'claude-sonnet-4-6') ??
        'claude-sonnet-4-6';
    googleModel.value = _hive.getSetting(AppConstants.keyGoogleModel,
            defaultValue: 'gemini-2.5-flash') ??
        'gemini-2.5-flash';
    openRouterModel.value = _hive.getSetting(AppConstants.keyOpenRouterModel,
            defaultValue: 'openai/gpt-4o-mini') ??
        'openai/gpt-4o-mini';
    customCloudModel.value =
        _hive.getSetting(AppConstants.keyCustomCloudModel) ?? '';
    _loadCustomCloudProfiles();
    globalSystemPrompt.value = _hive.getSetting(
            AppConstants.keyGlobalSystemPrompt,
            defaultValue: AppConstants.systemPrompt) ??
        AppConstants.systemPrompt;
    temperature.value = _hive.getSetting(AppConstants.keyTemperature,
            defaultValue: AppConstants.defaultTemperature) ??
        AppConstants.defaultTemperature;
    maxTokens.value = _hive.getSetting(AppConstants.keyMaxTokens,
            defaultValue: AppConstants.defaultMaxTokens) ??
        AppConstants.defaultMaxTokens;
    contextSize.value = _hive.getSetting(AppConstants.keyContextSize,
            defaultValue: AppConstants.defaultContextSize) ??
        AppConstants.defaultContextSize;
    performanceMode.value = _hive.getSetting(
          AppConstants.keyPerformanceMode,
          defaultValue: AppConstants.defaultPerformanceMode,
        ) ??
        AppConstants.defaultPerformanceMode;
    fontScale.value = _hive.getSetting(AppConstants.keyFontScale,
            defaultValue: AppConstants.defaultFontScale) ??
        AppConstants.defaultFontScale;
    hapticsEnabled.value = _hive.getSetting<bool>(
            AppConstants.keyHapticsEnabled,
            defaultValue: true) ??
        true;
    Haptics.enabled = hapticsEnabled.value;

    // Sync controllers with loaded values
    openaiKeyController.text = openaiKey.value;
    anthropicKeyController.text = anthropicKey.value;
    googleKeyController.text = googleKey.value;
    openRouterKeyController.text = openRouterKey.value;
    customCloudNameController.text = customCloudName.value;
    customCloudBaseUrlController.text = customCloudBaseUrl.value;
    customCloudKeyController.text = customCloudKey.value;
    globalSystemPromptController.text = globalSystemPrompt.value;
    stopSequences.value = (_hive.getSetting<List>(AppConstants.keyStopSequences,
                defaultValue: const []) ??
            const [])
        .whereType<String>()
        .toList();
    stopSequencesController.text = stopSequences.join('\n');

    openaiModelController.text = openaiModel.value;
    anthropicModelController.text = anthropicModel.value;
    googleModelController.text = googleModel.value;
    openRouterModelController.text = openRouterModel.value;
    customCloudModelController.text = customCloudModel.value;
  }

  TextEditingController apiKeyControllerFor(String provider) {
    switch (provider) {
      case 'anthropic':
        return anthropicKeyController;
      case 'google':
        return googleKeyController;
      case 'openrouter':
        return openRouterKeyController;
      case 'custom':
        return customCloudKeyController;
      default:
        return openaiKeyController;
    }
  }

  TextEditingController modelControllerFor(String provider) {
    switch (provider) {
      case 'anthropic':
        return anthropicModelController;
      case 'google':
        return googleModelController;
      case 'openrouter':
        return openRouterModelController;
      case 'custom':
        return customCloudModelController;
      default:
        return openaiModelController;
    }
  }

  String get selectedCloudModelName {
    switch (cloudProvider.value) {
      case 'anthropic':
        return anthropicModel.value;
      case 'google':
        return googleModel.value;
      case 'openrouter':
        return openRouterModel.value;
      case 'custom':
        return customCloudModel.value;
      default:
        return openaiModel.value;
    }
  }

  Future<void> setInferenceMode(String mode) async {
    inferenceMode.value = mode;
    await _hive.setSetting(AppConstants.keyInferenceMode, mode);
  }

  Future<void> setCloudProvider(String provider) async {
    cloudProvider.value = provider;
    await _hive.setSetting(AppConstants.keyCloudProvider, provider);
  }

  Future<void> setApiKey(String provider, String key) async {
    final trimmed = key.trim();
    switch (provider) {
      case 'openai':
        openaiKey.value = trimmed;
        openaiKeyController.text = trimmed;
        await _hive.setSetting(AppConstants.keyOpenaiKey, trimmed);
        break;
      case 'anthropic':
        anthropicKey.value = trimmed;
        anthropicKeyController.text = trimmed;
        await _hive.setSetting(AppConstants.keyAnthropicKey, trimmed);
        break;
      case 'google':
        googleKey.value = trimmed;
        googleKeyController.text = trimmed;
        await _hive.setSetting(AppConstants.keyGoogleKey, trimmed);
        break;
      case 'openrouter':
        openRouterKey.value = trimmed;
        openRouterKeyController.text = trimmed;
        await _hive.setSetting(AppConstants.keyOpenRouterKey, trimmed);
        break;
      case 'custom':
        customCloudKey.value = trimmed;
        customCloudKeyController.text = trimmed;
        await _hive.setSetting(AppConstants.keyCustomCloudKey, trimmed);
        break;
    }
  }

  void debouncedSetApiKey(String provider, String key) {
    _apiKeyDebounceTimer?.cancel();
    _apiKeyDebounceTimer = Timer(const Duration(milliseconds: 800), () {
      setApiKey(provider, key);
    });
  }

  void cancelApiKeyDebounce() {
    _apiKeyDebounceTimer?.cancel();
  }

  Future<void> setCloudModel(String provider, String model) async {
    switch (provider) {
      case 'openai':
        openaiModel.value = model;
        openaiModelController.text = model;
        await _hive.setSetting(AppConstants.keyOpenaiModel, model);
        break;
      case 'anthropic':
        anthropicModel.value = model;
        anthropicModelController.text = model;
        await _hive.setSetting(AppConstants.keyAnthropicModel, model);
        break;
      case 'google':
        googleModel.value = model;
        googleModelController.text = model;
        await _hive.setSetting(AppConstants.keyGoogleModel, model);
        break;
      case 'openrouter':
        openRouterModel.value = model;
        openRouterModelController.text = model;
        await _hive.setSetting(AppConstants.keyOpenRouterModel, model);
        break;
      case 'custom':
        customCloudModel.value = model;
        customCloudModelController.text = model;
        await _hive.setSetting(AppConstants.keyCustomCloudModel, model);
        break;
    }
  }

  Future<void> setCustomCloudConfig({
    required String name,
    required String baseUrl,
    required String apiKey,
    required String model,
  }) async {
    final normalizedName = name.trim().isEmpty ? 'Custom API' : name.trim();
    final normalizedBaseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

    customCloudName.value = normalizedName;
    customCloudBaseUrl.value = normalizedBaseUrl;
    customCloudKey.value = apiKey.trim();
    customCloudModel.value = model.trim();

    final profile = <String, String>{
      'name': customCloudName.value,
      'baseUrl': customCloudBaseUrl.value,
      'apiKey': customCloudKey.value,
      'model': customCloudModel.value,
    };
    final index = customCloudProfileIndex.value;
    if (index >= 0 && index < customCloudProfiles.length) {
      customCloudProfiles[index] = profile;
    } else {
      customCloudProfiles.add(profile);
      customCloudProfileIndex.value = customCloudProfiles.length - 1;
    }

    customCloudNameController.text = customCloudName.value;
    customCloudBaseUrlController.text = customCloudBaseUrl.value;
    customCloudKeyController.text = customCloudKey.value;
    customCloudModelController.text = customCloudModel.value;

    await _hive.setSetting(
        AppConstants.keyCustomCloudName, customCloudName.value);
    await _hive.setSetting(
        AppConstants.keyCustomCloudBaseUrl, customCloudBaseUrl.value);
    await _hive.setSetting(
        AppConstants.keyCustomCloudKey, customCloudKey.value);
    await _hive.setSetting(
        AppConstants.keyCustomCloudModel, customCloudModel.value);
    await _saveCustomCloudProfiles();
  }

  Future<void> clearCustomCloudConfig() async {
    final index = customCloudProfileIndex.value;
    if (index >= 0 && index < customCloudProfiles.length) {
      customCloudProfiles.removeAt(index);
    }
    if (customCloudProfiles.isNotEmpty) {
      await selectCustomCloudProfile(
          index.clamp(0, customCloudProfiles.length - 1).toInt());
      return;
    }
    customCloudName.value = 'Custom API';
    customCloudBaseUrl.value = '';
    customCloudKey.value = '';
    customCloudModel.value = '';

    customCloudNameController.text = customCloudName.value;
    customCloudBaseUrlController.clear();
    customCloudKeyController.clear();
    customCloudModelController.clear();

    await _hive.setSetting(
        AppConstants.keyCustomCloudName, customCloudName.value);
    await _hive.setSetting(AppConstants.keyCustomCloudBaseUrl, '');
    await _hive.setSetting(AppConstants.keyCustomCloudKey, '');
    await _hive.setSetting(AppConstants.keyCustomCloudModel, '');
    customCloudProfileIndex.value = -1;
    await _saveCustomCloudProfiles();
  }

  void beginNewCustomCloudProfile() {
    customCloudProfileIndex.value = -1;
    customCloudName.value = 'Custom API';
    customCloudBaseUrl.value = '';
    customCloudKey.value = '';
    customCloudModel.value = '';
    customCloudNameController.text = customCloudName.value;
    customCloudBaseUrlController.clear();
    customCloudKeyController.clear();
    customCloudModelController.clear();
  }

  Future<void> selectCustomCloudProfile(int index) async {
    if (index < 0 || index >= customCloudProfiles.length) return;
    customCloudProfileIndex.value = index;
    final profile = customCloudProfiles[index];
    customCloudName.value = profile['name'] ?? 'Custom API';
    customCloudBaseUrl.value = profile['baseUrl'] ?? '';
    customCloudKey.value = profile['apiKey'] ?? '';
    customCloudModel.value = profile['model'] ?? '';
    customCloudNameController.text = customCloudName.value;
    customCloudBaseUrlController.text = customCloudBaseUrl.value;
    customCloudKeyController.text = customCloudKey.value;
    customCloudModelController.text = customCloudModel.value;
    await _hive.setSetting(
        AppConstants.keyCustomCloudName, customCloudName.value);
    await _hive.setSetting(
        AppConstants.keyCustomCloudBaseUrl, customCloudBaseUrl.value);
    await _hive.setSetting(
        AppConstants.keyCustomCloudKey, customCloudKey.value);
    await _hive.setSetting(
        AppConstants.keyCustomCloudModel, customCloudModel.value);
    await _hive.setSetting(AppConstants.keyCustomCloudProfileIndex, index);
  }

  void _loadCustomCloudProfiles() {
    final raw = _hive.getSetting<List>(AppConstants.keyCustomCloudProfiles);
    if (raw != null) {
      customCloudProfiles.assignAll(raw.whereType<Map>().map((profile) =>
          profile.map((key, value) =>
              MapEntry(key.toString(), value?.toString() ?? ''))));
    }
    if (customCloudProfiles.isEmpty && customCloudBaseUrl.value.isNotEmpty) {
      customCloudProfiles.add({
        'name': customCloudName.value,
        'baseUrl': customCloudBaseUrl.value,
        'apiKey': customCloudKey.value,
        'model': customCloudModel.value,
      });
    }
    if (customCloudProfiles.isEmpty) return;
    final savedIndex = _hive.getSetting<int>(
            AppConstants.keyCustomCloudProfileIndex,
            defaultValue: 0) ??
        0;
    final index = savedIndex.clamp(0, customCloudProfiles.length - 1).toInt();
    customCloudProfileIndex.value = index;
    final profile = customCloudProfiles[index];
    customCloudName.value = profile['name'] ?? 'Custom API';
    customCloudBaseUrl.value = profile['baseUrl'] ?? '';
    customCloudKey.value = profile['apiKey'] ?? '';
    customCloudModel.value = profile['model'] ?? '';
  }

  Future<void> _saveCustomCloudProfiles() async {
    await _hive.setSetting(
        AppConstants.keyCustomCloudProfiles, customCloudProfiles.toList());
    await _hive.setSetting(
        AppConstants.keyCustomCloudProfileIndex, customCloudProfileIndex.value);
  }

  /// One stop sequence per line. Escapes like `\n` are allowed so a stop
  /// string can include a newline (e.g. `\nUser:`).
  Future<void> setStopSequences(String text) async {
    final list = text
        .split('\n')
        .map((l) => l.replaceAll(r'\n', '\n').replaceAll(r'\t', '\t'))
        .where((l) => l.trim().isNotEmpty)
        .take(8)
        .toList();
    stopSequences.value = list;
    stopSequencesController.text =
        text.split('\n').where((l) => l.trim().isNotEmpty).take(8).join('\n');
    await _hive.setSetting(AppConstants.keyStopSequences, list);
    showToast(
        'Saved',
        list.isEmpty
            ? 'Stop sequences cleared.'
            : '${list.length} stop sequence(s) saved.',
        tone: ToastTone.success);
  }

  Future<void> setGlobalSystemPrompt(String prompt) async {
    final normalized =
        prompt.trim().isEmpty ? AppConstants.systemPrompt : prompt.trim();
    globalSystemPrompt.value = normalized;
    globalSystemPromptController.text = normalized;
    await _hive.setSetting(AppConstants.keyGlobalSystemPrompt, normalized);
  }

  String effectiveSystemPromptForModel(String modelName) {
    final prompt = globalSystemPrompt.value.trim();
    final hasCustomPrompt =
        prompt.isNotEmpty && prompt != AppConstants.systemPrompt;
    if (hasCustomPrompt) return prompt;
    if (AppConstants.isUncensoredModelName(modelName)) {
      return AppConstants.uncensoredSystemPrompt;
    }
    return AppConstants.systemPrompt;
  }

  void debouncedSetCloudModel(String provider, String model) {
    _modelDebounceTimer?.cancel();
    _modelDebounceTimer = Timer(const Duration(milliseconds: 800), () {
      setCloudModel(provider, model);
    });
  }

  void cancelModelDebounce() {
    _modelDebounceTimer?.cancel();
  }

  Future<void> setTemperature(double value) async {
    temperature.value = value;
    await _hive.setSetting(AppConstants.keyTemperature, value);
  }

  Future<void> setMaxTokens(int value) async {
    maxTokens.value = value;
    await _hive.setSetting(AppConstants.keyMaxTokens, value);
  }

  Future<void> setContextSize(int value) async {
    contextSize.value = value;
    await _hive.setSetting(AppConstants.keyContextSize, value);
  }

  Future<void> setPerformanceMode(String mode) async {
    final normalized = switch (mode) {
      'gpu_fast' => 'gpu_fast',
      'cpu_safe' => 'cpu_safe',
      _ => AppConstants.defaultPerformanceMode,
    };
    performanceMode.value = normalized;
    await _hive.setSetting(AppConstants.keyPerformanceMode, normalized);
  }

  Future<void> setHapticsEnabled(bool value) async {
    hapticsEnabled.value = value;
    Haptics.enabled = value;
    // A little confirmation tick when turning it on.
    Haptics.selectionClick();
    await _hive.setSetting(AppConstants.keyHapticsEnabled, value);
  }

  Future<void> setFontScale(double value) async {
    final clamped = value.clamp(0.8, 1.4);
    fontScale.value = clamped;
    await _hive.setSetting(AppConstants.keyFontScale, clamped);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await _hive.setSetting('theme_mode', mode.name);
    Get.changeThemeMode(mode);
    _updateSystemUI();
  }

  void _updateSystemUI() {
    final isDark = themeMode.value == ThemeMode.dark ||
        (themeMode.value == ThemeMode.system &&
            Get.mediaQuery.platformBrightness == Brightness.dark);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: isDark ? Colors.black : Colors.white,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
    ));
  }

  static ThemeMode _themeModeFromString(String? value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
