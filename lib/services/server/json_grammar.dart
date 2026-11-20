import 'dart:convert';

import 'tool_calling.dart';

/// llama.cpp GBNF grammars that force valid JSON output.
///
/// Used by the API server for `response_format` (JSON mode and JSON schema)
/// and for tool calls: with a grammar, llama.cpp can only sample tokens
/// that keep the output valid, so clients always get parseable JSON and
/// calls whose arguments match the tool's parameters.
///
/// Supported JSON Schema: `type` (also as a list), `properties`,
/// `required`, `additionalProperties`, `items`, `prefixItems`,
/// `minItems`/`maxItems`, `enum`, `const`, `anyOf`/`oneOf`, `allOf` of
/// objects, `$ref` to `#/$defs/...` or `#/definitions/...`, and string
/// `minLength`/`maxLength`. Other keywords (`pattern`, `format`, numeric
/// bounds) are not enforced: the value just has the right type.
class JsonGrammar {
  JsonGrammar._(this._root);

  final Map<String, dynamic> _root;
  final _rules = <String, String>{};
  final _bodies = <String, String>{};
  final _refs = <String, String>{};

  static const _primitives = <String, String>{
    'space': r'| " " | "\n"{1,2} [ \t]{0,20}',
    'boolean': r'("true" | "false") space',
    'null': r'"null" space',
    'integral-part': r'[0] | [1-9] [0-9]{0,15}',
    'decimal-part': r'[0-9]{1,16}',
    'number':
        r'("-"? integral-part) ("." decimal-part)? ([eE] [-+]? integral-part)? space',
    'integer': r'("-"? integral-part) space',
    'char': r'[^"\\\x7F\x00-\x1F] | [\\] (["\\bfnrt] | "u" [0-9a-fA-F]{4})',
    'string': r'"\"" char* "\"" space',
    'value': r'object | array | string | number | boolean | null',
    'object':
        r'"{" space ( string ":" space value ("," space string ":" space value)* )? "}" space',
    'array': r'"[" space ( value ("," space value)* )? "]" space',
  };

  /// Primitive rules each primitive depends on.
  static const _deps = <String, List<String>>{
    'boolean': ['space'],
    'null': ['space'],
    'number': ['integral-part', 'decimal-part', 'space'],
    'integer': ['integral-part', 'space'],
    'char': [],
    'string': ['char', 'space'],
    'value': ['object', 'array', 'string', 'number', 'boolean', 'null'],
    'object': ['string', 'value', 'space'],
    'array': ['value', 'space'],
    'space': [],
    'integral-part': [],
    'decimal-part': [],
  };

  /// Any JSON object (`response_format: {"type": "json_object"}`).
  static String anyObject() {
    final g = JsonGrammar._(const {});
    g._rules['root'] = 'space? ${g._primitive('object')}';
    return g._render();
  }

  /// JSON matching [schema] (`response_format` of type `json_schema`).
  /// Throws a [FormatException] for a schema it can't read.
  static String forSchema(Map<String, dynamic> schema) {
    final g = JsonGrammar._(schema);
    final value = g._visit(schema, 'root-value');
    g._rules['root'] = 'space? $value';
    return g._render();
  }

  /// One or more `<tool_call>{"name": ..., "arguments": {...}}</tool_call>`
  /// blocks, as described by [ToolCalling.systemPrompt]. With [only], just
  /// that function can be called.
  static String toolCalls(List<ToolSpec> tools, {String? only}) {
    final g = JsonGrammar._(const {});
    final alternatives = <String>[];
    for (final tool in tools) {
      if (only != null && tool.name != only) continue;
      final ruleName = g._name('call-${tool.name}');
      final params = tool.parameters;
      final args = params == null || params.isEmpty
          ? g._primitive('object')
          : g._withRoot(params, () => g._visit(params, '$ruleName-args'));
      g._rules[ruleName] = [
        '"{" space',
        _literal(jsonEncode('name')),
        'space ":" space',
        _literal(jsonEncode(tool.name)),
        'space "," space',
        _literal(jsonEncode('arguments')),
        'space ":" space',
        args,
        '"}" space',
      ].join(' ');
      alternatives.add(ruleName);
    }
    if (alternatives.isEmpty) {
      throw const FormatException('no tool to call');
    }
    g._rules['tool-call'] = '${_literal(ToolCalling.openTag)} space '
        '( ${alternatives.join(' | ')} ) '
        '${_literal(ToolCalling.closeTag)}';
    g._rules['root'] = 'tool-call ( space tool-call )*';
    g._primitive('space');
    return g._render();
  }

  /// The regex that starts a lazy tool-call grammar (`tool_choice: auto`):
  /// the model writes freely until it opens a call.
  static String get toolCallTrigger => RegExp.escape(ToolCalling.openTag);

  // ── Schema visitor ──────────────────────────────────────────────────

  Map<String, dynamic>? _currentRoot;

  T _withRoot<T>(Map<String, dynamic> root, T Function() body) {
    final previous = _currentRoot;
    _currentRoot = root;
    try {
      return body();
    } finally {
      _currentRoot = previous;
    }
  }

  Map<String, dynamic> get _schemaRoot => _currentRoot ?? _root;

  /// Returns a rule expression (a rule name or a primitive) for [schema].
  String _visit(dynamic schema, String name) {
    if (schema == true || schema == null) return _primitive('value');
    if (schema is! Map) {
      throw const FormatException('a JSON schema must be an object');
    }
    final s = Map<String, dynamic>.from(schema);
    if (s.isEmpty) return _primitive('value');

    final ref = s[r'$ref'];
    if (ref is String) return _ref(ref);

    if (s.containsKey('const')) {
      return _define(name, '${_literal(jsonEncode(s['const']))} space');
    }

    final enumValues = s['enum'];
    if (enumValues is List && enumValues.isNotEmpty) {
      _primitive('space');
      final alts = enumValues.map((v) => _literal(jsonEncode(v))).join(' | ');
      return _define(name, '( $alts ) space');
    }

    final anyOf = s['anyOf'] ?? s['oneOf'];
    if (anyOf is List && anyOf.isNotEmpty) {
      final alts = <String>[
        for (var i = 0; i < anyOf.length; i++) _visit(anyOf[i], '$name-$i'),
      ];
      return _define(name, alts.join(' | '));
    }

    final allOf = s['allOf'];
    if (allOf is List && allOf.isNotEmpty) {
      return _visit(_mergeAllOf(s, allOf), name);
    }

    final type = s['type'];
    if (type is List) {
      final alts = <String>[
        for (final t in type) _visit({...s, 'type': t}, '$name-$t'),
      ];
      return _define(name, alts.join(' | '));
    }

    switch (type) {
      case 'object':
        return _object(s, name);
      case 'array':
        return _array(s, name);
      case 'string':
        return _string(s, name);
      case 'number':
        return _primitive('number');
      case 'integer':
        return _primitive('integer');
      case 'boolean':
        return _primitive('boolean');
      case 'null':
        return _primitive('null');
      case null:
        if (s['properties'] is Map) return _object(s, name);
        if (s['items'] != null || s['prefixItems'] != null) {
          return _array(s, name);
        }
        return _primitive('value');
      default:
        throw FormatException('unsupported schema type: $type');
    }
  }

  String _object(Map<String, dynamic> s, String name) {
    final rawProps = s['properties'];
    final props = rawProps is Map
        ? Map<String, dynamic>.from(rawProps)
        : <String, dynamic>{};
    if (props.isEmpty) {
      final additional = s['additionalProperties'];
      if (additional is Map && additional.isNotEmpty) {
        final value = _visit(additional, '$name-value');
        final kv = '${_primitive('string')} ":" space $value';
        return _define(name, '"{" space ( $kv ( "," space $kv )* )? "}" space');
      }
      return _primitive('object');
    }

    final required = {
      if (s['required'] is List)
        for (final r in s['required'] as List)
          if (r is String) r,
    };
    _primitive('space');
    final kv = <String, String>{};
    for (final entry in props.entries) {
      final key = entry.key;
      final value = _visit(entry.value, '$name-${_sanitize(key)}');
      kv[key] = _define('$name-${_sanitize(key)}-kv',
          '${_literal(jsonEncode(key))} space ":" space $value');
    }

    final req = [
      for (final k in props.keys)
        if (required.contains(k)) kv[k]!
    ];
    final opt = [
      for (final k in props.keys)
        if (!required.contains(k)) kv[k]!
    ];

    final body = StringBuffer('"{" space ');
    if (req.isNotEmpty) {
      body.write(req.join(' "," space '));
      for (final o in opt) {
        body.write(' ( "," space $o )?');
      }
    } else {
      // No required key: any one optional key may come first.
      final starts = <String>[];
      for (var i = 0; i < opt.length; i++) {
        final rest = [
          for (final o in opt.sublist(i + 1)) '( "," space $o )?',
        ];
        starts.add([opt[i], ...rest].join(' '));
      }
      body.write('( ${starts.join(' | ')} )?');
    }
    body.write(' "}" space');
    return _define(name, body.toString());
  }

  String _array(Map<String, dynamic> s, String name) {
    _primitive('space');
    final prefix = s['prefixItems'];
    if (prefix is List && prefix.isNotEmpty) {
      final items = [
        for (var i = 0; i < prefix.length; i++)
          _visit(prefix[i], '$name-tuple-$i'),
      ];
      return _define(name, '"[" space ${items.join(' "," space ')} "]" space');
    }
    final item = _visit(s['items'], '$name-item');
    final minItems = _int(s['minItems']) ?? 0;
    final maxItems = _int(s['maxItems']);
    if (maxItems != null && maxItems < minItems) {
      throw const FormatException('maxItems is smaller than minItems');
    }
    if (maxItems == 0) return _define(name, '"[" space "]" space');

    final more = '( "," space $item )';
    final restMin = minItems > 0 ? minItems - 1 : 0;
    final restMax = maxItems == null ? '' : '${maxItems - 1}';
    final rest = (restMin == 0 && maxItems == null)
        ? '$more*'
        : '$more{$restMin,$restMax}';
    final list = '$item $rest';
    final inner = minItems == 0 ? '( $list )?' : list;
    return _define(name, '"[" space $inner "]" space');
  }

  String _string(Map<String, dynamic> s, String name) {
    final minLength = _int(s['minLength']);
    final maxLength = _int(s['maxLength']);
    if (minLength == null && maxLength == null) return _primitive('string');
    _primitive('char');
    _primitive('space');
    final reps = '{${minLength ?? 0},${maxLength ?? ''}}';
    return _define(name, '"\\"" char$reps "\\"" space');
  }

  String _ref(String ref) {
    final key = "${identityHashCode(_schemaRoot)}:$ref";
    final existing = _refs[key];
    if (existing != null) return existing;
    final match = RegExp(r'^#/(\$defs|definitions)/(.+)$').firstMatch(ref);
    if (match == null) {
      throw FormatException('unsupported \$ref: $ref');
    }
    final defs = _schemaRoot[match.group(1)!];
    final target = defs is Map ? defs[match.group(2)!] : null;
    if (target is! Map) throw FormatException('\$ref not found: $ref');
    // Reserve the name first so recursive schemas refer to it.
    final name = _name('ref-${_sanitize(match.group(2)!)}');
    _refs[key] = name;
    _rules[name] = '';
    final expr = _visit(target, '$name-def');
    _rules[name] = expr;
    return name;
  }

  Map<String, dynamic> _mergeAllOf(Map<String, dynamic> s, List allOf) {
    final props = <String, dynamic>{};
    final required = <String>{};
    void add(dynamic part) {
      if (part is! Map) return;
      var p = Map<String, dynamic>.from(part);
      final ref = p[r'$ref'];
      if (ref is String) {
        final match = RegExp(r'^#/(\$defs|definitions)/(.+)$').firstMatch(ref);
        final defs = match == null ? null : _schemaRoot[match.group(1)!];
        final target = defs is Map ? defs[match!.group(2)!] : null;
        if (target is! Map) throw FormatException('\$ref not found: $ref');
        p = Map<String, dynamic>.from(target);
      }
      if (p['type'] != null && p['type'] != 'object') {
        throw const FormatException('allOf is only supported for objects');
      }
      if (p['properties'] is Map) {
        props.addAll(Map<String, dynamic>.from(p['properties'] as Map));
      }
      if (p['required'] is List) {
        required.addAll((p['required'] as List).whereType<String>());
      }
      if (p['allOf'] is List) (p['allOf'] as List).forEach(add);
    }

    add({...s}..remove('allOf'));
    allOf.forEach(add);
    return {
      'type': 'object',
      'properties': props,
      'required': required.toList(),
    };
  }

  // ── Rules ───────────────────────────────────────────────────────────

  /// Adds the primitive rule [name] (and what it uses); returns its name.
  String _primitive(String name) {
    if (_rules.containsKey(name)) return name;
    _rules[name] = _primitives[name]!;
    for (final dep in _deps[name]!) {
      _primitive(dep);
    }
    return name;
  }

  /// Defines a rule with [body], reusing an identical one.
  String _define(String name, String body) {
    final same = _bodies[body];
    if (same != null) return same;
    final unique = _name(name);
    _rules[unique] = body;
    _bodies[body] = unique;
    return unique;
  }

  String _name(String wanted) {
    final base = _sanitize(wanted);
    var name = base;
    var i = 1;
    while (_rules.containsKey(name) || _primitives.containsKey(name)) {
      name = '$base-${i++}';
    }
    return name;
  }

  String _render() {
    final b = StringBuffer()..writeln('root ::= ${_rules['root']}');
    for (final entry in _rules.entries) {
      if (entry.key == 'root') continue;
      b.writeln('${entry.key} ::= ${entry.value}');
    }
    return b.toString();
  }

  static String _sanitize(String s) {
    final clean = s.replaceAll(RegExp(r'[^a-zA-Z0-9-]+'), '-');
    final trimmed = clean.replaceAll(RegExp(r'^-+|-+$'), '');
    return trimmed.isEmpty ? 'r' : trimmed;
  }

  static int? _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : null);

  /// A GBNF string literal for [text].
  static String _literal(String text) {
    final b = StringBuffer('"');
    for (final rune in text.runes) {
      switch (rune) {
        case 0x22:
          b.write(r'\"');
        case 0x5C:
          b.write(r'\\');
        case 0x0A:
          b.write(r'\n');
        case 0x0D:
          b.write(r'\r');
        case 0x09:
          b.write(r'\t');
        default:
          if (rune < 0x20) {
            b.write('\\x${rune.toRadixString(16).padLeft(2, '0')}');
          } else {
            b.writeCharCode(rune);
          }
      }
    }
    b.write('"');
    return b.toString();
  }
}
