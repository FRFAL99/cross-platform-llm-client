import 'package:flutter_test/flutter_test.dart';
import 'package:onelm/services/server/json_grammar.dart';
import 'package:onelm/services/server/tool_calling.dart';

/// Rule names a grammar defines.
Set<String> rules(String gbnf) => {
      for (final line in gbnf.split('\n'))
        if (line.contains(' ::= ')) line.substring(0, line.indexOf(' ::= '))
    };

/// Every rule a grammar references must be defined (a bad reference makes
/// llama.cpp refuse the grammar). Literals and character classes are
/// stripped before looking for rule names.
void expectClosed(String gbnf) {
  final defined = rules(gbnf);
  for (final line in gbnf.split('\n')) {
    if (!line.contains(' ::= ')) continue;
    final body = line
        .substring(line.indexOf(' ::= ') + 5)
        .replaceAll(RegExp(r'"(?:[^"\\]|\\.)*"'), ' ')
        .replaceAll(RegExp(r'\[(?:[^\]\\]|\\.)*\]'), ' ')
        .replaceAll(RegExp(r'\{\d*,?\d*\}'), ' ');
    for (final m in RegExp(r'[a-zA-Z][a-zA-Z0-9-]*').allMatches(body)) {
      expect(defined, contains(m.group(0)), reason: 'in: $line');
    }
  }
  expect(defined.first, 'root');
}

void main() {
  test('any object', () {
    final g = JsonGrammar.anyObject();
    expect(g, startsWith('root ::= space? object\n'));
    expectClosed(g);
  });

  test('object schema: required in order, optional after', () {
    final g = JsonGrammar.forSchema({
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'age': {'type': 'integer'},
        'tags': {
          'type': 'array',
          'items': {'type': 'string'}
        },
      },
      'required': ['name', 'age'],
    });
    expectClosed(g);
    final root =
        g.split('\n').firstWhere((l) => l.startsWith('root-value ::='));
    expect(root, contains('root-value-name-kv "," space root-value-age-kv'));
    expect(root, contains('( "," space root-value-tags-kv )?'));
  });

  test('identical sub-schemas share one rule', () {
    final g = JsonGrammar.forSchema({
      'type': 'object',
      'properties': {
        'a': {
          'enum': ['x', 'y']
        },
        'b': {
          'enum': ['x', 'y']
        },
      },
    });
    expect(g, contains('root-value-a ::='));
    expect(g, isNot(contains('root-value-b ::=')));
    expectClosed(g);
  });

  test(r'recursive $ref', () {
    final g = JsonGrammar.forSchema({
      r'$defs': {
        'node': {
          'type': 'object',
          'properties': {
            'next': {
              'anyOf': [
                {r'$ref': r'#/$defs/node'},
                {'type': 'null'}
              ]
            },
          },
          'required': ['next'],
        },
      },
      r'$ref': r'#/$defs/node',
    });
    expectClosed(g);
    expect(g, contains('ref-node ::='));
  });

  test('string length and array bounds', () {
    final g = JsonGrammar.forSchema({
      'type': 'array',
      'items': {'type': 'string', 'minLength': 2, 'maxLength': 4},
      'minItems': 1,
      'maxItems': 3,
    });
    expectClosed(g);
    expect(g, contains('char{2,4}'));
    expect(g, contains('{0,2}'));
  });

  test('escapes keys and values in literals', () {
    final g = JsonGrammar.forSchema({
      'type': 'object',
      'properties': {
        'a "b"\n': {'const': 'c\\d'}
      },
      'required': ['a "b"\n'],
    });
    expectClosed(g);
    expect(g, contains(r'"\"a \\\"b\\\"\\n\""'));
    expect(g, contains(r'"\"c\\\\d\""'));
    expect(
        g
            .split('\n')
            .where((l) => l.isNotEmpty)
            .every((l) => l.contains(' ::= ')),
        isTrue,
        reason: 'no raw newline inside a rule');
  });

  test('unsupported schemas throw FormatException', () {
    expect(() => JsonGrammar.forSchema({'type': 'mystery'}),
        throwsFormatException);
    expect(() => JsonGrammar.forSchema({r'$ref': 'http://x/schema'}),
        throwsFormatException);
    expect(() => JsonGrammar.forSchema({r'$ref': r'#/$defs/missing'}),
        throwsFormatException);
  });

  group('tool calls', () {
    final tools = [
      const ToolSpec('get_weather', parameters: {
        'type': 'object',
        'properties': {
          'city': {'type': 'string'}
        },
        'required': ['city'],
      }),
      const ToolSpec('ping'),
    ];

    test('one alternative per tool inside <tool_call> tags', () {
      final g = JsonGrammar.toolCalls(tools);
      expectClosed(g);
      expect(g, startsWith('root ::= tool-call ( space tool-call )*'));
      expect(
          g, contains(r'"<tool_call>" space ( call-get-weather | call-ping )'));
      expect(g, contains(r'"\"get_weather\""'));
      expect(g, contains('"</tool_call>"'));
    });

    test('only the named function', () {
      final g = JsonGrammar.toolCalls(tools, only: 'ping');
      expect(g, isNot(contains('get_weather')));
      expect(() => JsonGrammar.toolCalls(tools, only: 'nope'),
          throwsFormatException);
    });

    test('tools with the same \$defs names stay apart', () {
      Map<String, dynamic> withDef(String type) => {
            r'$defs': {
              'v': {'type': type}
            },
            'type': 'object',
            'properties': {
              'v': {r'$ref': r'#/$defs/v'}
            },
            'required': ['v'],
          };
      final g = JsonGrammar.toolCalls([
        ToolSpec('a', parameters: withDef('string')),
        ToolSpec('b', parameters: withDef('integer')),
      ]);
      expectClosed(g);
      expect(g, contains('ref-v ::= string'));
      expect(g, contains('ref-v-1 ::= integer'));
    });

    test('trigger regex finds the opening tag', () {
      expect(RegExp(JsonGrammar.toolCallTrigger).hasMatch('Sure.<tool_call>'),
          isTrue);
    });
  });
}
