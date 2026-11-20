class ChatSession {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? lastMessage;

  /// Summary of the messages that no longer fit in the context window.
  final HistorySummary? historySummary;

  ChatSession({
    required this.id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.lastMessage,
    this.historySummary,
  })  : title = title ?? 'New Chat',
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'lastMessage': lastMessage,
        ...?historySummary?.toSession(),
      };

  factory ChatSession.fromMap(Map<dynamic, dynamic> map) => ChatSession(
        id: map['id'] ?? '',
        title: map['title'] ?? 'New Chat',
        createdAt: DateTime.tryParse(map['createdAt'] ?? '') ?? DateTime.now(),
        updatedAt: DateTime.tryParse(map['updatedAt'] ?? '') ?? DateTime.now(),
        lastMessage: map['lastMessage'],
        historySummary: HistorySummary.fromSession(map),
      );

  ChatSession copyWith({
    String? title,
    DateTime? updatedAt,
    String? lastMessage,
    HistorySummary? historySummary,
    bool clearSummary = false,
  }) =>
      ChatSession(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
        lastMessage: lastMessage ?? this.lastMessage,
        historySummary:
            clearSummary ? null : historySummary ?? this.historySummary,
      );
}

/// Summary of the oldest messages of a chat, the ones that no longer fit in
/// the model's context window. Kept with the chat session and given to the
/// model in the system prompt, so a long chat keeps its earlier facts.
class HistorySummary {
  /// What the earlier messages said.
  final String text;

  /// Id of the last message the summary covers; every message up to it is
  /// left out of the prompt.
  final String upToMessageId;

  const HistorySummary({required this.text, required this.upToMessageId});

  static HistorySummary? fromSession(Map<dynamic, dynamic> map) {
    final text = map['summary'];
    final upTo = map['summaryUpTo'];
    if (text is! String || upTo is! String || text.trim().isEmpty) {
      return null;
    }
    return HistorySummary(text: text, upToMessageId: upTo);
  }

  Map<String, dynamic> toSession() =>
      {'summary': text, 'summaryUpTo': upToMessageId};

  /// Number of leading messages of [ids] the summary covers, or null when
  /// its last message is gone (deleted or edited away): it no longer matches
  /// the chat and must be made again.
  int? coveredIn(List<String> ids) {
    final i = ids.indexOf(upToMessageId);
    return i < 0 ? null : i + 1;
  }

  /// [systemPrompt] with the summary appended.
  String withSystemPrompt(String systemPrompt) {
    final base = systemPrompt.trimRight();
    return '${base.isEmpty ? '' : '$base\n\n'}'
        'Summary of the earlier part of this conversation, which is no '
        'longer shown:\n${text.trim()}';
  }
}
