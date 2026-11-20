import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/utils/history_trimmer.dart';

Map<String, String> msg(String role, int chars) =>
    {'role': role, 'content': 'x' * chars};

void main() {
  test('keeps everything when it fits', () {
    final history = [msg('user', 40), msg('assistant', 40), msg('user', 40)];
    expect(trimHistoryToBudget(history, 1000), history);
  });

  test('drops the oldest messages first and keeps the new prompt', () {
    final history = [
      msg('user', 400), // 104 tokens each
      msg('assistant', 400),
      msg('user', 400),
      msg('assistant', 400),
      msg('user', 400),
    ];
    final trimmed = trimHistoryToBudget(history, 320);
    expect(trimmed.length, 3);
    expect(trimmed, history.sublist(2));
  });

  test('never starts with an assistant message', () {
    final history = [
      msg('user', 400),
      msg('assistant', 400),
      msg('user', 400),
    ];
    // Room for the last two messages, but that would start with assistant.
    final trimmed = trimHistoryToBudget(history, 220);
    expect(trimmed.length, 1);
    expect(trimmed.first['role'], 'user');
  });

  test('cuts an oversized prompt from the start, keeping its end', () {
    final prompt = '${'a' * 1000}QUESTION';
    final trimmed = trimHistoryToBudget([
      msg('user', 40),
      {'role': 'user', 'content': prompt},
    ], 50);
    expect(trimmed.length, 1);
    expect(trimmed.first['content']!.endsWith('QUESTION'), isTrue);
    expect(trimmed.first['content']!.length, 184);
  });

  test('empty history stays empty', () {
    expect(trimHistoryToBudget(const [], 100), isEmpty);
  });
}
