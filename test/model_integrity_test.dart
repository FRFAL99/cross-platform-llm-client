import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/download_native.dart' as native;
import 'package:privatelm/services/model_integrity.dart';

void main() {
  const abc =
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

  test('normalizes Hugging Face etags and rejects anything else', () {
    expect(ModelIntegrity.normalize('"$abc"'), abc);
    expect(ModelIntegrity.normalize('W/"${abc.toUpperCase()}"'), abc);
    expect(ModelIntegrity.normalize('sha256:$abc'), abc);
    // A git blob id (small non-LFS file) is not a SHA-256.
    expect(ModelIntegrity.normalize('"1f2e3d4c5b6a"'), isNull);
    expect(ModelIntegrity.normalize(null), isNull);
  });

  test('finds pinned hashes and URLs for models and projectors', () {
    const catalogue = [
      {
        'filename': 'm.gguf',
        'url': 'https://huggingface.co/a/b/resolve/main/m.gguf',
        'sha256': abc,
        'mmproj_filename': 'p.gguf',
        'mmproj_url': 'https://huggingface.co/a/b/resolve/main/p.gguf',
      },
    ];
    expect(ModelIntegrity.pinnedSha256('m.gguf', catalogue: catalogue), abc);
    expect(ModelIntegrity.pinnedSha256('p.gguf', catalogue: catalogue), isNull,
        reason: 'no mmproj_sha256 pinned');
    expect(ModelIntegrity.catalogueUrl('p.gguf', catalogue: catalogue),
        endsWith('/p.gguf'));
    expect(ModelIntegrity.pinnedSha256('other.gguf', catalogue: catalogue),
        isNull);
  });

  test('every pinned hash in the catalogue is well formed', () {
    for (final m in AppConstants.availableModels) {
      for (final key in ['sha256', 'mmproj_sha256']) {
        final v = m[key];
        if (v != null) {
          expect(ModelIntegrity.normalize(v), v, reason: '${m['name']} $key');
        }
      }
    }
  });

  test('only asks Hugging Face for a hash', () async {
    expect(await ModelIntegrity.remoteSha256('https://example.com/m.gguf'),
        isNull);
    expect(await ModelIntegrity.remoteSha256('not a url'), isNull);
  });

  test('hashes a file', () async {
    final dir = await Directory.systemTemp.createTemp('integrity');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/f.gguf')..writeAsStringSync('abc');
    expect(await native.sha256OfFile(file.path), abc);
  });

  test('older default system prompts count as the default', () {
    expect(
        AppConstants.isDefaultSystemPrompt(AppConstants.systemPrompt), isTrue);
    expect(
        AppConstants.isDefaultSystemPrompt(
            AppConstants.legacySystemPrompts.first),
        isTrue);
    expect(AppConstants.isDefaultSystemPrompt('You are a pirate.'), isFalse);
    expect(AppConstants.systemPrompt, contains('PrivateLM'));
  });
}
