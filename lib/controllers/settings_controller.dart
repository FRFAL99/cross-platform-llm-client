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
  final globalSystemPrompt = AppConstants.systemPrompt.obs;
  final temperature = 0.1.obs;
  final maxTokens = 512.obs;
  final contextSize = 2048.obs;
  final performanceMode = AppConstants.defaultPerformanceMode.obs;

  final fontScale = AppConstants.defaultFontScale.obs;
  final hapticsEnabled = true.obs;
  final summarizeHistory = true.obs;
  final appVersion = ''.obs;

  // Persistent text controllers for settings fields
  final globalSystemPromptController = TextEditingController();

  /// Strings that end a local model's reply (one per line in Settings).
  final stopSequences = <String>[].obs;
  final stopSequencesController = TextEditingController();

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
    globalSystemPromptController.dispose();
    stopSequencesController.dispose();
    super.onClose();
  }

  void _loadSettings() {
    final savedTheme = _hive.getSetting<String>('theme_mode');
    themeMode.value = _themeModeFromString(savedTheme);
    final savedPrompt = _hive.getSetting<String>(
            AppConstants.keyGlobalSystemPrompt,
            defaultValue: AppConstants.systemPrompt) ??
        AppConstants.systemPrompt;
    globalSystemPrompt.value = AppConstants.isDefaultSystemPrompt(savedPrompt)
        ? AppConstants.systemPrompt
        : savedPrompt;
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
    summarizeHistory.value = _hive.getSetting<bool>(
            AppConstants.keySummarizeHistory,
            defaultValue: true) ??
        true;

    // Sync controllers with loaded values
    globalSystemPromptController.text = globalSystemPrompt.value;
    stopSequences.value = (_hive.getSetting<List>(AppConstants.keyStopSequences,
                defaultValue: const []) ??
            const [])
        .whereType<String>()
        .toList();
    stopSequencesController.text = stopSequences.join('\n');
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

  /// The user's system prompt, or the default for [modelName]. Uncensored
  /// models get their own default only when [forUncensored] is set (the
  /// chat): API clients get the same default whatever the file is called.
  String effectiveSystemPromptForModel(String modelName,
      {bool forUncensored = true}) {
    final prompt = globalSystemPrompt.value.trim();
    if (!AppConstants.isDefaultSystemPrompt(prompt)) return prompt;
    if (forUncensored && AppConstants.isUncensoredModelName(modelName)) {
      return AppConstants.uncensoredSystemPrompt;
    }
    return AppConstants.systemPrompt;
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

  Future<void> setSummarizeHistory(bool value) async {
    summarizeHistory.value = value;
    await _hive.setSetting(AppConstants.keySummarizeHistory, value);
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
