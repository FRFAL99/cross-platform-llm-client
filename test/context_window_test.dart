import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/context_window.dart';

void main() {
  List<Map<String, String>> chat(int n) => [
        for (var i = 0; i < n; i++)
          {'role': i.isEven ? 'user' : 'assistant', 'content': 'm$i'}
      ];

  int keep(List<Map<String, String>> h, List<int> tokens,
          {int ctx = 1000, int reserve = 100}) =>
      ContextWindow.firstToKeep(
        history: h,
        messageTokens: tokens,
        systemTokens: 50,
        promptTokens: 50,
        contextTokens: ctx,
        reserveTokens: reserve,
      );

  test('keeps everything when it fits', () {
    expect(keep(chat(6), List.filled(6, 50)), 0);
  });

  test('drops the oldest messages first, whole messages only', () {
    // Budget: 1000 - 100 - 50 - 50 - 24 = 776; each message costs 108.
    // 7 fit (756); the 8th oldest doesn't.
    final h = chat(10);
    final from = keep(h, List.filled(10, 100));
    // The 7 newest are indices 3..9, but 3 is a reply: start at its
    // successor, a user message.
    expect(from, 4);
  });

  test('never starts the kept history with an assistant reply', () {
    final h = chat(10);
    final from = keep(h, List.filled(10, 100));
    expect(h[from]['role'], 'user');
  });

  test('one huge old message does not push out the newer ones', () {
    final tokens = [5000, 10, 10, 10];
    expect(keep(chat(4), tokens), 2,
        reason: 'index 1 is a reply whose question was dropped');
  });

  test('reserve is capped at half the context', () {
    // reserve 4000 would leave nothing; capped to 500 of 1000.
    expect(keep(chat(2), [10, 10], reserve: 4000), 0);
  });
}
