// Writes the grammar test cases for scripts/grammar_check.cpp (in the
// llama_flutter_android plugin): each block is a grammar from JsonGrammar
// and strings it must or must not accept. Run from the repo root:
//   dart --packages=.dart_tool/package_config.json tool/grammar_cases.dart /tmp/cases.txt
//   grammar_check /tmp/cases.txt
// (a newline inside a case is written as U+23CE).
import 'dart:io';
import 'package:privatelm/services/server/json_grammar.dart';
import 'package:privatelm/services/server/tool_calling.dart';

final out = StringBuffer();
void block(String name, String gbnf, List<String> yes, List<String> no) {
  out.writeln('=== $name');
  out.write(gbnf);
  out.writeln('---');
  for (final y in yes) {
    out.writeln('+ ${y.replaceAll('\n', '⏎')}');
  }
  for (final n in no) {
    out.writeln('- ${n.replaceAll('\n', '⏎')}');
  }
}

void main(List<String> args) {
  block('any object', JsonGrammar.anyObject(), [
    '{}',
    '{"a": 1}',
    ' {"a": [1, 2.5, -3e10, "x\\"y", true, null, {"b": {}}]}',
    '{\n  "a": "b"\n}',
  ], [
    '',
    '[]',
    '"x"',
    '{"a": 1',
    '{"a": 1} trailing',
    '{a: 1}',
    '{"a": 01}'
  ]);

  final person = {
    'type': 'object',
    'properties': {
      'name': {'type': 'string', 'minLength': 1, 'maxLength': 5},
      'age': {'type': 'integer'},
      'tags': {
        'type': 'array',
        'items': {'type': 'string'},
        'maxItems': 2
      },
      'role': {
        'enum': ['admin', 'user']
      },
      'nick': {
        'type': ['string', 'null']
      },
    },
    'required': ['name', 'age'],
  };
  block('person', JsonGrammar.forSchema(person), [
    '{"name": "Ann", "age": 30}',
    '{"name": "Ann", "age": -1, "tags": ["a", "b"], "role": "admin", "nick": null}',
    '{"name": "Ann", "age": 3, "role": "user"}',
    '{"name":"Ann","age":3,"nick":"x"}',
  ], [
    '{"age": 30, "name": "Ann"}',
    '{"name": "", "age": 30}',
    '{"name": "Annabel", "age": 30}',
    '{"name": "Ann"}',
    '{"name": "Ann", "age": 3.5}',
    '{"name": "Ann", "age": 3, "tags": ["a", "b", "c"]}',
    '{"name": "Ann", "age": 3, "role": "root"}',
    '{"name": "Ann", "age": 3, "extra": 1}',
  ]);

  block(
      'all optional',
      JsonGrammar.forSchema({
        'type': 'object',
        'properties': {
          'a': {'type': 'boolean'},
          'b': {'type': 'number'},
          'c': {'const': 'k'}
        },
      }),
      [
        '{}',
        '{"a": true}',
        '{"b": 1.5}',
        '{"c": "k"}',
        '{"a": false, "c": "k"}',
        '{"a": true, "b": 2, "c": "k"}'
      ],
      [
        '{"c": "k", "a": true}',
        '{,"a": true}',
        '{"c": "x"}'
      ]);

  block(
      'array minItems',
      JsonGrammar.forSchema({
        'type': 'array',
        'items': {'type': 'integer'},
        'minItems': 2,
        'maxItems': 3,
      }),
      ['[1, 2]', '[1,2,3]'],
      ['[]', '[1]', '[1, 2, 3, 4]']);

  block('array any', JsonGrammar.forSchema({'type': 'array'}),
      ['[]', '[1, "a", {}]'], ['{}']);

  block(
      'defs and anyOf',
      JsonGrammar.forSchema({
        r'$defs': {
          'node': {
            'type': 'object',
            'properties': {
              'v': {'type': 'integer'},
              'next': {
                'anyOf': [
                  {r'$ref': r'#/$defs/node'},
                  {'type': 'null'}
                ]
              },
            },
            'required': ['v', 'next'],
          },
        },
        r'$ref': r'#/$defs/node',
      }),
      ['{"v": 1, "next": null}', '{"v": 1, "next": {"v": 2, "next": null}}'],
      ['{"v": 1}', '{"v": 1, "next": 3}']);

  block(
      'allOf',
      JsonGrammar.forSchema({
        'allOf': [
          {
            'type': 'object',
            'properties': {
              'a': {'type': 'string'}
            },
            'required': ['a']
          },
          {
            'type': 'object',
            'properties': {
              'b': {'type': 'integer'}
            },
            'required': ['b']
          },
        ],
      }),
      ['{"a": "x", "b": 1}'],
      ['{"a": "x"}', '{"b": 1}']);

  block(
      'additionalProperties map',
      JsonGrammar.forSchema({
        'type': 'object',
        'additionalProperties': {'type': 'integer'},
      }),
      ['{}', '{"x": 1, "y": 2}'],
      ['{"x": "a"}']);

  block(
      'unicode and escapes',
      JsonGrammar.forSchema({
        'type': 'object',
        'properties': {
          'città "q"': {
            'enum': ['perché\n', 'a\\b']
          }
        },
        'required': ['città "q"'],
      }),
      [r'{"città \"q\"": "perché\n"}', r'{"città \"q\"": "a\\b"}'],
      [r'{"città \"q\"": "x"}']);

  final tools = [
    const ToolSpec('get_weather', parameters: {
      'type': 'object',
      'properties': {
        'city': {'type': 'string'},
        'unit': {
          'enum': ['c', 'f']
        },
      },
      'required': ['city'],
    }),
    const ToolSpec('ping'),
    const ToolSpec('noop', parameters: {'type': 'object', 'properties': {}}),
  ];
  block('tool calls', JsonGrammar.toolCalls(tools), [
    '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Rome"}}\n</tool_call>',
    '<tool_call>{"name": "ping", "arguments": {"anything": [1]}}</tool_call>',
    '<tool_call>\n{"name": "noop", "arguments": {}}\n</tool_call>\n<tool_call>\n{"name": "get_weather", "arguments": {"city": "Rome", "unit": "c"}}\n</tool_call>',
  ], [
    'Hello',
    '<tool_call>\n{"name": "nope", "arguments": {}}\n</tool_call>',
    '<tool_call>\n{"name": "get_weather", "arguments": {}}\n</tool_call>',
    '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Rome"}}\n',
    '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Rome"}}\n</tool_call> done',
  ]);
  block('tool only', JsonGrammar.toolCalls(tools, only: 'ping'), [
    '<tool_call>{"name": "ping", "arguments": {}}</tool_call>',
  ], [
    '<tool_call>{"name": "noop", "arguments": {}}</tool_call>'
  ]);

  File(args[0]).writeAsStringSync(out.toString());
}
