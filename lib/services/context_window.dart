/// Fits a conversation into the model's context window, a message at a time.
class ContextWindow {
  ContextWindow._();

  /// Chat-template tokens around each message (role markers, separators).
  static const tokensPerMessage = 8;

  /// Index of the oldest history message to keep so that the system prompt,
  /// the kept history, the new prompt and [reserveTokens] for the reply fit
  /// in [contextTokens]. Newest messages win; a kept history never starts
  /// with an assistant reply (its question would be missing). Returns
  /// `history.length` when nothing fits.
  static int firstToKeep({
    required List<Map<String, String>> history,
    required List<int> messageTokens,
    required int systemTokens,
    required int promptTokens,
    required int contextTokens,
    required int reserveTokens,
  }) {
    final reserve = reserveTokens.clamp(64, contextTokens ~/ 2);
    var left = contextTokens -
        reserve -
        systemTokens -
        promptTokens -
        3 * tokensPerMessage;
    var keepFrom = history.length;
    for (var i = history.length - 1; i >= 0; i--) {
      final cost = messageTokens[i] + tokensPerMessage;
      if (cost > left) break;
      left -= cost;
      keepFrom = i;
    }
    if (keepFrom < history.length && history[keepFrom]['role'] == 'assistant') {
      keepFrom++;
    }
    return keepFrom;
  }
}
