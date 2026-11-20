import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

class ChatMessage {
  final String id;
  final String chatId;
  final String role; // 'user', 'assistant', 'system', 'cmd'
  final String content;

  /// Image bytes kept in the record. Only on web and in messages saved by
  /// older versions; elsewhere the image lives in [imageFile].
  final String? imageBase64;
  final String? imagePath;

  /// The attached image saved by [ChatImageStore].
  final String? imageFile;
  final String? fileName;
  final String? fileContent;
  final String? filePath;
  final String? fileType;
  final int? fileSize;
  final String? cmdOutput; // Result of CMD: execution
  final bool isCommand;
  final double? tokensPerSec;
  final int? thoughtDurationSeconds;
  final int? imageGenDurationMs; // Time taken to generate image locally
  final DateTime timestamp;

  // Cache decoded bytes to prevent flickering on re-build
  Uint8List? _decodedImageBytes;
  Uint8List? get decodedImageBytes {
    if (_decodedImageBytes != null) return _decodedImageBytes;
    if (imageBase64 != null && imageBase64!.isNotEmpty) {
      return _decodedImageBytes = base64Decode(imageBase64!);
    }
    if (imageFile != null && !kIsWeb) {
      try {
        return _decodedImageBytes = File(imageFile!).readAsBytesSync();
      } catch (_) {}
    }
    return null;
  }

  ChatMessage({
    required this.id,
    required this.chatId,
    required this.role,
    required this.content,
    this.imageBase64,
    this.imagePath,
    this.imageFile,
    this.fileName,
    this.fileContent,
    this.filePath,
    this.fileType,
    this.fileSize,
    this.cmdOutput,
    this.isCommand = false,
    this.tokensPerSec,
    this.thoughtDurationSeconds,
    this.imageGenDurationMs,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'chatId': chatId,
        'role': role,
        'content': content,
        'imageBase64': imageBase64,
        'imagePath': imagePath,
        if (imageFile != null) 'imageFile': imageFile,
        'fileName': fileName,
        'fileContent': fileContent,
        'filePath': filePath,
        'fileType': fileType,
        'fileSize': fileSize,
        'cmdOutput': cmdOutput,
        'isCommand': isCommand,
        'tokensPerSec': tokensPerSec,
        'thoughtDurationSeconds': thoughtDurationSeconds,
        'imageGenDurationMs': imageGenDurationMs,
        'timestamp': timestamp.toIso8601String(),
      };

  factory ChatMessage.fromMap(Map<dynamic, dynamic> map) => ChatMessage(
        id: map['id'] ?? '',
        chatId: map['chatId'] ?? '',
        role: map['role'] ?? 'user',
        content: map['content'] ?? '',
        imageBase64: map['imageBase64'],
        imagePath: map['imagePath'],
        imageFile: map['imageFile'],
        fileName: map['fileName'],
        fileContent: map['fileContent'],
        filePath: map['filePath'],
        fileType: map['fileType'],
        fileSize:
            map['fileSize'] != null ? (map['fileSize'] as num).toInt() : null,
        cmdOutput: map['cmdOutput'],
        isCommand: map['isCommand'] ?? false,
        tokensPerSec: map['tokensPerSec'] != null
            ? (map['tokensPerSec'] as num).toDouble()
            : null,
        thoughtDurationSeconds: map['thoughtDurationSeconds'] != null
            ? (map['thoughtDurationSeconds'] as num).toInt()
            : null,
        imageGenDurationMs: map['imageGenDurationMs'] != null
            ? (map['imageGenDurationMs'] as num).toInt()
            : null,
        timestamp: DateTime.tryParse(map['timestamp'] ?? '') ?? DateTime.now(),
      );
}
