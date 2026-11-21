part of 'model_view.dart';

// Models screen: the active model, downloads and loading/import progress.

extension _StatusSection on ModelView {
  // ── Active model ──────────────────────────────────────────────────────

  Widget _buildActiveModelBanner(BuildContext context) {
    return Obx(() {
      final t = AppTokens.of(context);
      final inference = Get.find<InferenceService>();
      final busy =
          controller.isImporting.value || inference.isLoadingModel.value;

      final String name;
      final String meta;
      final IconData icon;
      if (inference.isModelLoaded.value) {
        name = inference.loadedModelName.value;
        final gpu = inference.gpuName.value;
        meta = inference.isGpuAccelerated.value
            ? 'Loaded · GPU${gpu.isEmpty ? '' : ' · $gpu'}'
            : 'Loaded · CPU';
        icon = Icons.memory_rounded;
      } else {
        return const SizedBox.shrink();
      }

      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: _ActiveCard(
          icon: icon,
          title: _prettyModel(name),
          meta: meta,
          dot: t.green,
          action: PillButton(
            label: 'Unload',
            onPressed: busy ? null : () => controller.unloadModel(),
          ),
        ),
      );
    });
  }

  /// Compact, pinned summary of every running download (models and their
  /// helper files), so progress stays visible while browsing the list.
  Widget _buildActiveDownloadsBanner(BuildContext context) {
    return Obx(() {
      final downloads = controller.activeDownloads.values.toList();
      if (downloads.isEmpty) return const SizedBox.shrink();
      final t = AppTokens.of(context);

      String labelFor(String filename) {
        if (filename.startsWith('save:')) {
          final name = filename.substring(5);
          final m = controller.availableModels
              .firstWhereOrNull((x) => x.filename == name);
          final owner = controller.availableModels
              .firstWhereOrNull((x) => x.mmprojFilename == name);
          return 'Saving to Downloads · '
              '${m?.name ?? (owner != null ? 'Vision file · ${owner.name}' : name)}';
        }
        final model = controller.availableModels
            .firstWhereOrNull((m) => m.filename == filename);
        if (model != null) return model.name;
        final owner = controller.availableModels
            .firstWhereOrNull((m) => m.mmprojFilename == filename);
        // Lead with "Vision file" so it stays visible when the name is cut off.
        if (owner != null) return 'Vision file · ${owner.name}';
        return filename;
      }

      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: AppCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (var i = 0; i < downloads.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 58),
                  child: Container(height: 0.5, color: t.hairline),
                ),
              Obx(() {
                final dp = downloads[i];
                final pct = (dp.progress.value * 100).clamp(0.0, 100.0);
                final eta = dp.eta;
                final meta = [
                  if (dp.status.value.isNotEmpty)
                    dp.status.value.replaceAll(RegExp(r'\.+$'), ''),
                  '${pct.toStringAsFixed(0)}%',
                  if (dp.bytesPerSecond.value > 0)
                    DownloadService.formatSpeed(dp.bytesPerSecond.value),
                  if (eta != null && eta > Duration.zero)
                    '${DownloadService.formatDuration(eta)} left',
                ].join(' · ');
                return Padding(
                  padding: const EdgeInsets.fromLTRB(14, 11, 6, 11),
                  child: Row(children: [
                    const IconBadge(Icons.download_rounded, size: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(labelFor(dp.filename),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.bodyStrong.copyWith(fontSize: 14)),
                            const SizedBox(height: 6),
                            AppProgressBar(
                                value: dp.progress.value > 0
                                    ? dp.progress.value
                                    : null,
                                height: 3),
                            const SizedBox(height: 5),
                            Text(meta,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    t.small.copyWith(fontFeatures: _tabular)),
                          ]),
                    ),
                    // Copies to Downloads are quick and can't be cancelled.
                    if (!dp.filename.startsWith('save:'))
                      IconButton(
                        tooltip: controller.canPauseDownloads
                            ? 'Pause download'
                            : 'Cancel download',
                        onPressed: () {
                          final external =
                              controller.externalDownloadId.value != null &&
                                  controller.importFileName.value ==
                                      dp.filename;
                          external
                              ? controller.cancelExternalDownload()
                              : controller.pauseDownload(dp.filename);
                        },
                        icon: Icon(
                            controller.canPauseDownloads
                                ? Icons.pause_rounded
                                : Icons.close_rounded,
                            size: 20,
                            color: t.muted),
                      ),
                  ]),
                );
              }),
            ],
          ]),
        ),
      );
    });
  }

  // ── Progress ──────────────────────────────────────────────────────────

  Widget _buildModelLoadingProgress(BuildContext context, AiModel model) {
    return Obx(() {
      final t = AppTokens.of(context);
      final inference = Get.find<InferenceService>();
      final textLoading = inference.isLoadingModel.value &&
          inference.loadingModelName.value == model.filename;
      if (!textLoading) return const SizedBox.shrink();
      final progress = inference.modelLoadProgress.value;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: t.orange,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Loading into memory',
                    style: t.caption.copyWith(color: t.text)),
              ),
              if (progress > 0)
                Text(
                  '${(progress * 100).clamp(0.0, 100.0).toStringAsFixed(0)}%',
                  style: t.small.copyWith(fontFeatures: _tabular),
                ),
            ],
          ),
          const SizedBox(height: 10),
          AppProgressBar(value: progress > 0 ? progress : null),
          const SizedBox(height: 6),
          Text(
            model.filename,
            style: t.small.copyWith(color: t.faint),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      );
    });
  }

  Widget _buildImportingProgress(BuildContext context) {
    return Obx(() {
      if (!controller.isImporting.value) return const SizedBox.shrink();
      // Downloads (including "save to Downloads folder") show in the pinned
      // downloads card; this card is only for file imports.
      if (controller.importStatus.value.toLowerCase().contains('download') &&
          controller.activeDownloads
              .containsKey(controller.importFileName.value)) {
        return const SizedBox.shrink();
      }
      final t = AppTokens.of(context);
      final percent = controller.importProgress * 100;
      final total = controller.importTotalBytes.value;
      final copied = controller.importCopiedBytes.value;
      final remaining = total <= 0 ? 0 : (total - copied).clamp(0, total);
      final isDownload =
          controller.importStatus.value.toLowerCase().contains('download');

      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: AppCard(
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconBadge(
                    isDownload
                        ? Icons.download_rounded
                        : Icons.file_upload_outlined,
                    size: 36,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(isDownload ? 'Downloading' : 'Importing',
                            style: t.bodyStrong),
                        const SizedBox(height: 2),
                        Text(
                          '${controller.importStatus.value} ${controller.importFileName.value}',
                          style: t.small,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (controller.externalDownloadId.value != null)
                    _IconAction(
                      icon: Icons.close_rounded,
                      tooltip: 'Cancel download',
                      destructive: true,
                      onPressed: controller.cancelExternalDownload,
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 12),
                    AppProgressBar(
                      value: controller.importProgress > 0
                          ? controller.importProgress
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [
                        '${percent.toStringAsFixed(0)}%',
                        '${DownloadService.formatWholeMb(copied)} of ${DownloadService.formatWholeMb(total)}',
                        DownloadService.formatSpeed(
                            controller.importBytesPerSecond.value),
                        '${DownloadService.formatWholeMb(remaining)} left',
                      ].join(' · '),
                      style: t.small.copyWith(fontFeatures: _tabular),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// Calm summary card for the model currently in use (mirrors the home card).
class _ActiveCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String meta;
  final Color dot;
  final Widget action;

  const _ActiveCard({
    required this.icon,
    required this.title,
    required this.meta,
    required this.dot,
    required this.action,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Row(children: [
        IconBadge(icon, size: 40),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyStrong),
                const SizedBox(height: 3),
                Row(children: [
                  StatusDot(dot),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.caption.copyWith(fontFeatures: _tabular)),
                  ),
                ]),
              ]),
        ),
        const SizedBox(width: 10),
        action,
      ]),
    );
  }
}

/// Circular download progress with the percentage inside, sized like the
/// row's round buttons.
class _DownloadRing extends StatelessWidget {
  final String filename;
  const _DownloadRing({required this.filename});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ModelController>();
    return Obx(() {
      final t = AppTokens.of(context);
      final dp = controller.getDownloadProgress(filename);
      final value = dp?.progress.value ?? 0;
      final pct = (value * 100).clamp(0.0, 100.0).round();
      return SizedBox(
        width: 38,
        height: 38,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
              value: value > 0 ? value : null,
              strokeWidth: 2.5,
              strokeCap: StrokeCap.round,
              color: t.accent,
              backgroundColor: t.fill,
            ),
          ),
          Text('$pct%',
              style: t.small.copyWith(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                  fontFeatures: _tabular)),
        ]),
      );
    });
  }
}
