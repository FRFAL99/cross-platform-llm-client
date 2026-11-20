/// Builds the requests that summarize dropped messages.
class HistorySummarizer {
  HistorySummarizer._();

  /// Longest summary, in tokens.
  static const maxSummaryTokens = 384;

  static const systemPrompt =
      'You summarize conversations. Write a short summary of the conversation '
      'below for the assistant that will continue it. Keep names, numbers, '
      'decisions, facts about the user, open questions and anything the '
      'user asked to remember. Write it in the language of the conversation. '
      'Reply with the summary only, no introduction.';

  /// Splits [messages] (with their token counts) into consecutive groups
  /// whose transcript fits in [budget] tokens next to the previous summary,
  /// so each group is summarized in one request, folding the summary along.
  /// A single message larger than the budget gets a group of its own (the
  /// engine trims the middle of a prompt that is too long).
  static List<List<Map<String, String>>> chunks(
    List<Map<String, String>> messages,
    List<int> tokens, {
    required int budget,
  }) {
    final groups = <List<Map<String, String>>>[];
    var current = <Map<String, String>>[];
    var used = 0;
    for (var i = 0; i < messages.length; i++) {
      final cost = tokens[i] + 4;
      if (current.isNotEmpty && used + cost > budget) {
        groups.add(current);
        current = [];
        used = 0;
      }
      current.add(messages[i]);
      used += cost;
    }
    if (current.isNotEmpty) groups.add(current);
    return groups;
  }

  /// The request for one group: the summary so far plus the transcript.
  static String prompt(String? previous, List<Map<String, String>> messages) {
    final b = StringBuffer();
    if (previous != null && previous.trim().isNotEmpty) {
      b
        ..writeln('Summary of the conversation so far:')
        ..writeln(previous.trim())
        ..writeln()
        ..writeln('It continues:');
    } else {
      b.writeln('Conversation:');
    }
    for (final m in messages) {
      final who = m['role'] == 'assistant' ? 'Assistant' : 'User';
      b.writeln('$who: ${(m['content'] ?? '').trim()}');
    }
    b
      ..writeln()
      ..write(previous != null && previous.trim().isNotEmpty
          ? 'Write the updated summary of the whole conversation.'
          : 'Write the summary.');
    return b.toString();
  }
}
