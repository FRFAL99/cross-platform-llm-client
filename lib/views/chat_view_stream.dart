part of 'chat_view.dart';

// Chat screen: model loading, the empty state and the reply being written.

extension _StreamSection on ChatView {
  // ── Model Loading ──
  Widget _modelLoadingBar(BuildContext context, bool isDark) {
    return Obx(() {
      final inf = Get.find<InferenceService>();
      if (!inf.isLoadingModel.value) return const SizedBox.shrink();
      final pct = (inf.modelLoadProgress.value * 100).round();
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text('Loading model',
                  style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12.5,
                      color: Theme.of(context).hintColor,
                      fontWeight: FontWeight.w500)),
            ),
            Text('$pct%',
                style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12.5,
                    color: Theme.of(context).hintColor,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                  value: inf.modelLoadProgress.value,
                  backgroundColor: _sep(context),
                  color: _appleBlue(context),
                  minHeight: 3)),
        ]),
      );
    });
  }

  // ── Empty State ──
  Widget _emptyState(BuildContext context, bool isDark) =>
      const HomeEmptyState();

  // ── Streaming Bubble ──
  Widget _streamBubble(BuildContext context, String text, bool isDark) {
    final attType = controller.streamingAttachmentType.value;
    final clean = _cleanStream(text).trimLeft();
    final parts = splitThoughtTags(clean);
    final answer = parts.answer.trimLeft();
    final hasText = parts.hasThought || _hasPrintable(answer);

    // Matches ChatBubble's assistant layout: full-width text, no bubble.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!hasText)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: _typingHint(context, isDark, attachmentType: attType),
          )
        else ...[
          if (parts.hasThought)
            ThoughtDisclosure(
                thought: parts.thought,
                isThinking: parts.isThinking,
                styleSheet: _thoughtMd(context, isDark)),
          if (_hasPrintable(answer))
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                  child: MarkdownBody(
                      data: answer,
                      selectable: true,
                      styleSheet: _streamMd(context, isDark))),
              _BlinkingCursor(color: Theme.of(context).hintColor),
            ]),
        ],
        if (hasText)
          Obx(() {
            final inf = Get.find<InferenceService>();
            if (inf.tokensPerSecond.value <= 0) {
              return const SizedBox(height: 28);
            }
            return SizedBox(
              height: 28,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    '${inf.tokensPerSecond.value.toStringAsFixed(1)} tok/s'
                    '${controller.summarizedMessages.value > 0 ? ' · ${controller.summarizedMessages.value} older messages summarized' : ''}'
                    '${inf.droppedHistoryMessages.value > 0 ? ' · ${inf.droppedHistoryMessages.value} older messages out of memory' : ''}',
                    style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        color:
                            Theme.of(context).hintColor.withValues(alpha: 0.8),
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ),
            );
          }),
      ]),
    );
  }

  Widget _typingHint(BuildContext context, bool isDark,
      {String? attachmentType}) {
    final msg = attachmentType == 'image'
        ? 'Reading image…'
        : attachmentType == 'audio'
            ? 'Listening to audio…'
            : attachmentType == 'summary'
                ? 'Summarizing earlier messages…'
                : null;
    if (msg == null) return _TypingDots(isDark: isDark);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _TypingDots(isDark: isDark),
      const SizedBox(width: 10),
      Flexible(
          child: Text(msg,
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  color: Theme.of(context).hintColor,
                  fontWeight: FontWeight.w400))),
    ]);
  }

  // ── Markdown styles ──
  MarkdownStyleSheet _streamMd(BuildContext c, bool isDark) =>
      ChatBubble.answerStyle(c);

  MarkdownStyleSheet _thoughtMd(BuildContext c, bool isDark) {
    final muted = Theme.of(c).hintColor;
    final base =
        TextStyle(fontFamily: 'Inter', fontSize: 13, color: muted, height: 1.4);
    final codeBg = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA);
    return MarkdownStyleSheet.fromTheme(Theme.of(c)).copyWith(
        p: base,
        strong: base.copyWith(fontWeight: FontWeight.w600),
        em: base.copyWith(fontStyle: FontStyle.italic),
        listBullet: base,
        code: TextStyle(
            fontFamily: 'FiraCode',
            fontSize: 11,
            color: muted,
            backgroundColor: codeBg),
        codeblockDecoration: BoxDecoration(
            color: codeBg, borderRadius: BorderRadius.circular(10)));
  }

  // ── Helpers ──
  String _cleanStream(String t) => t
      .replaceAll(
          RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]'), '')
      .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
      .replaceAll('\uFFFD', '')
      .replaceAll('<|endoftext|>', '')
      .replaceAll('<|im_end|>', '')
      .replaceAll('<|end|>', '');

  bool _hasPrintable(String t) {
    for (final r in t.runes) {
      if (r > 32 &&
          r != 0x7F &&
          r != 0x200B &&
          r != 0x200C &&
          r != 0x200D &&
          r != 0xFEFF &&
          r != 0xFFFD) {
        return true;
      }
    }
    return false;
  }
}

// ── Typing Dots ──
class _TypingDots extends StatefulWidget {
  final bool isDark;
  const _TypingDots({required this.isDark});
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final t = ((_c.value - i * 0.2) % 1.0).clamp(0.0, 1.0);
                final pulse = math.sin(t * math.pi).clamp(0.0, 1.0);
                return Padding(
                    padding: EdgeInsets.only(right: i < 2 ? 5 : 0),
                    child: Opacity(
                        opacity: 0.25 + 0.75 * pulse,
                        child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: widget.isDark
                                    ? Colors.white.withValues(alpha: 0.6)
                                    : Colors.black.withValues(alpha: 0.35)))));
              }));
        });
  }
}

// ── Blinking Cursor ──
class _BlinkingCursor extends StatefulWidget {
  final Color color;
  const _BlinkingCursor({required this.color});
  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Opacity(
            opacity: _c.value,
            child: Container(
                width: 2,
                height: 16,
                margin: const EdgeInsets.only(left: 2, bottom: 2),
                decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(1)))));
  }
}
