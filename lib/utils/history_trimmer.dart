/// Keeps a chat history within a token budget before it is sent to a cloud
/// provider, so long chats don't overflow the model's context window (the
/// provider rejects the request) or resend the whole conversation every turn.
library;

/// Rough token estimate: about 4 characters per token for English text,
/// plus a few tokens of per-message overhead (role, separators).
int estimateTokens(String text) => (text.length / 4).ceil() + 4;

/// Returns the most recent messages of [history] that fit in [budgetTokens].
///
/// - The last message (the user's new prompt) is always kept, cut from the
///   start if it alone exceeds the budget.
/// - Older messages are dropped whole, oldest first.
/// - The result never starts with an assistant message: providers such as
///   Anthropic require the conversation to start with a user turn.
List<Map<String, String>> trimHistoryToBudget(
  List<Map<String, String>> history,
  int budgetTokens,
) {
  if (history.isEmpty) return const [];

  final last = history.last;
  final lastContent = last['content'] ?? '';
  var remaining = budgetTokens - estimateTokens(lastContent);
  if (remaining < 0) {
    // The prompt alone is too big: keep its end, which holds the question.
    final keepChars = ((budgetTokens - 4) * 4).clamp(0, lastContent.length);
    final start = lastContent.length - keepChars;
    return [
      {...last, 'content': lastContent.substring(start)},
    ];
  }

  var firstKept = history.length - 1;
  for (var i = history.length - 2; i >= 0; i--) {
    final cost = estimateTokens(history[i]['content'] ?? '');
    if (cost > remaining) break;
    remaining -= cost;
    firstKept = i;
  }
  while (firstKept < history.length - 1 &&
      history[firstKept]['role'] != 'user') {
    firstKept++;
  }
  return history.sublist(firstKept);
}
