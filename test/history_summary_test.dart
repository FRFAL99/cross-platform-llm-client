import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/models/chat_session.dart';
import 'package:privatelm/services/history_summary.dart';

void main() {
  List<Map<String, String>> chat(int n) => [
        for (var i = 0; i < n; i++)
          {'role': i.isEven ? 'user' : 'assistant', 'content': 'm$i'}
      ];

  group('HistorySummary', () {
    const summary = HistorySummary(text: 'Ada likes tea.', upToMessageId: 'b');

    test('covers the messages up to its last one', () {
      expect(summary.coveredIn(['a', 'b', 'c', 'd']), 2);
    });

    test('no longer matches when its last message is gone', () {
      expect(summary.coveredIn(['a', 'c', 'd']), isNull);
    });

    test('goes after the system prompt', () {
      final prompt = summary.withSystemPrompt('You are helpful.');
      expect(prompt, startsWith('You are helpful.\n\n'));
      expect(prompt, endsWith('Ada likes tea.'));
      expect(summary.withSystemPrompt(''), isNot(startsWith('\n')));
    });

    test('is saved with the chat session and survives copyWith', () {
      final session = ChatSession(id: 's', historySummary: summary);
      final loaded = ChatSession.fromMap(session.toMap());
      expect(loaded.historySummary?.text, 'Ada likes tea.');
      expect(loaded.historySummary?.upToMessageId, 'b');

      final renamed = loaded.copyWith(title: 'Tea');
      expect(renamed.historySummary?.text, 'Ada likes tea.');
      expect(renamed.copyWith(clearSummary: true).historySummary, isNull);
    });

    test('old sessions without a summary load as before', () {
      final loaded = ChatSession.fromMap({'id': 's', 'title': 'Old'});
      expect(loaded.historySummary, isNull);
      expect(loaded.toMap().containsKey('summary'), isFalse);
    });
  });

  group('HistorySummarizer', () {
    test('keeps everything in one request when it fits', () {
      final groups =
          HistorySummarizer.chunks(chat(6), List.filled(6, 10), budget: 1000);
      expect(groups, hasLength(1));
      expect(groups.single, hasLength(6));
    });

    test('splits long runs in order, each within the budget', () {
      final messages = chat(10);
      final groups = HistorySummarizer.chunks(messages, List.filled(10, 96),
          budget: 300); // 100 per message: 3 per request
      expect(groups.map((g) => g.length), [3, 3, 3, 1]);
      expect(groups.expand((g) => g).toList(), messages);
    });

    test('a message larger than the budget gets a request of its own', () {
      final groups =
          HistorySummarizer.chunks(chat(3), [10, 5000, 10], budget: 300);
      expect(groups.map((g) => g.length), [1, 1, 1]);
    });

    test('the request carries the summary so far and the transcript', () {
      final first = HistorySummarizer.prompt(null, chat(2));
      expect(first, contains('User: m0'));
      expect(first, contains('Assistant: m1'));
      expect(first, isNot(contains('so far')));

      final next = HistorySummarizer.prompt('Ada likes tea.', chat(2));
      expect(next, contains('so far:\nAda likes tea.'));
      expect(next, contains('updated summary'));
    });
  });
}
