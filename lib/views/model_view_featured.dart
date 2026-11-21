part of 'model_view.dart';

// Models screen: featured picks, model details and custom models.

extension _FeaturedSection on ModelView {
  // ── Featured picks ────────────────────────────────────────────────────

  static const _pitch = {
    'general': 'Best for chat',
    'vision': 'Understands photos',
    'uncensored': 'No filters',
  };

  /// Horizontal row of the recommended pick for each type.
  Widget _buildFeatured(BuildContext context) {
    final t = AppTokens.of(context);
    final picks = <AiModel>[];
    for (final type in ['general', 'vision', 'uncensored']) {
      final m = controller.availableModels
          .firstWhereOrNull((m) => m.recommendedFor.contains(type));
      if (m != null && !picks.contains(m)) picks.add(m);
    }
    if (picks.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
        child: Text('Recommended', style: t.label),
      ),
      SizedBox(
        height: 172,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          itemCount: picks.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, i) => _buildFeaturedCard(context, picks[i]),
        ),
      ),
      const SizedBox(height: 18),
    ]);
  }

  Widget _buildFeaturedCard(BuildContext context, AiModel model) {
    return Obx(() {
      final t = AppTokens.of(context);
      final (name, _) = _cleanName(model);
      final downloaded = controller.isDownloaded(model.filename);
      final downloading = controller.isDownloadingModel(model.filename);
      final busy = controller.isImporting.value ||
          Get.find<InferenceService>().isLoadingModel.value;
      final type = model.recommendedFor
          .firstWhere(_pitch.containsKey, orElse: () => 'general');
      final Widget action;
      if (downloading) {
        action = _DownloadRing(filename: model.filename);
      } else if (downloaded) {
        action = Icon(Icons.check_circle_rounded, size: 22, color: t.green);
      } else {
        action = _RoundIconButton(
          icon: Icons.arrow_downward_rounded,
          tooltip: 'Download',
          onPressed: busy ? null : () => _confirmDownload(context, model),
        );
      }
      return SizedBox(
        width: 168,
        child: Material(
          color: t.surface,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            splashFactory: NoSplash.splashFactory,
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            onTap: () => _showModelDetails(context, model,
                controller.modelSizeLabel(model), const [], busy, null),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ModelAvatar(name: name, size: 44),
                  const Spacer(),
                  Text(name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyStrong.copyWith(height: 1.25)),
                  const SizedBox(height: 2),
                  Text(_pitch[type]!, style: t.small),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: Text(controller.modelSizeLabel(model),
                          style: t.small.copyWith(fontFeatures: _tabular)),
                    ),
                    action,
                  ]),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  static final _quantPattern = RegExp(
      r'\b(I?Q\d(?:_[A-Z0-9]+)*|F16|FP16|BF16|F32)\b',
      caseSensitive: false);

  /// Short display name plus the variant (quant or format) shown as detail:
  /// "Gemma 3 1B Instruct (Q4_0)" → ("Gemma 3 1B", "Q4_0").
  (String, String?) _cleanName(AiModel model) {
    var raw = model.isImported ? _prettyModel(model.name) : model.name;
    String? variant;
    final quant = _quantPattern.firstMatch(raw);
    if (quant != null) variant = quant.group(0)!.toUpperCase();

    // Parenthesised extras: drop the quant, keep the rest.
    final extras = <String>[];
    raw = raw.replaceAllMapped(RegExp(r'\(([^)]*)\)'), (m) {
      final inner = m.group(1)!.trim();
      if (!_quantPattern.hasMatch(inner)) {
        extras.add(inner);
      }
      return ' ';
    });
    raw = raw.replaceAll(_quantPattern, ' ');

    // File-style names ("qwen2.5-1.5b-instruct"): split and capitalise.
    final fileStyle = model.isImported || raw == raw.toLowerCase();
    final words = raw
        .split(fileStyle ? RegExp(r'[\s_-]+') : RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .where((w) =>
            !{'instruct', 'uncensored', 'it', 'gguf'}.contains(w.toLowerCase()))
        .map((w) {
      if (!fileStyle) return w;
      if (RegExp(r'^(e?\d+(\.\d+)?[bm])$', caseSensitive: false).hasMatch(w)) {
        return w.toUpperCase();
      }
      return w[0].toUpperCase() + w.substring(1);
    }).toList();
    final name = words.join(' ').trim();
    final detail = [if (variant != null) variant, ...extras];
    return (
      name.isEmpty ? model.name : name,
      detail.isEmpty ? null : detail.join(' · ')
    );
  }

  /// ⋯ sheet: full description, details and the less common actions.
  void _showModelDetails(
    BuildContext context,
    AiModel model,
    String meta,
    List<(IconData, String, bool, VoidCallback)> actions,
    bool disabled,
    Widget? primaryAction, {
    VoidCallback? onLoad,
  }) {
    final downloaded = controller.isDownloaded(model.filename);
    showAppSheet<void>(
      context,
      title: model.name,
      subtitle: meta,
      builder: (ctx) {
        final t = AppTokens.of(ctx);
        final tags = _buildModelTags(ctx, model);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (model.description.trim().isNotEmpty)
              Text(model.description, style: t.body.copyWith(color: t.muted)),
            if (model.license.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('License: ${model.license}',
                  style: t.caption.copyWith(color: t.muted)),
            ],
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 6, runSpacing: 6, children: tags),
            ],
            if (onLoad != null) ...[
              const SizedBox(height: 18),
              PrimaryButton(
                label: 'Load model',
                icon: Icons.play_arrow_rounded,
                onPressed: () {
                  Navigator.pop(ctx);
                  onLoad();
                },
              ),
            ],
            if (!downloaded && !disabled) ...[
              const SizedBox(height: 18),
              PrimaryButton(
                label: 'Download',
                icon: Icons.arrow_downward_rounded,
                onPressed: () {
                  Navigator.pop(ctx);
                  _confirmDownload(context, model);
                },
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 18),
              AppGroup(dividerIndent: 60, children: [
                for (final (icon, label, destructive, onTap) in actions)
                  AppRow(
                    icon: icon,
                    title: label,
                    destructive: destructive,
                    onTap: disabled
                        ? null
                        : () {
                            Navigator.pop(ctx);
                            onTap();
                          },
                  ),
              ]),
            ],
          ],
        );
      },
    );
  }

  /// For a downloaded vision model whose vision file isn't on disk yet
  /// (e.g. the main file was imported): one tap fetches it in-app.
  Widget _buildVisionFileRow(BuildContext context, AiModel model) {
    // Decide outside Obx: an Obx that reads no observable throws in GetX.
    if (!model.hasVisionProjector || model.mmprojUrl.isEmpty) {
      return const SizedBox.shrink();
    }
    return Obx(() {
      if (controller.isVisionFileReady(model)) {
        return const SizedBox.shrink();
      }
      final downloading = controller.isDownloadingModel(model.mmprojFilename);
      final size = controller.visionFileSizeLabel(model);
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppNotice(
              downloading
                  ? 'Downloading the vision file… images will work once it finishes.'
                  : 'Supports images. Download its vision file'
                      '${size.isEmpty ? '' : ' ($size)'} to use them; '
                      'text chat works without it.',
              icon: Icons.visibility_outlined,
            ),
            if (!downloading) ...[
              const SizedBox(height: 10),
              PillButton(
                label: 'Download vision file',
                icon: Icons.download_rounded,
                primary: true,
                onPressed: () => controller.downloadVisionFile(model),
              ),
            ],
          ],
        ),
      );
    });
  }

  Future<void> _confirmRemoveCustom(BuildContext context, AiModel model) async {
    final confirmed = await confirmSheet(
      context,
      title: 'Remove from list?',
      message: '${model.name} will be removed from your models. You can add it '
          'again later with the correct URL.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (confirmed) await controller.removeCustomModel(model);
  }
}
