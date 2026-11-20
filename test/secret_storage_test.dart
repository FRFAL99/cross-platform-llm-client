import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/hive_service.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('secret_storage_test');
    Hive.init(dir.path);
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('plaintext API keys in Hive are moved to secure storage', () async {
    final box = await Hive.openBox(AppConstants.settingsBox);
    await box.put(AppConstants.keyServerApiKey, 'aichat_legacy');
    await box.close();

    final hive = await HiveService().init();

    expect(
        hive.getSetting<String>(AppConstants.keyServerApiKey), 'aichat_legacy');
    expect(hive.settingsBox.containsKey(AppConstants.keyServerApiKey), isFalse);
    expect(
      await const FlutterSecureStorage()
          .read(key: AppConstants.keyServerApiKey),
      'aichat_legacy',
    );
  });

  test('new API keys never touch the Hive box', () async {
    final hive = await HiveService().init();

    await hive.setSetting(AppConstants.keyServerApiKey, 'aichat_new');
    expect(hive.getSetting<String>(AppConstants.keyServerApiKey), 'aichat_new');
    expect(hive.settingsBox.containsKey(AppConstants.keyServerApiKey), isFalse);

    await hive.setSetting(AppConstants.keyServerApiKey, '');
    expect(hive.getSetting<String>(AppConstants.keyServerApiKey), isNull);
  });

  test('API keys of removed cloud providers are deleted', () async {
    final box = await Hive.openBox(AppConstants.settingsBox);
    await box.put('openai_api_key', 'sk-old');
    await box.put('cloud_model_cache_openai', ['gpt']);
    await box.close();
    FlutterSecureStorage.setMockInitialValues({'anthropic_api_key': 'sk-ant'});

    final hive = await HiveService().init();

    expect(hive.settingsBox.containsKey('openai_api_key'), isFalse);
    expect(hive.settingsBox.containsKey('cloud_model_cache_openai'), isFalse);
    expect(await const FlutterSecureStorage().read(key: 'anthropic_api_key'),
        isNull);
  });

  test('non-secret settings stay in Hive', () async {
    final hive = await HiveService().init();
    await hive.setSetting(AppConstants.keyTemperature, 0.5);
    expect(hive.settingsBox.get(AppConstants.keyTemperature), 0.5);
  });
}
