import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

/// Keeps chat images as files (app documents/chat_images/<messageId>.jpg)
/// instead of base64 inside the message records, so the message database
/// stays small. Not available on web, where images stay in the message.
class ChatImageStore {
  /// Where images go. Tests set it to a temp directory.
  static Directory? directoryOverride;

  static bool get isSupported => !kIsWeb;

  static Future<Directory> _dir() async {
    final dir = directoryOverride ??
        Directory(
            '${(await getApplicationDocumentsDirectory()).path}/chat_images');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Writes [bytes] for [messageId] and returns the file path.
  static Future<String> save(String messageId, Uint8List bytes) async {
    final file = File('${(await _dir()).path}/$messageId.jpg');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  static Future<void> delete(String? path) async {
    if (path == null || path.isEmpty || !isSupported) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
