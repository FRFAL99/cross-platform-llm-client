part of 'chat_view.dart';

// Chat screen: the app bar and the model sheet.

extension _AppBarSection on ChatView {
  // ── AppBar ──
  PreferredSizeWidget _appBar(BuildContext context, bool isDark) {
    return AppBar(
      backgroundColor: isDark ? Colors.black : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(0.5),
        child: Obx(() => Container(
            height: 0.5,
            color: controller.messages.isEmpty
                ? Colors.transparent
                : _sep(context))),
      ),
      titleSpacing: 0,
      leadingWidth: 52,
      leading: IconButton(
        tooltip: 'Back',
        onPressed: () {
          FocusManager.instance.primaryFocus?.unfocus();
          Get.back();
        },
        icon: Icon(Icons.arrow_back_rounded,
            color: isDark ? Colors.white : Colors.black),
      ),
      title: Obx(() {
        final text = isDark ? Colors.white : Colors.black;
        // New chat: a plain title — the empty state carries the model.
        if (controller.messages.isEmpty) {
          return Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text('Try the model',
                style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    letterSpacing: -0.5,
                    color: text)),
          );
        }
        final sid = controller.currentSessionId.value;
        final info = _modelInfo(context);
        final title =
            controller.sessions.firstWhereOrNull((s) => s.id == sid)?.title ??
                'Chat';
        // Title + model line; tapping opens the model sheet.
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _showModelSheet(context),
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                          letterSpacing: -0.3,
                          color: text)),
                  const SizedBox(height: 1),
                  Row(children: [
                    Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle, color: info.dot)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(info.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 12.5,
                              color: Theme.of(context).hintColor)),
                    ),
                    Icon(Icons.expand_more_rounded,
                        size: 16, color: Theme.of(context).hintColor),
                  ]),
                ]),
          ),
        );
      }),
      actions: [
        Obx(() {
          if (controller.messages.isEmpty) return const SizedBox.shrink();
          final usage = _contextUsage();
          if (usage == null) return const SizedBox.shrink();
          final warn = usage.pct >= 0.75;
          return IconButton(
            tooltip: 'Context ${(usage.pct * 100).round()}% used',
            onPressed: () => _showModelSheet(context),
            icon: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                value: usage.pct < 0.02 ? 0.02 : usage.pct,
                strokeWidth: 2.4,
                strokeCap: StrokeCap.round,
                backgroundColor: _sep(context),
                color: warn
                    ? const Color(0xFFFF9500)
                    : Theme.of(context).hintColor,
              ),
            ),
          );
        }),
        Obx(() {
          // Already on a blank chat — a "new chat" button would only create
          // empty sessions.
          if (controller.messages.isEmpty) return const SizedBox.shrink();
          return IconButton(
              tooltip: 'New chat',
              icon: Icon(Icons.edit_square,
                  size: 20, color: isDark ? Colors.white : Colors.black),
              onPressed: () {
                Haptics.selectionClick();
                controller.createNewChat();
              });
        }),
        Builder(
          builder: (ctx) => IconButton(
            tooltip: 'Chats',
            onPressed: () {
              FocusManager.instance.primaryFocus?.unfocus();
              Scaffold.of(ctx).openEndDrawer();
            },
            icon: SidebarGlyph(color: isDark ? Colors.white : Colors.black),
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// Name and status colour of whatever will answer the next message.
  ({String name, String meta, Color dot, bool canUnload}) _modelInfo(
      BuildContext context) {
    final inf = Get.find<InferenceService>();
    const green = Color(0xFF34C759);
    const orange = Color(0xFFFF9500);
    String pretty(String n) =>
        n.replaceAll(RegExp(r'\.(gguf|bin)$', caseSensitive: false), '');

    if (inf.isLoadingModel.value) {
      return (
        name: 'Loading model…',
        meta: '${(inf.modelLoadProgress.value * 100).round()}%',
        dot: orange,
        canUnload: false,
      );
    }
    if (inf.isModelLoaded.value) {
      return (
        name: pretty(inf.loadedModelName.value),
        meta: [
          'Ready',
          Get.isRegistered<ClusterService>()
              ? Get.find<ClusterService>().splitSummary ??
                  (inf.isGpuAccelerated.value ? 'GPU' : 'CPU')
              : (inf.isGpuAccelerated.value ? 'GPU' : 'CPU'),
          'GGUF',
        ].join(' · '),
        dot: green,
        canUnload: true,
      );
    }
    return (
      name: 'No model loaded',
      meta: 'Load a model to continue this chat',
      dot: orange,
      canUnload: false,
    );
  }

  /// Local context-window usage, or null when it doesn't apply.
  ({int used, int total, double pct})? _contextUsage() {
    final settings = Get.find<SettingsController>();
    final inf = Get.find<InferenceService>();
    if (!inf.isModelLoaded.value) return null;
    final total = inf.contextTokensTotal.value > 0
        ? inf.contextTokensTotal.value
        : settings.contextSize.value;
    final est =
        controller.messages.fold<int>(0, (s, m) => s + m.content.length);
    final used = (inf.contextTokensUsed.value > 0
            ? inf.contextTokensUsed.value
            : (est / 4).ceil())
        .clamp(0, total)
        .toInt();
    final pct = total == 0 ? 0.0 : (used / total).clamp(0.0, 1.0).toDouble();
    return (used: used, total: total, pct: pct);
  }

  // ── Model sheet ──
  void _showModelSheet(BuildContext context) {
    Haptics.selectionClick();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
          child: Obx(() {
            final info = _modelInfo(ctx);
            final usage = _contextUsage();
            final text = isDark ? Colors.white : const Color(0xFF0B0B0C);
            final muted = Theme.of(ctx).hintColor;
            final warn = (usage?.pct ?? 0) >= 0.75;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                        color: _sep(ctx).withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 18),
                Text('Model',
                    style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: muted)),
                const SizedBox(height: 6),
                Text(info.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.3,
                        color: text)),
                const SizedBox(height: 4),
                Row(children: [
                  Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle, color: info.dot)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(info.meta,
                        style: TextStyle(
                            fontFamily: 'Inter', fontSize: 13, color: muted)),
                  ),
                ]),
                if (usage != null) ...[
                  const SizedBox(height: 22),
                  Row(children: [
                    Expanded(
                      child: Text('Context',
                          style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: muted)),
                    ),
                    Text('${_fmtK(usage.used)} / ${_fmtK(usage.total)} tokens',
                        style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 13,
                            color: warn ? const Color(0xFFFF9500) : muted,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                  ]),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: usage.pct,
                      minHeight: 5,
                      backgroundColor: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.black.withValues(alpha: 0.06),
                      color: warn ? const Color(0xFFFF9500) : _appleBlue(ctx),
                    ),
                  ),
                  if (warn) ...[
                    const SizedBox(height: 8),
                    Text('Almost full. Start a new chat for best results.',
                        style: TextStyle(
                            fontFamily: 'Inter', fontSize: 12.5, color: muted)),
                  ],
                ],
                const SizedBox(height: 24),
                Row(children: [
                  Expanded(
                    child: TonalButton.neutral(ctx, label: 'Switch model',
                        onTap: () {
                      Navigator.pop(ctx);
                      Get.find<HomeController>().openTab(AppTab.models);
                    }),
                  ),
                  if (info.canUnload) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: TonalButton.destructive(ctx, label: 'Unload',
                          onTap: () {
                        Navigator.pop(ctx);
                        Get.find<ModelController>().unloadModel();
                      }),
                    ),
                  ],
                ]),
              ],
            );
          }),
        ),
      ),
    );
  }

  String _fmtK(int v) => v >= 1000000
      ? '${(v / 1000000).toStringAsFixed(1)}M'
      : v >= 1000
          ? '${(v / 1000).toStringAsFixed(1)}K'
          : v.toString();
}
