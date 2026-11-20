import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/core/third_party_licenses.dart';
import 'package:privatelm/models/ai_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every bundled license file exists and is non-empty', () {
    for (final (_, asset) in thirdPartyLicenseAssets) {
      final file = File(asset);
      expect(file.existsSync(), isTrue, reason: asset);
      expect(file.readAsStringSync().trim(), isNotEmpty, reason: asset);
    }
  });

  test('registered licenses show up in the license registry', () async {
    registerThirdPartyLicenses();
    final packages = <String>{};
    await for (final entry in LicenseRegistry.licenses) {
      packages.addAll(entry.packages);
    }
    expect(packages, containsAll(['llama.cpp', 'Inter (font)']));
  });

  test('every catalogue model states its license', () {
    for (final entry in AppConstants.availableModels) {
      expect(entry['license'], isNotEmpty, reason: entry['name']);
      expect(AiModel.fromMap(entry).license, entry['license']);
      expect(AiModel.fromMap(entry).toMap()['license'], entry['license']);
    }
  });
}
