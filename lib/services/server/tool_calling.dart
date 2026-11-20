import 'dart:convert';
import 'dart:math';

/// OpenAI-style tool (function) calling for local GGUF models.
///
/// llama.cpp only sees a chat template, so tools are described in the system
/// prompt using the `<tools>` / `<tool_call>` convention that Qwen, Hermes
/// and many other open models are trained on, and the model's reply is
/// parsed back into OpenAI `tool_calls`. Bare JSON calls (Llama 3.x style)
/// and Mistral's `[TOOL_CALLS]` prefix are understood too.
class ToolSpec {
  final String name;
  final String? description;
  final Map<String, dynamic>? parameters;

  const ToolSpec(this.name, {this.description, this.parameters});

  Map<String, dynamic> toJson() => {
        'type': 'function',
        'function': {
          'name': name,
          if (description != null) 'description': description,
          if (parameters != null) 'parameters': parameters,
        },
      };
}

class ToolCall {
  final String id;
  final String name;

  /// JSON-encoded arguments object, as OpenAI returns them.
  final String arguments;

  const ToolCall(
      {required this.id, required this.name, required this.arguments});

  Map<String, dynamic> toJson({int? index}) => {
        if (index != null) 'index': index,
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
      };
}

class ToolParseResult {
  final String? content;
  final List<ToolCall> calls;
  const ToolParseResult(this.content, this.calls);
}

/// How the request wants tools used, from OpenAI `tool_choice`.
class ToolChoice {
  /// 'auto', 'none' or 'required'.
  final String mode;

  /// Set when one specific function must be called.
  final String? function;

  const ToolChoice(this.mode, [this.function]);

  static const auto = ToolChoice('auto');

  bool get disabled => mode == 'none';
}

class ToolCalling {
  ToolCalling._();

  static const openTag = '<tool_call>';
  static const closeTag = '</tool_call>';
  static const mistralTag = '[TOOL_CALLS]';

  /// Parses OpenAI `tools`. Returns an empty list when absent; throws a
  /// [FormatException] with a client-facing message when malformed.
  static List<ToolSpec> parseTools(dynamic raw) {
    if (raw == null) return const [];
    if (raw is! List) throw const FormatException('tools must be an array');
    final tools = <ToolSpec>[];
    for (var i = 0; i < raw.length; i++) {
      final tool = raw[i];
      if (tool is! Map ||
          tool['type'] != 'function' ||
          tool['function'] is! Map) {
        throw FormatException(
            'tools[$i] must be {"type":"function","function":{...}}');
      }
      final fn = tool['function'] as Map;
      final name = fn['name'];
      if (name is! String || name.trim().isEmpty) {
        throw FormatException('tools[$i].function.name is required');
      }
      final params = fn['parameters'];
      tools.add(ToolSpec(
        name.trim(),
        description:
            fn['description'] is String ? fn['description'] as String : null,
        parameters: params is Map ? Map<String, dynamic>.from(params) : null,
      ));
    }
    return tools;
  }

  static ToolChoice parseToolChoice(dynamic raw, List<ToolSpec> tools) {
    if (raw == null) return ToolChoice.auto;
    if (raw is String) {
      if (raw == 'auto' || raw == 'none' || raw == 'required') {
        return ToolChoice(raw);
      }
      throw const FormatException(
          'tool_choice must be auto, none, required or a function');
    }
    if (raw is Map && raw['function'] is Map) {
      final name = (raw['function'] as Map)['name'];
      if (name is String && tools.any((t) => t.name == name)) {
        return ToolChoice('required', name);
      }
      throw const FormatException(
          'tool_choice names a function that is not in tools');
    }
    throw const FormatException(
        'tool_choice must be auto, none, required or a function');
  }

  /// System prompt section that describes the tools to the model.
  static String systemPrompt(List<ToolSpec> tools, ToolChoice choice) {
    final b = StringBuffer()
      ..writeln('# Tools')
      ..writeln()
      ..writeln(
          'You may call one or more functions to assist with the user query.')
      ..writeln()
      ..writeln(
          'You are provided with function signatures within <tools></tools> XML tags:')
      ..writeln('<tools>');
    for (final tool in tools) {
      b.writeln(jsonEncode(tool.toJson()));
    }
    b
      ..writeln('</tools>')
      ..writeln()
      ..writeln(
          'For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:')
      ..writeln('<tool_call>')
      ..writeln('{"name": <function-name>, "arguments": <args-json-object>}')
      ..write('</tool_call>');
    if (choice.function != null) {
      b.write('\n\nYou must call the function "${choice.function}" now.');
    } else if (choice.mode == 'required') {
      b.write('\n\nYou must call at least one function now.');
    }
    return b.toString();
  }

  /// Text for an assistant turn that called tools, so the model sees its
  /// earlier calls in the history.
  static String assistantTurn(String? content, dynamic rawToolCalls) {
    final b = StringBuffer();
    if (content != null && content.trim().isNotEmpty) b.write(content.trim());
    if (rawToolCalls is List) {
      for (final call in rawToolCalls) {
        if (call is! Map || call['function'] is! Map) continue;
        final fn = call['function'] as Map;
        dynamic args = fn['arguments'];
        if (args is String) {
          try {
            args = jsonDecode(args);
          } catch (_) {}
        }
        if (b.isNotEmpty) b.write('\n');
        b
          ..writeln(openTag)
          ..writeln(jsonEncode({'name': fn['name'], 'arguments': args ?? {}}))
          ..write(closeTag);
      }
    }
    return b.toString();
  }

  /// Text for a `tool` role message. Sent to the model as a user turn,
  /// since chat templates only know system, user and assistant.
  static String toolResultTurn(String content, {String? name}) {
    final b = StringBuffer()..writeln('<tool_response>');
    if (name != null && name.isNotEmpty) {
      b.writeln('{"name": ${jsonEncode(name)}}');
    }
    b
      ..writeln(content.trim())
      ..write('</tool_response>');
    return b.toString();
  }

  /// Splits a model reply into plain content and tool calls. Calls to
  /// functions that were not offered are left in the content.
  static ToolParseResult parse(String text, Iterable<String> toolNames) {
    final names = toolNames.toSet();
    final calls = <ToolCall>[];

    // 1. <tool_call>{...}</tool_call> blocks (closing tag optional at the end).
    if (text.contains(openTag)) {
      final content = StringBuffer();
      var rest = text;
      while (true) {
        final start = rest.indexOf(openTag);
        if (start < 0) {
          content.write(rest);
          break;
        }
        content.write(rest.substring(0, start));
        final afterOpen = rest.substring(start + openTag.length);
        final end = afterOpen.indexOf(closeTag);
        final body = end < 0 ? afterOpen : afterOpen.substring(0, end);
        final parsed = _callsFromJson(body, names);
        if (parsed == null) {
          content.write(rest.substring(start, start + openTag.length));
          rest = afterOpen;
          continue;
        }
        calls.addAll(parsed);
        if (end < 0) break;
        rest = afterOpen.substring(end + closeTag.length);
      }
      if (calls.isNotEmpty) {
        return ToolParseResult(_nonEmpty(content.toString()), calls);
      }
    }

    // 2. [TOOL_CALLS][{...}] (Mistral) or a reply that is only JSON.
    var candidate = text.trim();
    if (candidate.startsWith(mistralTag)) {
      candidate = candidate.substring(mistralTag.length).trim();
    }
    final fence =
        RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(candidate);
    if (fence != null) candidate = fence.group(1)!.trim();
    if (candidate.startsWith('{') || candidate.startsWith('[')) {
      final parsed = _callsFromJson(candidate, names);
      if (parsed != null) return ToolParseResult(null, parsed);
    }
    return ToolParseResult(text, const []);
  }

  static List<ToolCall>? _callsFromJson(String raw, Set<String> names) {
    dynamic decoded;
    try {
      decoded = jsonDecode(raw.trim());
    } catch (_) {
      return null;
    }
    final items = decoded is List ? decoded : [decoded];
    final calls = <ToolCall>[];
    for (final item in items) {
      if (item is! Map) return null;
      final fn = item['function'] is Map ? item['function'] as Map : item;
      final name = fn['name'];
      if (name is! String || !names.contains(name)) return null;
      var args = fn['arguments'] ?? fn['parameters'] ?? const {};
      if (args is String) {
        try {
          args = jsonDecode(args);
        } catch (_) {
          return null;
        }
      }
      if (args is! Map) return null;
      calls.add(
          ToolCall(id: newCallId(), name: name, arguments: jsonEncode(args)));
    }
    return calls.isEmpty ? null : calls;
  }

  static String? _nonEmpty(String s) => s.trim().isEmpty ? null : s.trim();

  static String newCallId() {
    final rng = Random.secure();
    return 'call_${List.generate(24, (_) => rng.nextInt(36).toRadixString(36)).join()}';
  }
}

/// Streams plain text as it arrives but holds back anything that may be a
/// tool call, so clients never see raw `<tool_call>` markup or call JSON.
class ToolCallStreamFilter {
  final _all = StringBuffer();
  String _pending = '';
  bool _decided = false;
  bool _holding = false;
  int _emittedLength = 0;

  /// Everything the model produced.
  String get text => _all.toString();

  /// Feeds a token; returns the text that is safe to send now.
  String add(String token) {
    _all.write(token);
    if (_holding) return '';
    _pending += token;

    if (!_decided) {
      final t = _pending.trimLeft();
      if (t.isEmpty) return '';
      if (t.startsWith('{') ||
          t.startsWith('[') ||
          t.startsWith('```') ||
          t.startsWith(ToolCalling.openTag)) {
        _holding = true;
        return '';
      }
      if (_isPrefix(t, ToolCalling.openTag) ||
          _isPrefix(t, ToolCalling.mistralTag) ||
          _isPrefix(t, '```')) {
        return '';
      }
      _decided = true;
    }

    final idx = _pending.indexOf(ToolCalling.openTag);
    if (idx >= 0) {
      _holding = true;
      return _emit(_pending.substring(0, idx));
    }
    final keep = _partialTagSuffix(_pending);
    final out = _pending.substring(0, _pending.length - keep);
    _pending = _pending.substring(_pending.length - keep);
    return _emit(out);
  }

  /// Text produced but not yet sent (held back or still pending).
  String get unsent => text.substring(_emittedLength);

  String _emit(String s) {
    _emittedLength += s.length;
    return s;
  }

  static bool _isPrefix(String s, String tag) =>
      s.length < tag.length && tag.startsWith(s);

  static int _partialTagSuffix(String s) {
    const tag = ToolCalling.openTag;
    for (var len = min(tag.length - 1, s.length); len > 0; len--) {
      if (tag.startsWith(s.substring(s.length - len))) return len;
    }
    return 0;
  }
}
