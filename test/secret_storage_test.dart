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
    await box.put(AppConstants.keyOpenaiKey, 'sk-legacy');
    await box.close();

    final hive = await HiveService().init();

    expect(hive.getSetting<String>(AppConstants.keyOpenaiKey), 'sk-legacy');
    expect(hive.settingsBox.containsKey(AppConstants.keyOpenaiKey), isFalse);
    expect(
      await const FlutterSecureStorage().read(key: AppConstants.keyOpenaiKey),
      'sk-legacy',
    );
  });

  test('new API keys never touch the Hive box', () async {
    final hive = await HiveService().init();

    await hive.setSetting(AppConstants.keyAnthropicKey, 'sk-ant');
    expect(hive.getSetting<String>(AppConstants.keyAnthropicKey), 'sk-ant');
    expect(hive.settingsBox.containsKey(AppConstants.keyAnthropicKey), isFalse);

    await hive.setSetting(AppConstants.keyAnthropicKey, '');
    expect(hive.getSetting<String>(AppConstants.keyAnthropicKey), isNull);
  });

  test('non-secret settings stay in Hive', () async {
    final hive = await HiveService().init();
    await hive.setSetting(AppConstants.keyTemperature, 0.5);
    expect(hive.settingsBox.get(AppConstants.keyTemperature), 0.5);
  });
}
