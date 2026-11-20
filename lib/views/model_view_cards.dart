part of 'model_view.dart';

// Models screen: model rows, the library and the browse list.

extension _CardsSection on ModelView {
  // ── Local model cards ─────────────────────────────────────────────────

  List<AppTag> _buildModelTags(BuildContext context, AiModel model) {
    final filter = controller.localFilter.value.isEmpty
        ? controller.defaultLocalFilter
        : controller.localFilter.value;
    return [
      if (model.recommendedFor.contains(filter))
        AppTag('Recommended',
            icon: Icons.star_rounded, color: AppTokens.of(context).accent),
      if (controller.isVisionModel(model))
        const AppTag('Vision', icon: Icons.visibility_outlined),
      if (controller.isUncensoredModel(model)) const AppTag('Uncensored'),
      if (model.isImported) const AppTag('Imported'),
      if (model.isCustom) const AppTag('Custom'),
    ];
  }

  void _confirmDownload(BuildContext context, AiModel model,
      {bool isToDownloadsFolder = false}) {
    showAppSheet<void>(
      context,
      title: isToDownloadsFolder ? 'Save to Downloads' : 'Download model',
      subtitle: isToDownloadsFolder
          ? 'Save ${model.name} to your phone\'s public Downloads folder.'
          : 'Download ${model.name} for use in the app.',
      builder: (ctx) {
        final t = AppTokens.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: _sheetSurface(t),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.hairline, width: 0.5),
              ),
              child: Row(
                children: [
                  Icon(Icons.sd_storage_outlined, size: 18, color: t.muted),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Size', style: t.body)),
                  Text(
                    controller.modelSizeLabel(model),
                    style: t.bodyStrong.copyWith(fontFeatures: _tabular),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            AppNotice(
              'Wi-Fi is recommended. Keep the app open while it downloads.',
              icon: Icons.wifi_rounded,
              color: t.orange,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TonalButton.neutral(ctx,
                      label: 'Cancel', onTap: () => Navigator.of(ctx).pop()),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PrimaryButton(
                    label: isToDownloadsFolder ? 'Save' : 'Download',
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      if (isToDownloadsFolder) {
                        controller.downloadModelToDownloads(model);
                      } else {
                        controller.downloadModel(model);
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmDeleteModel(
      BuildContext context, String filename) async {
    final confirmed = await confirmSheet(
      context,
      title: 'Delete model?',
      message: '$filename will be permanently removed from this device.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed) await controller.deleteModel(filename);
  }

  Widget _buildModelCard(BuildContext context, AiModel model,
      {bool library = false}) {
    return Obx(() {
      final t = AppTokens.of(context);
      final actualFilename = model.filename.toLowerCase().endsWith('.zip')
          ? model.filename.substring(0, model.filename.length - 4)
          : model.filename;

      final isDownloaded = controller.isDownloaded(model.filename);
      final inference = Get.find<InferenceService>();
      final isActive = inference.loadedModelName.value == actualFilename;
      final isCurrentlyDownloading =
          controller.isDownloadingModel(model.filename);
      final isAnyModelLoading = inference.isLoadingModel.value;
      final isThisModelLoading = inference.isLoadingModel.value &&
          inference.loadingModelName.value == actualFilename;
      final disableActions = controller.isImporting.value ||
          isAnyModelLoading ||
          isCurrentlyDownloading;
      final loadPercent = (inference.modelLoadProgress.value * 100)
          .clamp(0.0, 100.0)
          .toStringAsFixed(0);

      // Primary action (right). While downloading: a progress ring with the
      // percentage (cancel lives in the pinned downloads card at the top).
      final Widget primaryAction;
      if (isCurrentlyDownloading) {
        primaryAction = _DownloadRing(filename: model.filename);
      } else if (isDownloaded) {
        if (isThisModelLoading) {
          primaryAction = Text('$loadPercent%',
              style: t.small.copyWith(
                  color: t.accent,
                  fontWeight: FontWeight.w600,
                  fontFeatures: _tabular));
        } else if (isActive) {
          primaryAction = AppTag('Loaded', color: t.green);
        } else if (library) {
          primaryAction = _SoftButton(
            label: 'Load',
            onPressed: disableActions
                ? null
                : () => controller.loadModel(actualFilename),
          );
        } else {
          primaryAction = Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.check_rounded, size: 15, color: t.muted),
            const SizedBox(width: 4),
            Text('On phone', style: t.small),
          ]);
        }
      } else {
        primaryAction = _RoundIconButton(
          icon: Icons.arrow_downward_rounded,
          tooltip: 'Download',
          onPressed:
              disableActions ? null : () => _confirmDownload(context, model),
        );
      }
      final VoidCallback? load = isDownloaded && !isActive && !disableActions
          ? () => controller.loadModel(actualFilename)
          : null;

      // Secondary actions live in the ⋯ sheet.
      final secondary = <(IconData, String, bool, VoidCallback)>[
        if (!isCurrentlyDownloading && isDownloaded)
          (
            Icons.save_alt_rounded,
            model.hasVisionProjector
                ? 'Save to Downloads folder (with vision file)'
                : 'Save to Downloads folder',
            false,
            () => controller.saveToDownloads(model),
          ),
        if (!isCurrentlyDownloading && isDownloaded && !isActive)
          (
            Icons.delete_outline_rounded,
            'Delete model',
            true,
            () => _confirmDeleteModel(context, actualFilename),
          ),
        if (!isCurrentlyDownloading &&
            !isDownloaded &&
            model.url.trim().isNotEmpty)
          (
            Icons.save_alt_rounded,
            'Save to phone Downloads folder',
            false,
            () => _confirmDownload(context, model, isToDownloadsFolder: true),
          ),
        if (!isCurrentlyDownloading && !isDownloaded && model.isCustom)
          (
            Icons.playlist_remove_rounded,
            'Remove from list',
            true,
            () => _confirmRemoveCustom(context, model),
          ),
      ];

      final filter = controller.localFilter.value.isEmpty
          ? controller.defaultLocalFilter
          : controller.localFilter.value;
      final recommended = !library && model.recommendedFor.contains(filter);
      // In Browse, skip the label the selected type already implies.
      final (name, variant) = _cleanName(model);
      // Uncensored is a tag next to the name; the type is the section (My
      // models) or the selected chip (Browse), so neither repeats here.
      final uncensored = controller.isUncensoredModel(model) &&
          (library || filter != 'uncensored');
      final subtitle = [
        controller.modelSizeLabel(model),
        if (variant != null) variant,
        if (!library && controller.isVisionModel(model) && filter != 'vision')
          'Vision',
        if (model.isImported) 'Imported',
      ].join(' · ');
      void openDetails() => _showModelDetails(
          context, model, subtitle, secondary, disableActions, primaryAction,
          onLoad: load);
      return Material(
        color: Colors.transparent,
        child: InkWell(
          // Tap or long-press opens the details sheet; loading has its own
          // button on the row.
          onTap: openDetails,
          onLongPress: openDetails,
          splashFactory: NoSplash.splashFactory,
          // No pressed/focus tint at all: it could stay stuck on the row
          // after a sheet opens or a model starts loading.
          highlightColor: Colors.transparent,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _ModelAvatar(name: name, loaded: isActive),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Flexible(
                              child: Text(name,
                                  style: t.body
                                      .copyWith(fontWeight: FontWeight.w500),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                            if (uncensored) ...[
                              const SizedBox(width: 8),
                              AppTag('Uncensored', color: t.orange),
                            ],
                          ]),
                          const SizedBox(height: 3),
                          Row(children: [
                            Flexible(
                              child: Text.rich(
                                TextSpan(children: [
                                  if (recommended && !isActive)
                                    TextSpan(
                                      text: '★ Recommended · ',
                                      style: TextStyle(
                                          color: t.accent,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  TextSpan(text: subtitle),
                                ]),
                                style: t.small.copyWith(fontFeatures: _tabular),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ]),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    primaryAction,
                  ],
                ),
                if (isDownloaded && !isCurrentlyDownloading)
                  _buildVisionFileRow(context, model),
                if (isThisModelLoading) ...[
                  const SizedBox(height: 10),
                  _buildModelLoadingProgress(context, model),
                ],
              ],
            ),
          ),
        ),
      );
    });
  }

  _TextAction _sortAction() => _TextAction(
        icon: Icons.swap_vert_rounded,
        label: controller.sortSmallestFirst.value ? 'By size' : 'By name',
        onTap: controller.toggleSort,
      );

  /// My models: everything on the phone. Tap a row to load it.
  List<Widget> _buildLibrary(BuildContext context) {
    final models = controller.displayedModels
        .where((m) => controller.isDownloaded(m.filename))
        .toList();
    if (models.isEmpty) return [_buildEmptyLibrary(context)];
    final t = AppTokens.of(context);
    final vision = models.where(controller.isVisionModel).toList();
    final chat = models.where((m) => !vision.contains(m)).toList();
    var first = true;
    List<Widget> group(String title, List<AiModel> list) {
      if (list.isEmpty) return const [];
      final header = SectionHeader(title,
          padding: EdgeInsets.fromLTRB(4, first ? 14 : 22, 0, 8));
      first = false;
      return [
        header,
        AppGroup(children: [
          for (final m in list) _buildModelCard(context, m, library: true),
        ]),
      ];
    }

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 0, 0),
        child: Row(children: [
          Expanded(
              child:
                  Text('On this phone · ${models.length}', style: t.caption)),
          _sortAction(),
        ]),
      ),
      ...group('Chat', chat),
      ...group('Vision', vision),
    ];
  }

  /// Browse: the catalogue for the selected type, recommended pick first.
  List<Widget> _buildBrowse(BuildContext context) {
    final models = controller.filteredDisplayedModels;
    if (models.isEmpty) {
      return [
        const EmptyState(
            icon: Icons.search_off_rounded,
            title: 'No models here yet',
            message: 'Try another type.'),
      ];
    }
    return [
      SectionHeader('All ${models.length}',
          padding: const EdgeInsets.fromLTRB(4, 20, 0, 8),
          trailing: _sortAction()),
      AppGroup(children: [
        for (final m in models) _buildModelCard(context, m),
      ]),
    ];
  }
}
