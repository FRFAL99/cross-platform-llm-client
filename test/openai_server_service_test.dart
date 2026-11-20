import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:privatelm/services/inference_service.dart';
import 'package:privatelm/services/openai_server_service_io.dart';

void main() {
  late OpenAiServerService server;
  late HttpClient client;
  const port = 18765;

  setUp(() {
    server = OpenAiServerService();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
  });

  Future<HttpClientResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final req =
        await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    req.persistentConnection = false;
    headers.forEach(req.headers.set);
    if (body != null) req.write(body);
    final res = await req.close();
    await res.drain<void>();
    return res;
  }

  /// Like [send] but returns the status, headers and body text.
  Future<({int status, HttpHeaders headers, String body})> call(
    String method,
    String path, {
    Object? json,
  }) async {
    final req =
        await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    req.persistentConnection = false;
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(json));
    }
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    return (status: res.statusCode, headers: res.headers, body: body);
  }

  /// Parses an SSE body into its JSON events (without [DONE]).
  List<Map<String, dynamic>> sseEvents(String body) => [
        for (final line in const LineSplitter().convert(body))
          if (line.startsWith('data: ') && line != 'data: [DONE]')
            jsonDecode(line.substring(6)) as Map<String, dynamic>
      ];

  test('binds to loopback only by default', () async {
    await server.start(port: port);
    expect(server.localUrl, 'http://127.0.0.1:$port');
  });

  test('network mode refuses to start without an API key', () async {
    expect(
      () => server.start(port: port, allowNetwork: true),
      throwsArgumentError,
    );
    expect(server.isRunning, isFalse);
  });

  test('enforces the API key and applies key changes live', () async {
    await server.start(port: port, apiKey: 'first');

    expect((await send('GET', '/v1/models')).statusCode, 401);
    expect(
      (await send('GET', '/health')).statusCode,
      200,
      reason: 'health check stays public',
    );

    server.updateApiKey('second');
    expect(
      (await send('GET', '/v1/server/capabilities',
              headers: {'Authorization': 'Bearer first'}))
          .statusCode,
      401,
    );
  });

  test('rejects POST bodies that are not JSON', () async {
    await server.start(port: port);
    final res = await send('POST', '/v1/chat/completions',
        headers: {'Content-Type': 'text/plain'},
        body: jsonEncode({'messages': []}));
    expect(res.statusCode, HttpStatus.unsupportedMediaType);
  });

  test('only sends CORS headers when a key is required', () async {
    await server.start(port: port);
    var res = await send('GET', '/health');
    expect(res.headers.value('access-control-allow-origin'), isNull);
    await server.stop();

    await server.start(port: port, apiKey: 'k');
    res = await send('GET', '/health');
    expect(res.headers.value('access-control-allow-origin'), '*');
  });

  group('generation', () {
    late FakeInference fake;
    const json = {'Content-Type': 'application/json'};
    String chatBody({bool stream = false, int? maxTokens}) => jsonEncode({
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ],
          if (stream) 'stream': true,
          if (maxTokens != null) 'max_tokens': maxTokens,
        });

    setUp(() async {
      fake = FakeInference();
      Get.put<InferenceService>(fake);
      await server.start(
          port: port, queueTimeout: const Duration(milliseconds: 600));
    });

    tearDown(Get.reset);

    test('passes max_tokens through to the model', () async {
      final res = await send('POST', '/v1/chat/completions',
          headers: json, body: chatBody(maxTokens: 7));
      expect(res.statusCode, 200);
      expect(fake.lastMaxTokens, 7);
    });

    test('passes OpenAI stop (string or list) through to the model', () async {
      var res = await send('POST', '/v1/chat/completions',
          headers: json,
          body: jsonEncode({
            'messages': [
              {'role': 'user', 'content': 'hi'}
            ],
            'stop': '###',
          }));
      expect(res.statusCode, 200);
      expect(fake.lastStop, ['###']);
      res = await send('POST', '/v1/completions',
          headers: json,
          body: jsonEncode({
            'prompt': 'hi',
            'stop': ['a', 'b', 7, 'c', 'd', 'e'],
          }));
      expect(res.statusCode, 200);
      expect(fake.lastStop, ['a', 'b', 'c', 'd'],
          reason: 'non-strings dropped, at most 4 like OpenAI');
    });

    test('waits for the model instead of failing while it is busy', () async {
      fake.isGenerating.value = true; // e.g. the in-app chat is answering
      final pending =
          send('POST', '/v1/chat/completions', headers: json, body: chatBody());
      await Future.delayed(const Duration(milliseconds: 250));
      fake.isGenerating.value = false;
      expect((await pending).statusCode, 200);
    });

    test('answers 429 with Retry-After when the wait times out', () async {
      fake.isGenerating.value = true;
      final res = await send('POST', '/v1/chat/completions',
          headers: json, body: chatBody());
      expect(res.statusCode, 429);
      expect(res.headers.value('retry-after'), isNotNull);
    });

    test('serves queued requests one at a time', () async {
      fake.tokensToEmit = 3;
      final results = await Future.wait([
        for (var i = 0; i < 3; i++)
          call('POST', '/v1/chat/completions', json: {
            'messages': [
              {'role': 'user', 'content': 'q$i'}
            ]
          }),
      ]);
      expect(results.map((r) => r.status), everyElement(200));
      expect(fake.maxConcurrent, 1);
    });

    test('passes temperature and top_p through and validates them', () async {
      var res = await call('POST', '/v1/chat/completions', json: {
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
        'temperature': 0.2,
        'top_p': 0.5,
      });
      expect(res.status, 200);
      expect(fake.lastTemperature, 0.2);
      expect(fake.lastTopP, 0.5);

      res = await call('POST', '/v1/chat/completions', json: {
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
        'temperature': 5,
      });
      expect(res.status, 400);
    });

    group('tool calling', () {
      final tools = [
        {
          'type': 'function',
          'function': {
            'name': 'get_weather',
            'description': 'Current weather for a city',
            'parameters': {
              'type': 'object',
              'properties': {
                'city': {'type': 'string'}
              },
              'required': ['city'],
            },
          },
        }
      ];
      const callText = 'Let me check.<tool_call>\n'
          '{"name": "get_weather", "arguments": {"city": "Rome"}}\n'
          '</tool_call>';

      test('describes the tools and returns tool_calls', () async {
        fake.reply = callText;
        final res = await call('POST', '/v1/chat/completions', json: {
          'messages': [
            {'role': 'user', 'content': 'Weather in Rome?'}
          ],
          'tools': tools,
        });
        expect(res.status, 200);
        expect(fake.lastSystemPrompt, contains('<tools>'));
        expect(fake.lastSystemPrompt, contains('get_weather'));
        final choice = (jsonDecode(res.body)['choices'] as List).first;
        expect(choice['finish_reason'], 'tool_calls');
        final message = choice['message'];
        expect(message['content'], 'Let me check.');
        final call0 = (message['tool_calls'] as List).single;
        expect(call0['type'], 'function');
        expect(call0['id'], startsWith('call_'));
        expect(call0['function']['name'], 'get_weather');
        expect(jsonDecode(call0['function']['arguments']), {'city': 'Rome'});
      });

      test('tool_choice none leaves tools out of the prompt', () async {
        fake.reply = callText;
        final res = await call('POST', '/v1/chat/completions', json: {
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ],
          'tools': tools,
          'tool_choice': 'none',
        });
        expect(res.status, 200);
        expect(fake.lastSystemPrompt, isNot(contains('<tools>')));
        final choice = (jsonDecode(res.body)['choices'] as List).first;
        expect(choice['finish_reason'], 'stop');
      });

      test('accepts tool results and earlier calls in the history', () async {
        fake.reply = 'It is sunny in Rome.';
        final res = await call('POST', '/v1/chat/completions', json: {
          'messages': [
            {'role': 'user', 'content': 'Weather in Rome?'},
            {
              'role': 'assistant',
              'content': null,
              'tool_calls': [
                {
                  'id': 'call_1',
                  'type': 'function',
                  'function': {
                    'name': 'get_weather',
                    'arguments': '{"city":"Rome"}'
                  },
                }
              ],
            },
            {
              'role': 'tool',
              'tool_call_id': 'call_1',
              'content': '{"sky":"sunny"}'
            },
          ],
          'tools': tools,
        });
        expect(res.status, 200, reason: res.body);
        expect(fake.lastPrompt, contains('<tool_response>'));
        expect(fake.lastPrompt, contains('sunny'));
        expect(fake.lastHistory!.last['role'], 'assistant');
        expect(fake.lastHistory!.last['content'], contains('<tool_call>'));
        expect(fake.lastHistory!.last['content'], contains('"city":"Rome"'));
      });

      test('streams text but never the raw call markup', () async {
        fake.reply = callText;
        final res = await call('POST', '/v1/chat/completions', json: {
          'messages': [
            {'role': 'user', 'content': 'Weather in Rome?'}
          ],
          'tools': tools,
          'stream': true,
        });
        expect(res.body, endsWith('data: [DONE]\n\n'));
        final events = sseEvents(res.body);
        final deltas = [
          for (final e in events) (e['choices'] as List).first['delta'] as Map
        ];
        final text = deltas.map((d) => d['content'] ?? '').join();
        expect(text, 'Let me check.');
        final calls = deltas.where((d) => d['tool_calls'] != null).single;
        final call0 = (calls['tool_calls'] as List).single;
        expect(call0['index'], 0);
        expect(call0['function']['name'], 'get_weather');
        expect((events.last['choices'] as List).first['finish_reason'],
            'tool_calls');
      });

      test('rejects malformed tools', () async {
        final res = await call('POST', '/v1/chat/completions', json: {
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ],
          'tools': [
            {'type': 'function'}
          ],
        });
        expect(res.status, 400);
      });
    });

    test('JSON mode instructs the model and strips code fences', () async {
      fake.reply = '```json\n{"ok": true}\n```';
      final res = await call('POST', '/v1/chat/completions', json: {
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
        'response_format': {'type': 'json_object'},
      });
      expect(res.status, 200);
      expect(fake.lastSystemPrompt, contains('valid JSON'));
      final content =
          (jsonDecode(res.body)['choices'] as List).first['message']['content'];
      expect(jsonDecode(content), {'ok': true});
    });

    test('streams a role chunk first and a finish_reason at the end', () async {
      final res = await call('POST', '/v1/chat/completions', json: {
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
        'stream': true,
      });
      final events = sseEvents(res.body);
      expect((events.first['choices'] as List).first['delta']['role'],
          'assistant');
      expect((events.last['choices'] as List).first['finish_reason'], 'stop');
      expect(res.body, endsWith('data: [DONE]\n\n'));
    });

    test('reports 503 when the generation is interrupted', () async {
      fake.tokensToEmit = 50;
      final pending =
          send('POST', '/v1/chat/completions', headers: json, body: chatBody());
      await Future.delayed(const Duration(milliseconds: 100));
      await fake.stopGeneration(); // e.g. the user started a chat reply
      expect((await pending).statusCode, HttpStatus.serviceUnavailable);
    });

    test('streams live and stops the model when the client disconnects',
        () async {
      fake.tokensToEmit = 1000;
      final req = await client.openUrl(
          'POST', Uri.parse('http://127.0.0.1:$port/v1/chat/completions'));
      req.headers.contentType = ContentType.json;
      req.write(chatBody(stream: true));
      final res = await req.close();
      final firstChunk = Completer<void>();
      final sub = res.listen((_) {
        if (!firstChunk.isCompleted) firstChunk.complete();
      });
      await firstChunk.future.timeout(const Duration(seconds: 2));
      await sub.cancel();
      client.close(force: true);
      client = HttpClient();

      // The server must notice, stop the model, and free itself up.
      for (var i = 0; i < 40 && fake.stops == 0; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(fake.stops, 1);
      await Future.delayed(const Duration(milliseconds: 100));
      fake.tokensToEmit = 1;
      final next = await send('POST', '/v1/chat/completions',
          headers: json, body: chatBody());
      expect(next.statusCode, 200, reason: 'server must not stay busy');
    });
  });
}

/// Minimal stand-in for InferenceService: tokens are emitted on a timer until
/// stopped, so tests can observe busy/stop/interrupt behaviour.
class FakeInference extends GetxService implements InferenceService {
  @override
  final isModelLoaded = true.obs;
  @override
  final isGenerating = false.obs;
  @override
  final loadedModelName = 'fake-model'.obs;
  @override
  final generationSource = ''.obs;
  @override
  final isVisionLoaded = false.obs;
  @override
  final loadedModelRuntime = 'llama'.obs;
  @override
  bool get ggufVisionLoaded => false;

  int? lastMaxTokens;
  List<String> lastStop = const [];
  double? lastTemperature;
  double? lastTopP;
  String? lastPrompt;
  String? lastSystemPrompt;
  List<Map<String, String>>? lastHistory;

  /// When set, emitted in a few chunks instead of the t0 t1 … tokens.
  String? reply;
  int _running = 0;
  int maxConcurrent = 0;
  int stops = 0;
  Duration tokenInterval = const Duration(milliseconds: 20);
  int tokensToEmit = 3;
  Completer<void>? _stopped;

  @override
  int get stopCount => stops;

  @override
  Future<String> generate({
    required String prompt,
    String? systemPrompt,
    List<Map<String, String>>? conversationHistory,
    String source = 'chat',
    String? imagePath,
    String? audioPath,
    int? maxTokens,
    List<String> stopSequences = const [],
    double? temperature,
    double? topP,
    void Function(String token)? onToken,
  }) async {
    lastMaxTokens = maxTokens;
    lastStop = stopSequences;
    lastTemperature = temperature;
    lastTopP = topP;
    lastPrompt = prompt;
    lastSystemPrompt = systemPrompt;
    lastHistory = conversationHistory;
    _running++;
    if (_running > maxConcurrent) maxConcurrent = _running;
    isGenerating.value = true;
    generationSource.value = source;
    final stopped = _stopped = Completer<void>();
    final out = StringBuffer();
    final tokens = reply == null
        ? [for (var i = 0; i < tokensToEmit; i++) 't$i ']
        : [
            for (var i = 0; i < reply!.length; i += 4)
              reply!.substring(i, i + 4 > reply!.length ? reply!.length : i + 4)
          ];
    for (final token in tokens) {
      if (stopped.isCompleted) break;
      await Future.any([Future.delayed(tokenInterval), stopped.future]);
      if (stopped.isCompleted) break;
      out.write(token);
      onToken?.call(token);
    }
    _running--;
    isGenerating.value = false;
    generationSource.value = '';
    return out.toString();
  }

  @override
  Future<void> stopGeneration() async {
    stops++;
    isGenerating.value = false;
    generationSource.value = '';
    if (_stopped != null && !_stopped!.isCompleted) _stopped!.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
