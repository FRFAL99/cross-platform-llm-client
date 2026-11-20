import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/server/tool_calling.dart';

void main() {
  const names = ['get_weather', 'search'];

  group('ToolCalling.parse', () {
    test('reads <tool_call> blocks and keeps surrounding text', () {
      final r = ToolCalling.parse(
        'Sure.\n<tool_call>\n{"name": "get_weather", "arguments": {"city": "Rome"}}\n</tool_call>\n'
        '<tool_call>{"name": "search", "arguments": "{\\"q\\": \\"x\\"}"}</tool_call>',
        names,
      );
      expect(r.content, 'Sure.');
      expect(r.calls.map((c) => c.name), ['get_weather', 'search']);
      expect(jsonDecode(r.calls[0].arguments), {'city': 'Rome'});
      expect(jsonDecode(r.calls[1].arguments), {'q': 'x'});
      expect(r.calls[0].id, isNot(r.calls[1].id));
    });

    test('accepts a missing closing tag at the end', () {
      final r = ToolCalling.parse(
          '<tool_call>{"name": "search", "arguments": {}}', names);
      expect(r.calls.single.name, 'search');
      expect(r.content, isNull);
    });

    test('reads bare JSON, fenced JSON, parameters and Mistral calls', () {
      expect(
          ToolCalling.parse(
                  '{"name": "search", "parameters": {"q": "a"}}', names)
              .calls
              .single
              .arguments,
          '{"q":"a"}');
      expect(
          ToolCalling.parse(
                  '```json\n{"name": "search", "arguments": {}}\n```', names)
              .calls,
          hasLength(1));
      expect(
          ToolCalling.parse(
                  '[TOOL_CALLS][{"name": "search", "arguments": {}}, '
                  '{"name": "get_weather", "arguments": {"city": "Oslo"}}]',
                  names)
              .calls,
          hasLength(2));
    });

    test('leaves plain text and unknown functions alone', () {
      expect(ToolCalling.parse('Hello there', names).calls, isEmpty);
      final r = ToolCalling.parse('{"name": "rm_rf", "arguments": {}}', names);
      expect(r.calls, isEmpty);
      expect(r.content, '{"name": "rm_rf", "arguments": {}}');
      expect(ToolCalling.parse('{"answer": 42}', names).calls, isEmpty);
    });
  });

  group('ToolCalling.parseTools / parseToolChoice', () {
    test('parses OpenAI tools and rejects malformed ones', () {
      final tools = ToolCalling.parseTools([
        {
          'type': 'function',
          'function': {
            'name': 'search',
            'parameters': {'type': 'object'}
          }
        }
      ]);
      expect(tools.single.name, 'search');
      expect(() => ToolCalling.parseTools({}), throwsFormatException);
      expect(
          () => ToolCalling.parseTools([
                {'type': 'function', 'function': {}}
              ]),
          throwsFormatException);
    });

    test('tool_choice forms', () {
      final tools = [const ToolSpec('search')];
      expect(ToolCalling.parseToolChoice(null, tools).mode, 'auto');
      expect(ToolCalling.parseToolChoice('none', tools).disabled, isTrue);
      final forced = ToolCalling.parseToolChoice({
        'type': 'function',
        'function': {'name': 'search'}
      }, tools);
      expect(forced.function, 'search');
      expect(ToolCalling.systemPrompt(tools, forced),
          contains('You must call the function "search"'));
      expect(() => ToolCalling.parseToolChoice('maybe', tools),
          throwsFormatException);
      expect(
          () => ToolCalling.parseToolChoice({
                'type': 'function',
                'function': {'name': 'other'}
              }, tools),
          throwsFormatException);
    });
  });

  group('ToolCallStreamFilter', () {
    String run(List<String> tokens, ToolCallStreamFilter f) =>
        tokens.map(f.add).join();

    test('passes plain text through, holding back only a partial tag', () {
      final f = ToolCallStreamFilter();
      expect(f.add('Hello '), 'Hello ');
      expect(f.add('world <tool'), 'world ');
      expect(f.add('s are fun'), '<tools are fun');
      expect(f.unsent, '');
    });

    test('stops at a tool call and keeps it out of the stream', () {
      final f = ToolCallStreamFilter();
      final shown = run(
          ['Checking', '.<tool_', 'call>{"name":', '"search"}</tool_call>'], f);
      expect(shown, 'Checking.');
      expect(f.text, contains('<tool_call>'));
    });

    test('holds back a reply that starts like JSON', () {
      final f = ToolCallStreamFilter();
      expect(run(['  {"name"', ': "search"}'], f), '');
      expect(f.unsent, '  {"name": "search"}');
    });
  });
}
