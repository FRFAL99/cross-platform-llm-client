import 'dart:async';
import 'dart:convert';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import 'hive_service.dart';
import 'app_log_service.dart';

/// Cloud API service supporting native and OpenAI-compatible providers.
class CloudService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  String get _provider =>
      _hive.getSetting(AppConstants.keyCloudProvider,
          defaultValue: 'openrouter') ??
      'openrouter';

  String get _apiKey {
    switch (_provider) {
      case 'anthropic':
        return _hive.getSetting(AppConstants.keyAnthropicKey) ?? '';
      case 'google':
        return _hive.getSetting(AppConstants.keyGoogleKey) ?? '';
      case 'openrouter':
        return _hive.getSetting(AppConstants.keyOpenRouterKey) ?? '';
      case 'custom':
        return _hive.getSetting(AppConstants.keyCustomCloudKey) ?? '';
      default:
        return _hive.getSetting(AppConstants.keyOpenaiKey) ?? '';
    }
  }

  String get _model {
    switch (_provider) {
      case 'anthropic':
        return _hive.getSetting(AppConstants.keyAnthropicModel) ??
            'claude-sonnet-4-6';
      case 'google':
        return _hive.getSetting(AppConstants.keyGoogleModel) ??
            'gemini-2.5-flash';
      case 'openrouter':
        return _hive.getSetting(AppConstants.keyOpenRouterModel) ??
            'openai/gpt-4o-mini';
      case 'custom':
        return _hive.getSetting(AppConstants.keyCustomCloudModel) ?? '';
      default:
        return _hive.getSetting(AppConstants.keyOpenaiModel) ?? 'gpt-5.2';
    }
  }

  bool get isConfigured {
    if (_provider == 'custom') {
      final baseUrl =
          _hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '';
      return _apiKey.isNotEmpty && _model.isNotEmpty && baseUrl.isNotEmpty;
    }
    return _apiKey.isNotEmpty;
  }

  http.Client? _activeStreamClient;

  // Without timeouts a stalled connection (captive Wi-Fi, a hung custom
  // endpoint) leaves the chat loading forever.
  static const _connectTimeout = Duration(seconds: 30);
  static const _responseTimeout = Duration(seconds: 120);

  /// Max gap between streamed chunks. Not const so tests can shorten it.
  static Duration streamIdleTimeout = const Duration(seconds: 60);

  /// Native API endpoints. Not const so tests can point them at a fake server.
  static String anthropicEndpoint = AppConstants.anthropicEndpoint;
  static String googleEndpoint = AppConstants.googleEndpoint;

  Future<http.Response> _post(Uri url,
          {Map<String, String>? headers, Object? body}) =>
      http.post(url, headers: headers, body: body).timeout(_responseTimeout);

  /// Aborts the streaming response in progress, if any. Closing the client
  /// drops the connection, so the provider stops generating (and billing).
  void cancel() {
    final client = _activeStreamClient;
    _activeStreamClient = null;
    client?.close();
  }

  /// Send a message to the cloud API. Returns the response text.
  /// [messages] is a list of {role, content} maps forming the conversation.
  /// [imageBase64] is optional for multimodal requests.
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
    void Function(String token)? onToken,
  }) async {
    if (!isConfigured) {
      return 'ERROR: No API key configured for $_provider. Go to Settings.';
    }

    try {
      if (onToken != null && _provider == 'anthropic') {
        return await _streamAnthropic(
            messages, imageBase64, temperature, maxTokens, onToken);
      }
      if (onToken != null && _provider == 'google') {
        return await _streamGoogle(
            messages, imageBase64, temperature, maxTokens, onToken);
      }
      if (onToken != null && _supportsStreaming) {
        return await _streamOpenAICompatible(
          endpoint: _openAICompatibleEndpoint,
          providerLabel: _providerLabel,
          messages: messages,
          imageBase64: imageBase64,
          temperature: temperature,
          maxTokens: maxTokens,
          onToken: onToken,
        );
      }

      switch (_provider) {
        case 'anthropic':
          return await _sendAnthropic(
              messages, imageBase64, temperature, maxTokens);
        case 'google':
          return await _sendGoogle(
              messages, imageBase64, temperature, maxTokens);
        case 'openrouter':
          return await _sendOpenRouter(
              messages, imageBase64, temperature, maxTokens);
        case 'custom':
          return await _sendCustomOpenAICompatible(
              messages, imageBase64, temperature, maxTokens);
        default:
          return await _sendOpenAI(
              messages, imageBase64, temperature, maxTokens);
      }
    } on TimeoutException {
      Get.find<AppLogService>().warning('Cloud API request timed out');
      return "ERROR: $_providerLabel didn't respond in time. Check your "
          'connection and try again.';
    } catch (e) {
      Get.find<AppLogService>().error('Cloud API request failed', details: e);
      return 'ERROR: Cloud API request failed — $e';
    }
  }

  bool get _supportsStreaming =>
      _provider == 'openai' ||
      _provider == 'openrouter' ||
      _provider == 'custom';

  String get _openAICompatibleEndpoint {
    switch (_provider) {
      case 'openrouter':
        return '${AppConstants.openRouterEndpoint}/chat/completions';
      case 'custom':
        final baseUrl =
            (_hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '')
                .toString()
                .replaceAll(RegExp(r'/+$'), '');
        return '$baseUrl/chat/completions';
      default:
        return AppConstants.openaiEndpoint;
    }
  }

  String get _providerLabel {
    switch (_provider) {
      case 'openrouter':
        return 'OpenRouter';
      case 'custom':
        return _hive.getSetting(AppConstants.keyCustomCloudName) ??
            'Custom API';
      default:
        return 'OpenAI';
    }
  }

  // ─── OpenAI ─────────────────────────────────────

  Future<String> _sendOpenAI(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': msg['content']},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'}
            },
          ],
        });
      } else {
        apiMessages.add({'role': msg['role'], 'content': msg['content']});
      }
    }

    final response = await _post(
      Uri.parse(AppConstants.openaiEndpoint),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return 'ERROR: OpenAI returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  // ─── Anthropic ──────────────────────────────────

  Map<String, String> get _anthropicHeaders => {
        'x-api-key': _apiKey,
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json',
      };

  Map<String, dynamic> _anthropicBody(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens, {
    bool stream = false,
  }) {
    String? systemMsg;
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'system') {
        systemMsg = msg['content'];
        continue;
      }

      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/jpeg',
                'data': imageBase64,
              }
            },
            {'type': 'text', 'text': msg['content']},
          ],
        });
      } else {
        apiMessages.add({
          'role': msg['role'],
          'content': msg['content'],
        });
      }
    }

    return {
      'model': _model,
      'messages': apiMessages,
      'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      'temperature': temperature ?? AppConstants.defaultTemperature,
      if (systemMsg != null) 'system': systemMsg,
      if (stream) 'stream': true,
    };
  }

  Future<String> _sendAnthropic(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final response = await _post(
      Uri.parse(anthropicEndpoint),
      headers: _anthropicHeaders,
      body: jsonEncode(
          _anthropicBody(messages, imageBase64, temperature, maxTokens)),
    );

    if (response.statusCode != 200) {
      return 'ERROR: Anthropic returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    final content = data['content'] as List;
    return content.isNotEmpty ? content[0]['text'] ?? '' : '';
  }

  /// Messages API with `stream: true`: text arrives in content_block_delta
  /// events and message_stop ends a complete reply.
  Future<String> _streamAnthropic(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
    void Function(String token) onToken,
  ) {
    final request = http.Request('POST', Uri.parse(anthropicEndpoint));
    request.headers
        .addAll({..._anthropicHeaders, 'Accept': 'text/event-stream'});
    request.body = jsonEncode(_anthropicBody(
        messages, imageBase64, temperature, maxTokens,
        stream: true));
    return _streamSse(
      request: request,
      providerLabel: 'Anthropic',
      onToken: onToken,
      parse: (data) {
        switch (data['type']) {
          case 'content_block_delta':
            final delta = data['delta'];
            return (
              token: delta is Map && delta['type'] == 'text_delta'
                  ? delta['text']?.toString()
                  : null,
              finished: false,
              error: null,
            );
          case 'message_stop':
            return (token: null, finished: true, error: null);
          case 'error':
            final error = data['error'];
            return (
              token: null,
              finished: false,
              error: error is Map ? '${error['message'] ?? error}' : '$error',
            );
          default:
            return (token: null, finished: false, error: null);
        }
      },
    );
  }

  // ─── Google Gemini ──────────────────────────────

  /// Gemini wants roles "user" and "model", with the system prompt apart.
  Map<String, dynamic> _googleBody(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) {
    final system = <String>[];
    final contents = <Map<String, dynamic>>[];
    for (final msg in messages) {
      final text = msg['content'] ?? '';
      if (msg['role'] == 'system') {
        system.add(text);
        continue;
      }
      final role = msg['role'] == 'assistant' ? 'model' : 'user';
      final parts = <Map<String, dynamic>>[
        {'text': text}
      ];
      if (imageBase64 != null && msg == messages.last) {
        parts.add({
          'inline_data': {'mime_type': 'image/jpeg', 'data': imageBase64}
        });
      }
      // Gemini rejects two turns in a row from the same role: merge them.
      if (contents.isNotEmpty && contents.last['role'] == role) {
        (contents.last['parts'] as List).addAll(parts);
      } else {
        contents.add({'role': role, 'parts': parts});
      }
    }
    return {
      if (system.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': system.join('\n\n')}
          ]
        },
      'contents': contents,
      'generationConfig': {
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'maxOutputTokens': maxTokens ?? AppConstants.defaultMaxTokens,
      },
    };
  }

  // The key goes in a header, not the URL, so it can't leak via exception
  // messages (http's ClientException includes the full URI).
  Map<String, String> get _googleHeaders => {
        'Content-Type': 'application/json',
        'x-goog-api-key': _apiKey,
      };

  Future<String> _sendGoogle(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final response = await _post(
      Uri.parse('$googleEndpoint/$_model:generateContent'),
      headers: _googleHeaders,
      body: jsonEncode(
          _googleBody(messages, imageBase64, temperature, maxTokens)),
    );

    if (response.statusCode != 200) {
      return 'ERROR: Google returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    return _googleText(data) ?? '';
  }

  static String? _googleText(Map data) {
    final candidates = data['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final content =
        candidates.first is Map ? candidates.first['content'] : null;
    final parts = content is Map ? content['parts'] : null;
    if (parts is! List) return null;
    return parts.map((p) => p is Map ? (p['text'] ?? '') : '').join('');
  }

  /// streamGenerateContent with alt=sse: each event carries the next text
  /// and the last one a finishReason.
  Future<String> _streamGoogle(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
    void Function(String token) onToken,
  ) {
    final request = http.Request('POST',
        Uri.parse('$googleEndpoint/$_model:streamGenerateContent?alt=sse'));
    request.headers.addAll({..._googleHeaders, 'Accept': 'text/event-stream'});
    request.body =
        jsonEncode(_googleBody(messages, imageBase64, temperature, maxTokens));
    return _streamSse(
      request: request,
      providerLabel: 'Google',
      onToken: onToken,
      parse: (data) {
        final error = data['error'];
        if (error != null) {
          return (
            token: null,
            finished: false,
            error: error is Map ? '${error['message'] ?? error}' : '$error',
          );
        }
        final candidates = data['candidates'];
        final first = candidates is List && candidates.isNotEmpty
            ? candidates.first
            : null;
        return (
          token: _googleText(data),
          finished: first is Map && first['finishReason'] != null,
          error: null,
        );
      },
    );
  }

  Future<String> _sendOpenRouter(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    return _sendOpenAICompatible(
      endpoint: '${AppConstants.openRouterEndpoint}/chat/completions',
      providerLabel: 'OpenRouter',
      messages: messages,
      imageBase64: imageBase64,
      temperature: temperature,
      maxTokens: maxTokens,
    );
  }

  Future<String> _sendCustomOpenAICompatible(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final baseUrl = (_hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '')
        .toString()
        .replaceAll(RegExp(r'/+$'), '');
    return _sendOpenAICompatible(
      endpoint: '$baseUrl/chat/completions',
      providerLabel:
          _hive.getSetting(AppConstants.keyCustomCloudName) ?? 'Custom API',
      messages: messages,
      imageBase64: imageBase64,
      temperature: temperature,
      maxTokens: maxTokens,
    );
  }

  Future<String> _sendOpenAICompatible({
    required String endpoint,
    required String providerLabel,
    required List<Map<String, String>> messages,
    required String? imageBase64,
    required double? temperature,
    required int? maxTokens,
    Map<String, String> extraHeaders = const {},
  }) async {
    final apiMessages = <Map<String, dynamic>>[];

    apiMessages.addAll(_buildOpenAICompatibleMessages(messages, imageBase64));

    final response = await _post(
      Uri.parse(endpoint),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
        ...extraHeaders,
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return 'ERROR: $providerLabel returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  Future<String> _streamOpenAICompatible({
    required String endpoint,
    required String providerLabel,
    required List<Map<String, String>> messages,
    required String? imageBase64,
    required double? temperature,
    required int? maxTokens,
    required void Function(String token) onToken,
    Map<String, String> extraHeaders = const {},
  }) async {
    final request = http.Request('POST', Uri.parse(endpoint));
    request.headers.addAll({
      'Authorization': 'Bearer $_apiKey',
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
      ...extraHeaders,
    });
    request.body = jsonEncode({
      'model': _model,
      'messages': _buildOpenAICompatibleMessages(messages, imageBase64),
      'temperature': temperature ?? AppConstants.defaultTemperature,
      'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      'stream': true,
    });

    return _streamSse(
      request: request,
      providerLabel: providerLabel,
      onToken: onToken,
      parse: (data) {
        final error = data['error'];
        if (error != null) {
          return (
            token: null,
            finished: false,
            error: error is Map
                ? '${error['message'] ?? error['code'] ?? error}'
                : '$error',
          );
        }
        final choices = data['choices'];
        final choice =
            choices is List && choices.isNotEmpty ? choices.first : null;
        if (choice is! Map) return (token: null, finished: false, error: null);
        final delta = choice['delta'];
        return (
          token: delta is Map ? delta['content']?.toString() : null,
          finished: choice['finish_reason'] != null,
          error: null,
        );
      },
    );
  }

  /// Sends [request] and reads a server-sent events stream. [parse] turns
  /// each JSON event into text, an end marker or an error.
  Future<String> _streamSse({
    required http.Request request,
    required String providerLabel,
    required void Function(String token) onToken,
    required ({String? token, bool finished, String? error}) Function(Map data)
        parse,
  }) async {
    final client = http.Client();
    _activeStreamClient = client;
    try {
      final response = await client.send(request).timeout(_connectTimeout);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        return 'ERROR: $providerLabel returned ${response.statusCode} — $body';
      }

      final buffer = StringBuffer();
      final lines = response.stream
          .timeout(streamIdleTimeout)
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      // Providers can fail after the 200 (rate limits, moderation, upstream
      // errors) by sending an error event, or just drop the connection. Track
      // both so they aren't shown as a normal, complete reply.
      var finished = false;
      String? streamError;

      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;

        final payload = trimmed.substring(5).trim();
        if (payload == '[DONE]') {
          finished = true;
          break;
        }

        Map? data;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map) data = decoded;
        } catch (_) {
          continue; // Malformed keep-alive chunk.
        }
        if (data == null) continue;

        final event = parse(data);
        if (event.error != null) {
          streamError = event.error;
          break;
        }
        final token = event.token;
        if (token != null && token.isNotEmpty) {
          buffer.write(token);
          onToken(token);
        }
        if (event.finished) finished = true;
      }

      final text = buffer.toString();
      if (streamError != null) {
        return text.isEmpty
            ? 'ERROR: $providerLabel returned an error — $streamError'
            : '$text\n\n⚠️ $providerLabel stopped with an error: $streamError';
      }
      if (text.isEmpty) {
        return 'ERROR: $providerLabel returned an empty response.';
      }
      if (!finished) {
        return '$text\n\n⚠️ The response was cut off before it finished.';
      }
      return text;
    } finally {
      if (identical(_activeStreamClient, client)) _activeStreamClient = null;
      client.close();
    }
  }

  List<Map<String, dynamic>> _buildOpenAICompatibleMessages(
    List<Map<String, String>> messages,
    String? imageBase64,
  ) {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': msg['content']},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'}
            },
          ],
        });
      } else {
        apiMessages.add({'role': msg['role'], 'content': msg['content']});
      }
    }

    return apiMessages;
  }
}
