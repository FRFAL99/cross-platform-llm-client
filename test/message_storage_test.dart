import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:onelm/core/constants.dart';
import 'package:onelm/services/chat_image_store.dart';
import 'package:onelm/services/hive_service.dart';

Map<String, dynamic> msg(String id, String chatId, {String? image}) => {
      'id': id,
      'chatId': chatId,
      'role': 'user',
      'content': 'message $id',
      if (image != null) 'imageBase64': image,
      'timestamp': DateTime(2026, 1, 1).toIso8601String(),
    };

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('message_storage_test');
    Hive.init(dir.path);
    ChatImageStore.directoryOverride = Directory('${dir.path}/images');
  });

  tearDown(() async {
    ChatImageStore.directoryOverride = null;
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('loads a chat by its index and deletes it with its images', () async {
    final hive = await HiveService().init();
    await hive.saveMessage('a1', msg('a1', 'A'));
    await hive.saveMessage('b1', msg('b1', 'B'));
    await hive.saveMessage('a2', msg('a2', 'A'));
    await hive.saveMessage('a2', msg('a2', 'A')); // An update, not a new id.

    final a = await hive.getMessagesForChat('A');
    expect(a.map((m) => m['id']), ['a1', 'a2']);

    final image = await ChatImageStore.save('a1', utf8.encode('jpeg'));
    await hive.saveMessage('a1', {...msg('a1', 'A'), 'imageFile': image});
    await hive.deleteSession('A');

    expect(await hive.getMessagesForChat('A'), isEmpty);
    expect(File(image).existsSync(), isFalse);
    expect((await hive.getMessagesForChat('B')).single['id'], 'b1');
  });

  test('upgrades old messages: builds the index, moves images to files',
      () async {
    final old = await Hive.openBox(AppConstants.chatMessagesBox);
    final bytes = utf8.encode('fake jpeg bytes');
    await old.put('m1', msg('m1', 'C', image: base64Encode(bytes)));
    await old.put('m2', msg('m2', 'C'));
    await old.put('m3', msg('m3', 'D'));
    await old.close();

    final hive = await HiveService().init();

    final c = await hive.getMessagesForChat('C');
    expect(c.map((m) => m['id']).toSet(), {'m1', 'm2'});
    final withImage = c.firstWhere((m) => m['id'] == 'm1');
    expect(withImage.containsKey('imageBase64'), isFalse);
    expect(File(withImage['imageFile'] as String).readAsBytesSync(), bytes);
    expect((await hive.getMessagesForChat('D')).single['id'], 'm3');
    expect(hive.getSetting<int>(AppConstants.keyMessageStorageVersion), 1);
  });
}
