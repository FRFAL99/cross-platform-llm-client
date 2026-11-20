import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/app_log_service.dart';
import 'package:privatelm/services/cloud_service.dart';
import 'package:privatelm/services/hive_service.dart';

String _chunk(String token, {String? finish}) => 'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': token},
              'finish_reason': finish,
            }
          ]
        })}\n\n';

void main() {
  late Directory dir;
  late HttpServer server;
  late CloudService cloud;
  // What the fake provider streams back for the next request.
  late Future<void> Function(HttpResponse res) respond;
  // The last request the fake provider received.
  late Uri lastUri;
  late Map lastBody;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cloud_test');
    Hive.init(dir.path);
    final hive = await HiveService().init();
    Get.put(hive);
    Get.put(AppLogService());

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      lastUri = req.uri;
      lastBody = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      await respond(req.response);
    });

    await hive.setSetting(AppConstants.keyCloudProvider, 'custom');
    await hive.setSetting(
        AppConstants.keyCustomCloudBaseUrl, 'http://127.0.0.1:${server.port}');
    await hive.setSetting(AppConstants.keyCustomCloudKey, 'test-key');
    await hive.setSetting(AppConstants.keyCustomCloudModel, 'test-model');
    cloud = CloudService();
  });

  tearDown(() async {
    CloudService.streamIdleTimeout = const Duration(seconds: 60);
    CloudService.anthropicEndpoint = AppConstants.anthropicEndpoint;
    CloudService.googleEndpoint = AppConstants.googleEndpoint;
    await server.close(force: true);
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  Future<String> send(List<String> tokens) => cloud.sendMessage(
        messages: [
          {'role': 'user', 'content': 'hi'}
        ],
        onToken: tokens.add,
      );

  test('a complete stream returns the text', () async {
    respond = (res) async {
      res.write(_chunk('Hello '));
      res.write(_chunk('world', finish: 'stop'));
      res.write('data: [DONE]\n\n');
      await res.close();
    };
    final tokens = <String>[];
    expect(await send(tokens), 'Hello world');
    expect(tokens.join(), 'Hello world');
  });

  test('an error event mid-stream is reported, not shown as a reply', () async {
    respond = (res) async {
      res.write(_chunk('Partial '));
      res.write('data: ${jsonEncode({
            'error': {'message': 'Rate limit exceeded'}
          })}\n\n');
      await res.close();
    };
    final result = await send([]);
    expect(result, startsWith('Partial'));
    expect(result, contains('Rate limit exceeded'));
  });

  test('an error event before any text is an ERROR', () async {
    respond = (res) async {
      res.write('data: ${jsonEncode({'error': 'upstream failed'})}\n\n');
      await res.close();
    };
    expect(await send([]), startsWith('ERROR:'));
  });

  test('a stream that ends without [DONE] is marked as cut off', () async {
    respond = (res) async {
      res.write(_chunk('Half an answer'));
      await res.close();
    };
    final result = await send([]);
    expect(result, startsWith('Half an answer'));
    expect(result, contains('cut off'));
  });

  test('an empty stream is an ERROR, not a blank reply', () async {
    respond = (res) async {
      res.write('data: [DONE]\n\n');
      await res.close();
    };
    expect(await send([]), startsWith('ERROR:'));
  });

  test('a stalled stream times out instead of hanging', () async {
    CloudService.streamIdleTimeout = const Duration(milliseconds: 300);
    respond = (res) async {
      res.write(_chunk('Start'));
      await res.flush(); // ...then nothing more
      await Future.delayed(const Duration(seconds: 5));
    };
    final result = await send([]).timeout(const Duration(seconds: 3));
    expect(result, startsWith('ERROR:'));
    expect(result, contains("didn't respond in time"));
  });

  test('cancel() aborts the stream in progress', () async {
    respond = (res) async {
      res.write(_chunk('Start'));
      await res.flush();
      await Future.delayed(const Duration(seconds: 5));
    };
    final pending = send([]);
    await Future.delayed(const Duration(milliseconds: 200));
    cloud.cancel();
    expect(await pending.timeout(const Duration(seconds: 2)),
        startsWith('ERROR:'));
  });

  group('Anthropic streaming', () {
    setUp(() async {
      final hive = Get.find<HiveService>();
      await hive.setSetting(AppConstants.keyCloudProvider, 'anthropic');
      await hive.setSetting(AppConstants.keyAnthropicKey, 'test-key');
      CloudService.anthropicEndpoint =
          'http://127.0.0.1:${server.port}/v1/messages';
    });

    String event(Map data) =>
        'event: ${data['type']}\ndata: ${jsonEncode(data)}\n\n';
    Map delta(String text) => {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': text},
        };

    test('streams text deltas and sends the system prompt apart', () async {
      respond = (res) async {
        res.write(event({'type': 'message_start', 'message': {}}));
        res.write(event(delta('Ciao ')));
        res.write(event(delta('mondo')));
        res.write(event({'type': 'message_stop'}));
        await res.close();
      };
      final tokens = <String>[];
      final result = await cloud.sendMessage(
        messages: [
          {'role': 'system', 'content': 'Be brief'},
          {'role': 'user', 'content': 'hi'},
        ],
        onToken: tokens.add,
      );
      expect(result, 'Ciao mondo');
      expect(tokens, ['Ciao ', 'mondo']);
      expect(lastBody['stream'], true);
      expect(lastBody['system'], 'Be brief');
      expect(lastBody['messages'], [
        {'role': 'user', 'content': 'hi'}
      ]);
    });

    test('an error event is reported', () async {
      respond = (res) async {
        res.write(event(delta('Partial')));
        res.write(event({
          'type': 'error',
          'error': {'type': 'overloaded_error', 'message': 'Overloaded'}
        }));
        await res.close();
      };
      final result = await send([]);
      expect(result, startsWith('Partial'));
      expect(result, contains('Overloaded'));
    });

    test('a stream without message_stop is marked as cut off', () async {
      respond = (res) async {
        res.write(event(delta('Half')));
        await res.close();
      };
      expect(await send([]), contains('cut off'));
    });
  });

  group('Gemini streaming', () {
    setUp(() async {
      final hive = Get.find<HiveService>();
      await hive.setSetting(AppConstants.keyCloudProvider, 'google');
      await hive.setSetting(AppConstants.keyGoogleKey, 'test-key');
      await hive.setSetting(AppConstants.keyGoogleModel, 'gemini-test');
      CloudService.googleEndpoint =
          'http://127.0.0.1:${server.port}/v1beta/models';
    });

    String chunk(String text, {String? finish}) => 'data: ${jsonEncode({
              'candidates': [
                {
                  'content': {
                    'role': 'model',
                    'parts': [
                      {'text': text}
                    ]
                  },
                  if (finish != null) 'finishReason': finish,
                }
              ]
            })}\r\n\r\n';

    test('streams text and sends proper roles', () async {
      respond = (res) async {
        res.write(chunk('Ciao '));
        res.write(chunk('mondo', finish: 'STOP'));
        await res.close();
      };
      final tokens = <String>[];
      final result = await cloud.sendMessage(
        messages: [
          {'role': 'system', 'content': 'Be brief'},
          {'role': 'user', 'content': 'hi'},
          {'role': 'assistant', 'content': 'hello'},
          {'role': 'user', 'content': 'how are you?'},
        ],
        onToken: tokens.add,
      );
      expect(result, 'Ciao mondo');
      expect(tokens, ['Ciao ', 'mondo']);
      expect(lastUri.path, '/v1beta/models/gemini-test:streamGenerateContent');
      expect(lastUri.queryParameters['alt'], 'sse');
      expect(lastBody['systemInstruction'], {
        'parts': [
          {'text': 'Be brief'}
        ]
      });
      expect((lastBody['contents'] as List).map((c) => c['role']),
          ['user', 'model', 'user']);
    });

    test('a stream without finishReason is marked as cut off', () async {
      respond = (res) async {
        res.write(chunk('Half'));
        await res.close();
      };
      expect(await send([]), contains('cut off'));
    });
  });
}
