import 'package:dio/dio.dart';

import '../core/constants.dart';

/// Checks downloaded model files against their SHA-256, so a corrupted or
/// swapped file is never loaded.
///
/// The expected hash comes from the catalogue when it pins one (`sha256` /
/// `mmproj_sha256`); otherwise from Hugging Face, which reports the SHA-256
/// of every large (LFS) file in the `X-Linked-Etag` header of its download
/// URL. Other hosts give no hash: those files are not verified.
class ModelIntegrity {
  ModelIntegrity._();

  static final _sha256 = RegExp(r'^[0-9a-f]{64}$');

  /// The catalogue's pinned SHA-256 for [filename] (a model or its vision
  /// projector), or null.
  static String? pinnedSha256(String filename,
      {List<Map<String, String>> catalogue = AppConstants.availableModels}) {
    for (final m in catalogue) {
      if (m['filename'] == filename) return normalize(m['sha256']);
      if (m['mmproj_filename'] == filename) {
        return normalize(m['mmproj_sha256']);
      }
    }
    return null;
  }

  /// The catalogue URL for [filename], for downloads whose URL was lost
  /// (the app restarted while the system downloader ran).
  static String? catalogueUrl(String filename,
      {List<Map<String, String>> catalogue = AppConstants.availableModels}) {
    for (final m in catalogue) {
      if (m['filename'] == filename) return m['url'];
      if (m['mmproj_filename'] == filename) return m['mmproj_url'];
    }
    return null;
  }

  /// A lowercase 64-hex SHA-256 from [value] (quotes and a `sha256:` prefix
  /// allowed), or null if it isn't one.
  static String? normalize(String? value) {
    if (value == null) return null;
    var v = value.trim().toLowerCase();
    if (v.startsWith('w/')) v = v.substring(2);
    v = v.replaceAll('"', '');
    if (v.startsWith('sha256:')) v = v.substring(7);
    return _sha256.hasMatch(v) ? v : null;
  }

  /// SHA-256 that Hugging Face publishes for [url] (from `X-Linked-Etag`),
  /// or null when the host doesn't give one or can't be reached.
  static Future<String?> remoteSha256(String url, {Dio? dio}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.host.endsWith('huggingface.co')) return null;
    final client = dio ?? Dio();
    try {
      final response = await client.head(
        url,
        options: Options(
          // The hash is on Hugging Face's own reply, before the redirect to
          // the file storage.
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      return normalize(response.headers.value('x-linked-etag'));
    } catch (_) {
      return null;
    }
  }
}

/// What checking a downloaded file found.
enum IntegrityResult {
  /// The file matches the published SHA-256.
  verified,

  /// No hash was available (not Hugging Face, or offline): not checked.
  unchecked,

  /// The file doesn't match: it was deleted.
  mismatch,
}
