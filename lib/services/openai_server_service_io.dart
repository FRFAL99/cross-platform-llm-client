import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

import '../controllers/settings_controller.dart';
import '../core/constants.dart';
import 'inference_service.dart';
import 'server/json_grammar.dart';
import 'server/tool_calling.dart';

class OpenAiServerService {
  HttpServer? _server;
  bool _busy = false;

  /// Requests waiting for the model, oldest first. One model generates one
  /// answer at a time, so requests queue instead of failing straight away.
  final List<int> _queue = [];
  int _nextTicket = 0;
  Duration _queueTimeout = defaultQueueTimeout;

  static const Duration defaultQueueTimeout = Duration(minutes: 5);
  static const int maxQueuedRequests = 8;
  String? _apiKey;
  void Function(String)? _onLog;

  bool get isRunning => _server != null;
  String? get localUrl {
    final port = _server?.port;
    if (port == null) return null;
    final host = _lastReachableAddress;
    return 'http://${host ?? '127.0.0.1'}:$port';
  }

  String? _lastReachableAddress;

  static const int maxBodyBytes = 18 * 1024 * 1024;
  static const int maxDecodedAttachmentBytes = 12 * 1024 * 1024;

  /// When [allowNetwork] is false the server only listens on loopback, so it
  /// is reachable from this device only. Network mode must be paired with an
  /// API key; the caller is responsible for supplying one.
  Future<void> start({
    int port = 8080,
    String? apiKey,
    bool allowNetwork = false,
    Duration queueTimeout = defaultQueueTimeout,
    void Function(String)? onLog,
  }) async {
    if (_server != null) return;
    _queueTimeout = queueTimeout;
    if (allowNetwork && (apiKey == null || apiKey.trim().isEmpty)) {
      throw ArgumentError('An API key is required for network access.');
    }
    updateApiKey(apiKey);
    _onLog = onLog;
    _lastReachableAddress = allowNetwork ? await _reachableIpv4Address() : null;
    _server = await HttpServer.bind(
      allowNetwork ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
      port,
    );
    _onLog?.call('Server listening on ${localUrl ?? 'http://localhost:$port'}');
    unawaited(_serve(_server!));
  }

  /// Applies a new API key to the running server without a restart.
  void updateApiKey(String? apiKey) {
    final key = apiKey?.trim();
    _apiKey = (key == null || key.isEmpty) ? null : key;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    _busy = false;
    _queue.clear();
    _onLog?.call('Server stopped');
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      _addCorsHeaders(request.response);
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }

      final path = request.uri.path;
      if (request.method == 'GET' && path == '/health') {
        await _json(request, {'status': 'ok'});
        return;
      }

      if (path.startsWith('/v1/') && !_isAuthorized(request)) {
        await _json(request, {'error': 'Unauthorized'},
            status: HttpStatus.unauthorized);
        return;
      }

      // Requiring a JSON content type forces browsers to send a CORS
      // preflight, so web pages can't fire "simple" cross-origin requests.
      if (request.method == 'POST' &&
          request.headers.contentType?.mimeType != ContentType.json.mimeType) {
        await _json(request, {'error': 'Content-Type must be application/json'},
            status: HttpStatus.unsupportedMediaType);
        return;
      }

      if (request.method == 'GET' && path == '/v1/models') {
        await _handleModels(request);
        return;
      }
      if (request.method == 'GET' && path == '/v1/server/capabilities') {
        await _handleCapabilities(request);
        return;
      }
      if (request.method == 'POST' && path == '/v1/chat/completions') {
        await _handleChatCompletions(request);
        return;
      }
      if (request.method == 'POST' && path == '/v1/completions') {
        await _handleCompletions(request);
        return;
      }

      await _json(request, {'error': 'Not found'}, status: HttpStatus.notFound);
    } catch (error) {
      _onLog?.call('Request failed: $error');
      try {
        await _json(
          request,
          {'error': 'Internal server error'},
          status: HttpStatus.internalServerError,
        );
      } catch (_) {
        // The response may already be closed or detached (streaming).
        try {
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  bool _isAuthorized(HttpRequest request) {
    final key = _apiKey;
    if (key == null || key.isEmpty) return true;
    final header = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    return _constantTimeEquals(header.trim(), 'Bearer $key');
  }

  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length && i < y.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  Future<void> _handleModels(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    final hasModel = inference.isModelLoaded.value;
    await _json(request, {
      'object': 'list',
      'data': [
        if (hasModel)
          {
            'id': inference.loadedModelName.value,
            'object': 'model',
            'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'owned_by': 'local',
          }
      ],
    });
  }

  Future<void> _handleCapabilities(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    final hasModel = inference.isModelLoaded.value;
    await _json(request, {
      'server': 'PrivateLM',
      'running': true,
      'model': hasModel ? inference.loadedModelName.value : null,
      'runtime': inference.loadedModelRuntime.value,
      'capabilities': {
        'text': hasModel,
        'image': hasModel && inference.ggufVisionLoaded,
        'audio': false,
        'streaming': hasModel,
        'tools': hasModel,
        'json_mode': hasModel,
        'gguf': hasModel,
      },
    });
  }

  Future<void> _handleChatCompletions(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    if (!await _acquire(request, inference)) return;
    final tempFiles = <File>[];
    try {
      final body = await _readJson(request);
      // One model is loaded at a time, and clients (PC chat apps, editors)
      // often send their own model name: serve the loaded model regardless,
      // as llama-server and LM Studio do.
      final model = (body['model'] as String?)?.trim();
      if (model != null &&
          model.isNotEmpty &&
          model != inference.loadedModelName.value) {
        _onLog?.call(
            'Request for "$model"; serving ${inference.loadedModelName.value}');
      }

      final parsed = await _parseChatRequest(body, tempFiles);
      if (parsed.error != null) {
        await _json(request, {'error': parsed.error},
            status: HttpStatus.badRequest);
        return;
      }

      final sampling = _sampling(body);
      if (sampling.error != null) {
        await _json(request, {'error': sampling.error},
            status: HttpStatus.badRequest);
        return;
      }
      final systemPrompt = _chatSystemPrompt(
          parsed, _defaultSystemPrompt(inference.loadedModelName.value));
      if (body['stream'] == true) {
        await _streamChatResponse(
            request, inference, parsed, systemPrompt, sampling);
      } else {
        final stopsBefore = inference.stopCount;
        final text = await inference.generate(
          prompt: parsed.prompt,
          systemPrompt: systemPrompt,
          conversationHistory: parsed.history,
          source: 'server',
          imagePath: parsed.imagePath,
          audioPath: parsed.audioPath,
          maxTokens: sampling.maxTokens,
          stopSequences: sampling.stop,
          temperature: sampling.temperature,
          topP: sampling.topP,
          grammar: parsed.grammar,
          grammarTrigger: parsed.grammarTrigger,
        );
        if (inference.stopCount != stopsBefore) {
          await _interrupted(request);
          return;
        }
        await _json(
            request,
            _chatResponse(inference.loadedModelName.value, text, parsed,
                inference.lastUsage));
      }
    } finally {
      _busy = false;
      await _deleteFiles(tempFiles);
    }
  }

  /// Claims the model for one request. While another server request or an
  /// in-app generation is running, waits in a first-come queue (up to the
  /// queue timeout) before the body is read. The server is marked busy
  /// synchronously so concurrent requests can't both pass.
  Future<bool> _acquire(HttpRequest request, InferenceService inference) async {
    final modelError = _localModelError(inference);
    if (modelError != null) {
      await _json(request, {'error': modelError},
          status: HttpStatus.badRequest);
      return false;
    }
    if (!_busy && !inference.isGenerating.value && _queue.isEmpty) {
      _busy = true;
      return true;
    }
    if (_queue.length >= maxQueuedRequests) {
      await _busyResponse(request, 'Too many requests are waiting');
      return false;
    }
    final ticket = _nextTicket++;
    _queue.add(ticket);
    final deadline = DateTime.now().add(_queueTimeout);
    try {
      while (_busy || inference.isGenerating.value || _queue.first != ticket) {
        if (_server == null || !_queue.contains(ticket)) return false;
        if (DateTime.now().isAfter(deadline)) {
          await _busyResponse(request, 'Model is busy');
          return false;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
      _busy = true;
      return true;
    } finally {
      _queue.remove(ticket);
    }
  }

  Future<void> _busyResponse(HttpRequest request, String message) {
    request.response.headers.set(HttpHeaders.retryAfterHeader, '5');
    return _json(request, {'error': message}, status: 429);
  }

  Future<void> _interrupted(HttpRequest request) => _json(
        request,
        {
          'error':
              'Generation was interrupted (the app started its own response)'
        },
        status: HttpStatus.serviceUnavailable,
      );

  /// OpenAI `stop`: a string or a list of up to 4 strings.
  List<String> _stop(Map<String, dynamic> body) {
    final raw = body['stop'];
    if (raw is String) return raw.isEmpty ? const [] : [raw];
    if (raw is List) {
      return raw
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .take(4)
          .toList();
    }
    return const [];
  }

  int? _maxTokens(Map<String, dynamic> body) {
    final raw = body['max_completion_tokens'] ?? body['max_tokens'];
    return raw is num && raw > 0 ? raw.toInt() : null;
  }

  /// OpenAI sampling options. Unset values fall back to the app settings.
  _Sampling _sampling(Map<String, dynamic> body) {
    final temperature = body['temperature'];
    final topP = body['top_p'];
    if (temperature != null &&
        (temperature is! num || temperature < 0 || temperature > 2)) {
      return const _Sampling.error('temperature must be between 0 and 2');
    }
    if (topP != null && (topP is! num || topP <= 0 || topP > 1)) {
      return const _Sampling.error(
          'top_p must be greater than 0 and at most 1');
    }
    return _Sampling(
      maxTokens: _maxTokens(body),
      stop: _stop(body),
      temperature: (temperature as num?)?.toDouble(),
      topP: (topP as num?)?.toDouble(),
      includeUsage: body['stream_options'] is Map &&
          (body['stream_options'] as Map)['include_usage'] == true,
    );
  }

  /// The client's system prompt (or the app default) plus the tool list and
  /// JSON-mode instructions the request asks for.
  String _chatSystemPrompt(_ParsedChatRequest parsed, String fallback) {
    final parts = <String>[parsed.systemPrompt ?? fallback];
    if (parsed.tools.isNotEmpty && !parsed.toolChoice.disabled) {
      parts.add(ToolCalling.systemPrompt(parsed.tools, parsed.toolChoice));
    }
    if (parsed.jsonInstruction != null) parts.add(parsed.jsonInstruction!);
    return parts.where((p) => p.trim().isNotEmpty).join('\n\n');
  }

  Future<void> _deleteFiles(List<File> files) async {
    for (final file in files) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<void> _handleCompletions(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    if (!await _acquire(request, inference)) return;
    try {
      final body = await _readJson(request);
      final prompt = body['prompt'];
      if (prompt is! String || prompt.trim().isEmpty) {
        await _json(request, {'error': 'prompt is required'},
            status: HttpStatus.badRequest);
        return;
      }

      final sampling = _sampling(body);
      if (sampling.error != null) {
        await _json(request, {'error': sampling.error},
            status: HttpStatus.badRequest);
        return;
      }
      if (body['stream'] == true) {
        await _streamCompletionResponse(request, inference, prompt, sampling);
      } else {
        final stopsBefore = inference.stopCount;
        final text = await inference.generate(
          prompt: prompt,
          systemPrompt: _defaultSystemPrompt(inference.loadedModelName.value),
          source: 'server',
          maxTokens: sampling.maxTokens,
          stopSequences: sampling.stop,
          temperature: sampling.temperature,
          topP: sampling.topP,
        );
        if (inference.stopCount != stopsBefore) {
          await _interrupted(request);
          return;
        }
        await _json(request, {
          'id': 'cmpl-${_id()}',
          'object': 'text_completion',
          'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'model': inference.loadedModelName.value,
          'choices': [
            {'index': 0, 'text': text, 'finish_reason': 'stop'}
          ],
          'usage': _usage(inference.lastUsage),
        });
      }
    } finally {
      _busy = false;
    }
  }

  String? _localModelError(InferenceService inference) {
    if (!inference.isModelLoaded.value) {
      return 'No local model loaded. Load a GGUF model first.';
    }
    return null;
  }

  /// Temp files are appended to [tempFiles] as they're written so the caller
  /// can always delete them, including when parsing fails part-way.
  Future<_ParsedChatRequest> _parseChatRequest(
      Map<String, dynamic> body, List<File> tempFiles) async {
    final rawMessages = body['messages'];
    if (rawMessages is! List || rawMessages.isEmpty) {
      return _ParsedChatRequest.error('messages must be a non-empty array');
    }

    late final List<ToolSpec> tools;
    late final ToolChoice toolChoice;
    try {
      tools = ToolCalling.parseTools(body['tools']);
      toolChoice = ToolCalling.parseToolChoice(body['tool_choice'], tools);
    } on FormatException catch (e) {
      return _ParsedChatRequest.error(e.message);
    }
    final jsonInstruction = _jsonInstruction(body['response_format']);
    if (jsonInstruction is _Invalid) {
      return _ParsedChatRequest.error(jsonInstruction.message);
    }
    final grammar = _grammar(tools, toolChoice, body['response_format']);

    final systemParts = <String>[];
    final history = <Map<String, String>>[];
    var lastText = '';
    String? imagePath;
    String? audioPath;

    for (var i = 0; i < rawMessages.length; i++) {
      final raw = rawMessages[i];
      if (raw is! Map) {
        return _ParsedChatRequest.error('message[$i] must be an object');
      }
      var role = '${raw['role'] ?? ''}';
      if (role == 'developer') role = 'system';
      if (!const {'system', 'user', 'assistant', 'tool'}.contains(role)) {
        return _ParsedChatRequest.error('message[$i].role is unsupported');
      }
      final rawContent = raw['content'];
      final contentResult = rawContent == null && role != 'user'
          ? _ContentResult(text: '')
          : await _parseContent(rawContent, tempFiles);
      if (contentResult.error != null) {
        return _ParsedChatRequest.error(contentResult.error!);
      }
      imagePath ??= contentResult.imagePath;
      audioPath ??= contentResult.audioPath;

      if (role == 'system') {
        if (contentResult.text.trim().isNotEmpty) {
          systemParts.add(contentResult.text.trim());
        }
        continue;
      }

      // Chat templates only know system, user and assistant: tool results
      // become user turns and tool calls become assistant text.
      var text = contentResult.text;
      if (role == 'tool') {
        final name = raw['name'];
        text = ToolCalling.toolResultTurn(text,
            name: name is String ? name : null);
        role = 'user';
      } else if (role == 'assistant' && raw['tool_calls'] is List) {
        text = ToolCalling.assistantTurn(text, raw['tool_calls']);
      }

      if (i == rawMessages.length - 1 && role == 'user') {
        lastText = text.trim();
      } else {
        history.add({'role': role, 'content': text});
      }
    }

    if (lastText.isEmpty && imagePath == null && audioPath == null) {
      return _ParsedChatRequest.error(
          'last message must be a user or tool message with text, image, or audio');
    }

    return _ParsedChatRequest(
      prompt: lastText.isEmpty ? 'Describe this attachment.' : lastText,
      systemPrompt: systemParts.isEmpty ? null : systemParts.join('\n'),
      history: history,
      imagePath: imagePath,
      audioPath: audioPath,
      tools: tools,
      toolChoice: toolChoice,
      jsonInstruction: jsonInstruction as String?,
      grammar: grammar?.gbnf,
      grammarTrigger: grammar?.trigger,
    );
  }

  /// The llama.cpp grammar that makes the model's output valid: tool calls
  /// whose arguments match the tool's parameters (from the first token when
  /// a call is required, from `<tool_call>` on with `auto`), or JSON for
  /// `response_format`. A schema the converter can't read falls back to
  /// the prompt instructions alone.
  ({String gbnf, String? trigger})? _grammar(
      List<ToolSpec> tools, ToolChoice choice, dynamic format) {
    try {
      if (tools.isNotEmpty && !choice.disabled) {
        return (
          gbnf: JsonGrammar.toolCalls(tools, only: choice.function),
          trigger: choice.mode == 'auto' ? JsonGrammar.toolCallTrigger : null,
        );
      }
      if (format is Map && format['type'] == 'json_object') {
        return (gbnf: JsonGrammar.anyObject(), trigger: null);
      }
      if (format is Map && format['type'] == 'json_schema') {
        final spec = format['json_schema'];
        final schema = spec is Map ? spec['schema'] : null;
        if (schema is Map) {
          return (
            gbnf: JsonGrammar.forSchema(Map<String, dynamic>.from(schema)),
            trigger: null,
          );
        }
      }
    } on FormatException catch (e) {
      _onLog?.call('Output not constrained (${e.message}); '
          'relying on instructions');
    }
    return null;
  }

  /// OpenAI `response_format`: JSON mode and JSON schema are described to
  /// the model too, so it knows what to write; the grammar from [_grammar]
  /// is what guarantees it.
  Object? _jsonInstruction(dynamic format) {
    if (format == null) return null;
    if (format is! Map) {
      return const _Invalid('response_format must be an object');
    }
    switch (format['type']) {
      case 'text':
        return null;
      case 'json_object':
        return 'Respond only with a single valid JSON object. '
            'Do not add any text before or after it, and do not use code fences.';
      case 'json_schema':
        final spec = format['json_schema'];
        final schema = spec is Map ? spec['schema'] : null;
        if (schema is! Map) {
          return const _Invalid(
              'response_format.json_schema.schema is required');
        }
        return 'Respond only with a single valid JSON object that matches this '
            'JSON schema. Do not add any text before or after it, and do not '
            'use code fences.\n${jsonEncode(schema)}';
      default:
        return const _Invalid('response_format.type is unsupported');
    }
  }

  Future<_ContentResult> _parseContent(
      dynamic content, List<File> tempFiles) async {
    if (content is String) return _ContentResult(text: content);
    if (content is! List) {
      return _ContentResult.error(
          'message.content must be a string or content array');
    }

    final text = StringBuffer();
    String? imagePath;
    String? audioPath;

    for (final part in content) {
      if (part is! Map) {
        return _ContentResult.error('content part must be an object');
      }
      final type = '${part['type'] ?? ''}';
      if (type == 'text') {
        text.write('${part['text'] ?? ''}');
      } else if (type == 'image_url') {
        if (imagePath != null) {
          return _ContentResult.error(
              'only one image is supported per request');
        }
        final imageUrl = part['image_url'];
        final url = imageUrl is Map ? '${imageUrl['url'] ?? ''}' : '';
        final file = await _dataUrlToTempFile(url, 'image');
        if (file.error != null) return _ContentResult.error(file.error!);
        imagePath = file.path;
        tempFiles.add(file.file!);
      } else if (type == 'input_audio' || type == 'audio_url') {
        if (audioPath != null) {
          return _ContentResult.error(
              'only one audio file is supported per request');
        }
        final raw = part[type == 'input_audio' ? 'input_audio' : 'audio_url'];
        final data = raw is Map ? '${raw['data'] ?? raw['url'] ?? ''}' : '';
        final file = await _dataUrlToTempFile(data, 'audio');
        if (file.error != null) return _ContentResult.error(file.error!);
        audioPath = file.path;
        tempFiles.add(file.file!);
      } else {
        return _ContentResult.error('unsupported content part type: $type');
      }
    }

    return _ContentResult(
      text: text.toString(),
      imagePath: imagePath,
      audioPath: audioPath,
    );
  }

  Future<_TempFileResult> _dataUrlToTempFile(String value, String kind) async {
    if (!value.startsWith('data:')) {
      return _TempFileResult.error(
          'Only base64 data URLs are accepted for $kind input');
    }
    final comma = value.indexOf(',');
    if (comma <= 0 || !value.substring(0, comma).contains(';base64')) {
      return _TempFileResult.error('$kind input must be a base64 data URL');
    }
    final meta = value.substring(5, comma).toLowerCase();
    final encoded = value.substring(comma + 1);
    if (encoded.length > maxDecodedAttachmentBytes * 2) {
      return _TempFileResult.error('$kind input is too large');
    }
    late List<int> bytes;
    try {
      bytes = base64Decode(encoded);
    } catch (_) {
      return _TempFileResult.error('$kind input has invalid base64');
    }
    if (bytes.length > maxDecodedAttachmentBytes) {
      return _TempFileResult.error('$kind input is too large');
    }
    final ext = _extensionForMime(meta, kind);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/server_${kind}_${_id()}.$ext');
    await file.writeAsBytes(bytes, flush: true);
    return _TempFileResult(file);
  }

  String _extensionForMime(String mime, String kind) {
    if (mime.contains('png')) return 'png';
    if (mime.contains('webp')) return 'webp';
    if (mime.contains('jpg') || mime.contains('jpeg')) return 'jpg';
    if (mime.contains('wav')) return 'wav';
    if (mime.contains('mp3') || mime.contains('mpeg')) return 'mp3';
    if (mime.contains('m4a') || mime.contains('mp4')) return 'm4a';
    return kind == 'image' ? 'png' : 'wav';
  }

  Future<void> _streamChatResponse(
    HttpRequest request,
    InferenceService inference,
    _ParsedChatRequest parsed,
    String systemPrompt,
    _Sampling sampling,
  ) async {
    final response = request.response;
    _addCorsHeaders(response);
    final id = 'chatcmpl-${_id()}';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final model = inference.loadedModelName.value;
    final sse = await _SseStream.open(response, onDisconnect: () {
      if (inference.generationSource.value == 'server') {
        unawaited(inference.stopGeneration());
      }
    });

    void chunk(Map<String, dynamic> delta, {String? finishReason}) {
      sse.event({
        'id': id,
        'object': 'chat.completion.chunk',
        'created': created,
        'model': model,
        'choices': [
          {'index': 0, 'delta': delta, 'finish_reason': finishReason}
        ],
      });
    }

    // OpenAI clients expect the role first.
    chunk({'role': 'assistant', 'content': ''});

    final filter = parsed.usesTools ? ToolCallStreamFilter() : null;
    final sent = StringBuffer();
    void emit(String token) {
      final visible = filter == null ? token : filter.add(token);
      if (visible.isEmpty) return;
      sent.write(visible);
      chunk({'content': visible});
    }

    final stopsBefore = inference.stopCount;
    final result = await inference.generate(
      prompt: parsed.prompt,
      systemPrompt: systemPrompt,
      conversationHistory: parsed.history,
      source: 'server',
      imagePath: parsed.imagePath,
      audioPath: parsed.audioPath,
      maxTokens: sampling.maxTokens,
      stopSequences: sampling.stop,
      temperature: sampling.temperature,
      topP: sampling.topP,
      grammar: parsed.grammar,
      grammarTrigger: parsed.grammarTrigger,
      onToken: emit,
    );

    if (inference.stopCount != stopsBefore) {
      await _endInterrupted(sse);
      return;
    }

    var finishReason = 'stop';
    if (filter != null) {
      final full = filter.text.isEmpty ? result : filter.text;
      final parsedCalls = ToolCalling.parse(full, parsed.toolNames);
      if (parsedCalls.calls.isNotEmpty) {
        chunk({
          'tool_calls': [
            for (var i = 0; i < parsedCalls.calls.length; i++)
              parsedCalls.calls[i].toJson(index: i)
          ],
        });
        finishReason = 'tool_calls';
      } else {
        final rest = filter.text.isEmpty ? result : filter.unsent;
        if (rest.isNotEmpty) chunk({'content': rest});
      }
    } else if (sent.isEmpty && result.isNotEmpty) {
      // Engines that don't stream (or an error message) still answer.
      chunk({'content': result});
    }
    chunk({}, finishReason: finishReason);
    if (sampling.includeUsage) {
      sse.event({
        'id': id,
        'object': 'chat.completion.chunk',
        'created': created,
        'model': model,
        'choices': const [],
        'usage': _usage(inference.lastUsage),
      });
    }
    sse.raw('data: [DONE]\n\n');
    await sse.close();
  }

  /// OpenAI `usage`; zeros when the engine couldn't count.
  static Map<String, int> _usage(GenerationUsage? usage) =>
      (usage ?? const GenerationUsage(promptTokens: 0, completionTokens: 0))
          .toJson();

  /// Reports an interruption as an error event rather than a normal [DONE],
  /// so clients don't mistake a partial answer for a complete one.
  Future<void> _endInterrupted(_SseStream sse) async {
    sse.event({
      'error': {
        'message': 'Generation was interrupted',
        'type': 'interrupted',
      }
    });
    await sse.close();
  }

  Future<void> _streamCompletionResponse(
    HttpRequest request,
    InferenceService inference,
    String prompt,
    _Sampling sampling,
  ) async {
    final response = request.response;
    _addCorsHeaders(response);
    final id = 'cmpl-${_id()}';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final model = inference.loadedModelName.value;
    var emitted = false;
    final sse = await _SseStream.open(response, onDisconnect: () {
      if (inference.generationSource.value == 'server') {
        unawaited(inference.stopGeneration());
      }
    });

    void chunk(String text, {String? finishReason}) {
      sse.event({
        'id': id,
        'object': 'text_completion',
        'created': created,
        'model': model,
        'choices': [
          {'index': 0, 'text': text, 'finish_reason': finishReason}
        ],
      });
    }

    final stopsBefore = inference.stopCount;
    final result = await inference.generate(
      prompt: prompt,
      systemPrompt: _defaultSystemPrompt(model),
      source: 'server',
      maxTokens: sampling.maxTokens,
      stopSequences: sampling.stop,
      temperature: sampling.temperature,
      topP: sampling.topP,
      onToken: (token) {
        emitted = true;
        chunk(token);
      },
    );
    if (inference.stopCount != stopsBefore) {
      await _endInterrupted(sse);
      return;
    }
    if (!emitted && result.isNotEmpty) chunk(result);
    chunk('', finishReason: 'stop');
    if (sampling.includeUsage) {
      sse.event({
        'id': id,
        'object': 'text_completion',
        'created': created,
        'model': model,
        'choices': const [],
        'usage': _usage(inference.lastUsage),
      });
    }
    sse.raw('data: [DONE]\n\n');
    await sse.close();
  }

  Map<String, dynamic> _chatResponse(String model, String text,
      _ParsedChatRequest parsed, GenerationUsage? usage) {
    if (parsed.jsonInstruction != null) text = _stripCodeFence(text);
    var message = <String, dynamic>{'role': 'assistant', 'content': text};
    var finishReason = 'stop';
    if (parsed.usesTools) {
      final result = ToolCalling.parse(text, parsed.toolNames);
      if (result.calls.isNotEmpty) {
        message = {
          'role': 'assistant',
          'content': result.content,
          'tool_calls': [for (final c in result.calls) c.toJson()],
        };
        finishReason = 'tool_calls';
      }
    }
    return {
      'id': 'chatcmpl-${_id()}',
      'object': 'chat.completion',
      'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'model': model,
      'choices': [
        {
          'index': 0,
          'message': message,
          'finish_reason': finishReason,
        }
      ],
      'usage': _usage(usage),
    };
  }

  /// Models often wrap JSON in a ```json fence despite being told not to.
  static String _stripCodeFence(String text) {
    final match =
        RegExp(r'^\s*```(?:json)?\s*([\s\S]*?)\s*```\s*$').firstMatch(text);
    return match == null ? text : match.group(1)!;
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > maxBodyBytes) {
        throw const HttpException('Request body is too large');
      }
    }
    final body = utf8.decode(builder.takeBytes());
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSON body must be an object');
    }
    return decoded;
  }

  Future<void> _json(
    HttpRequest request,
    Map<String, dynamic> data, {
    int status = HttpStatus.ok,
  }) async {
    _addCorsHeaders(request.response);
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(data));
    await request.response.close();
  }

  void _addCorsHeaders(HttpResponse response) {
    // Only allow browser access when a key is required, so an arbitrary web
    // page can't read model output from an open server.
    if (_apiKey == null) return;
    response.headers.set(HttpHeaders.accessControlAllowOriginHeader, '*');
    response.headers
        .set(HttpHeaders.accessControlAllowMethodsHeader, 'GET,POST,OPTIONS');
    response.headers.set(
      HttpHeaders.accessControlAllowHeadersHeader,
      'Content-Type, Authorization',
    );
  }

  Future<String?> _reachableIpv4Address() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) return address.address;
        }
      }
    } catch (_) {}
    return null;
  }

  String _id() {
    final rng = Random.secure();
    return List.generate(12, (_) => rng.nextInt(16).toRadixString(16)).join();
  }

  String _defaultSystemPrompt(String modelName) {
    if (Get.isRegistered<SettingsController>()) {
      return Get.find<SettingsController>().effectiveSystemPromptForModel(
        modelName,
      );
    }
    if (AppConstants.isUncensoredModelName(modelName)) {
      return AppConstants.uncensoredSystemPrompt;
    }
    return AppConstants.systemPrompt;
  }
}

/// Streams server-sent events over the raw socket.
///
/// dart:io's HttpServer never reports a client that hangs up mid-response
/// (flush() keeps succeeding and `done` never errors), so the response is
/// detached and the socket itself is watched: it closes the moment the client
/// goes away. Writes are fire-and-forget, so nothing here can block the
/// request handler (and leave the server stuck busy).
class _SseStream {
  _SseStream._(this._socket, this._onDisconnect) {
    _socket.listen(
      (_) {},
      onDone: _disconnect,
      onError: (_) => _disconnect(),
      cancelOnError: true,
    );
  }

  static Future<_SseStream> open(
    HttpResponse response, {
    required void Function() onDisconnect,
  }) async {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    // The body ends when the connection closes; no chunked framing needed.
    response.headers.chunkedTransferEncoding = false;
    response.headers.set(HttpHeaders.connectionHeader, 'close');
    final socket = await response.detachSocket(writeHeaders: true);
    return _SseStream._(socket, onDisconnect);
  }

  final Socket _socket;
  final void Function() _onDisconnect;
  bool _disconnected = false;
  bool _closed = false;

  void event(Object payload) => raw('data: ${jsonEncode(payload)}\n\n');

  void raw(String chunk) {
    if (_disconnected || _closed) return;
    try {
      _socket.write(chunk);
    } catch (_) {
      _disconnect();
    }
  }

  void _disconnect() {
    if (_disconnected) return;
    _disconnected = true;
    if (!_closed) _onDisconnect();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      _socket.destroy();
    }
  }
}

class _ParsedChatRequest {
  final String prompt;
  final String? systemPrompt;
  final List<Map<String, String>> history;
  final String? imagePath;
  final String? audioPath;
  final List<ToolSpec> tools;
  final ToolChoice toolChoice;
  final String? jsonInstruction;

  /// GBNF grammar that forces valid JSON or tool calls (null: free text).
  final String? grammar;

  /// Set when [grammar] only starts once the model opens a tool call.
  final String? grammarTrigger;
  final String? error;

  _ParsedChatRequest({
    required this.prompt,
    required this.systemPrompt,
    required this.history,
    required this.imagePath,
    required this.audioPath,
    this.tools = const [],
    this.toolChoice = ToolChoice.auto,
    this.jsonInstruction,
    this.grammar,
    this.grammarTrigger,
  }) : error = null;

  _ParsedChatRequest.error(this.error)
      : prompt = '',
        systemPrompt = null,
        history = const [],
        imagePath = null,
        audioPath = null,
        tools = const [],
        toolChoice = ToolChoice.auto,
        jsonInstruction = null,
        grammar = null,
        grammarTrigger = null;

  /// Whether the reply should be parsed for tool calls.
  bool get usesTools => tools.isNotEmpty && !toolChoice.disabled;

  Iterable<String> get toolNames => tools.map((t) => t.name);
}

class _Sampling {
  final int? maxTokens;
  final List<String> stop;
  final double? temperature;
  final double? topP;

  /// `stream_options.include_usage`: end the stream with a usage chunk.
  final bool includeUsage;
  final String? error;

  const _Sampling({
    required this.maxTokens,
    required this.stop,
    required this.temperature,
    required this.topP,
    this.includeUsage = false,
  }) : error = null;

  const _Sampling.error(this.error)
      : maxTokens = null,
        stop = const [],
        temperature = null,
        topP = null,
        includeUsage = false;
}

class _Invalid {
  final String message;
  const _Invalid(this.message);
}

class _ContentResult {
  final String text;
  final String? imagePath;
  final String? audioPath;
  final String? error;

  _ContentResult({
    required this.text,
    this.imagePath,
    this.audioPath,
  }) : error = null;

  _ContentResult.error(this.error)
      : text = '',
        imagePath = null,
        audioPath = null;
}

class _TempFileResult {
  final File? file;
  final String? error;

  _TempFileResult(this.file) : error = null;
  _TempFileResult.error(this.error) : file = null;

  String get path => file!.path;
}
