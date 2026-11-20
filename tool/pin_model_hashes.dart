// Pins the SHA-256 of every catalogue download (models and vision
// projectors) in lib/core/constants.dart, using the hash Hugging Face
// publishes for each LFS file (X-Linked-Etag). Entries that already have a
// hash are checked, not changed. Run from the repo root (needs network):
//   dart --packages=.dart_tool/package_config.json tool/pin_model_hashes.dart
// Add --check to only report, without writing.
import 'dart:io';

import 'package:onelm/core/constants.dart';
import 'package:onelm/services/model_integrity.dart';

Future<String?> remoteHash(HttpClient client, String url) async {
  final request = await client.headUrl(Uri.parse(url));
  request.followRedirects = false;
  final response = await request.close();
  await response.drain<void>();
  return ModelIntegrity.normalize(response.headers.value('x-linked-etag'));
}

Future<void> main(List<String> args) async {
  final check = args.contains('--check');
  const path = 'lib/core/constants.dart';
  var source = File(path).readAsStringSync();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  var failures = 0;

  for (final m in AppConstants.availableModels) {
    for (final (urlKey, hashKey) in [
      ('url', 'sha256'),
      ('mmproj_url', 'mmproj_sha256')
    ]) {
      final url = m[urlKey];
      if (url == null || url.isEmpty) continue;
      String? hash;
      try {
        hash = await remoteHash(client, url);
      } catch (e) {
        stderr.writeln('FAIL  ${m['name']} ($urlKey): $e');
        failures++;
        continue;
      }
      if (hash == null) {
        stderr.writeln('FAIL  ${m['name']} ($urlKey): no hash published');
        failures++;
        continue;
      }
      final pinned = m[hashKey];
      if (pinned != null) {
        final ok = pinned == hash;
        if (!ok) failures++;
        stdout.writeln('${ok ? 'OK   ' : 'DIFF '} ${m['name']} ($hashKey)'
            '${ok ? '' : ': pinned $pinned, published $hash'}');
        continue;
      }
      stdout.writeln('NEW   ${m['name']} ($hashKey) $hash');
      // Insert the hash right after the URL entry.
      final at = source.indexOf("'$url',");
      if (at < 0) {
        stderr.writeln('FAIL  ${m['name']}: URL not found in $path');
        failures++;
        continue;
      }
      final end = at + url.length + 3;
      source =
          '${source.substring(0, end)}\n      \'$hashKey\': \'$hash\',${source.substring(end)}';
    }
  }
  client.close();
  if (!check) File(path).writeAsStringSync(source);
  if (failures > 0) {
    stderr.writeln('$failures problem(s)');
    exitCode = 1;
  }
}
