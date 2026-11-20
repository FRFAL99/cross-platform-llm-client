part of 'model_controller.dart';

// ModelController: loading a model, memory checks and load errors.

extension ModelLoading on ModelController {
  Future<void> loadModel(String filename) async {
    if (_inference.isLoadingModel.value) {
      showToast('Model Loading', 'Another model is already loading.',
          tone: ToastTone.warning);
      return;
    }
    final path = await _download.modelPath(filename);
    final model =
        availableModels.firstWhereOrNull((m) => m.filename == filename);
    if (_isVisionProjectorFile(filename)) {
      showToast(
        'Helper File',
        '$filename is a vision file used by another model and cannot be loaded on its own.',
        tone: ToastTone.info,
      );
      return;
    }
    final fileBytes = await _modelFileBytes(filename, path, model);
    if (model != null && _isIncompleteCatalogFile(model, fileBytes)) {
      final actual = DownloadService.formatBytes(fileBytes);
      Get.find<AppLogService>().error(
        'Incomplete model file blocked',
        details: '$filename is $actual, expected about ${model.size}',
      );
      showToast(
        'Incomplete Model File',
        '$filename is only $actual. Delete it and download again.',
        tone: ToastTone.error,
        duration: const Duration(seconds: 6),
      );
      return;
    }
    final loadAction = await _confirmModelLoadSafety(
      filename: filename,
      path: path,
      fileBytes: fileBytes,
    );
    if (loadAction == _ModelLoadAction.cancel) return;
    if (loadAction == _ModelLoadAction.unloadAndContinue) {
      await unloadModel();
    }

    // GGUF vision: pass the projector if it's on disk; otherwise fetch it
    // and load text-only for now.
    String? mmprojPath;
    var visionNote = '';
    if (model != null && model.hasVisionProjector) {
      if (await _download.isModelDownloaded(model.mmprojFilename)) {
        mmprojPath = await _download.modelPath(model.mmprojFilename);
      } else {
        visionNote = ' Vision file is still downloading, so images will '
            'work after you reload the model.';
        if (model.mmprojUrl.isNotEmpty &&
            !_download.activeDownloads.containsKey(model.mmprojFilename)) {
          unawaited(_downloadVisionFile(model));
        }
      }
    }
    final result = await _inference.loadModel(
      path,
      modelName: filename,
      mmprojPath: mmprojPath,
    );
    if (_inference.isModelLoaded.value) {
      _inference.isVisionLoaded.value = _inference.ggufVisionLoaded;
      if (visionNote.isNotEmpty) {
        showToast('Model Loaded', '$result$visionNote',
            tone: ToastTone.info, duration: const Duration(seconds: 5));
        return;
      }
      showToast('Model Loaded', result, tone: ToastTone.success);
    } else {
      _showLoadFailedSheet(filename, result);
    }
  }

  Future<int> _modelFileBytes(
    String filename,
    String path,
    AiModel? model,
  ) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        final bytes = await file.length();
        fileSizes[filename] = bytes;
        return bytes;
      }
    } catch (_) {}
    final cached = fileSizes[filename] ?? 0;
    if (cached > 0) return cached;
    return model == null ? 0 : _knownModelBytes(model);
  }

  Future<_ModelLoadAction> _confirmModelLoadSafety({
    required String filename,
    required String path,
    required int fileBytes,
  }) async {
    // Phone cluster: the model is split across phones, so this phone's free
    // memory alone says little. ClusterService checks the whole cluster's
    // memory (and offers this-phone-only when it fits) right before loading.
    if (filename.toLowerCase().endsWith('.gguf') &&
        Get.isRegistered<ClusterService>() &&
        Get.find<ClusterService>().role == ClusterRole.master &&
        Get.find<ClusterService>().workers.isNotEmpty) {
      return _ModelLoadAction.continueLoad;
    }

    final availableRamGb = await _refreshAvailableRamGb();

    // Whatever is loaded now gets unloaded first, so count its memory as
    // free when judging whether the new model fits.
    final loadedName =
        _inference.isModelLoaded.value ? _inference.loadedModelName.value : '';
    final hasLoadedModel = loadedName.isNotEmpty;
    final isSameModelLoaded = hasLoadedModel && loadedName == filename;
    final loadedBytes = hasLoadedModel ? (fileSizes[loadedName] ?? 0) : 0;

    final measuredBytes = (availableRamGb * 1024 * 1024 * 1024).round();
    final availableBytes =
        measuredBytes > 0 ? measuredBytes + loadedBytes : measuredBytes;
    final modelLabel = fileBytes > 0
        ? DownloadService.formatWholeMb(fileBytes)
        : 'Unknown size';
    final ramLabel = availableBytes > 0
        ? '${hasLoadedModel && loadedBytes > 0 ? '~' : ''}'
            '${DownloadService.formatWholeMb(availableBytes)}'
        : 'Unknown';
    final lower = filename.toLowerCase();

    // For GGUF, estimate real usage from the file's header: weights plus the
    // KV cache for the configured context, which file size alone ignores.
    final gguf = lower.endsWith('.gguf') ? await readGgufInfo(path) : null;
    final contextTokens = _settings.contextSize.value;
    final estimatedBytes = gguf?.estimateBytes(contextTokens);
    final fits = estimatedBytes == null ||
        availableBytes <= 0 ||
        estimatedBytes <= availableBytes;
    final fittingContext = (gguf != null && !fits && availableBytes > 0)
        ? gguf.maxContextFitting(availableBytes)
        : null;

    final hasMeasuredMemory = availableBytes > 0 && fileBytes > 0;
    final isCriticallyLow = hasMeasuredMemory &&
        (estimatedBytes != null
            ? estimatedBytes > availableBytes
            : (availableBytes < fileBytes ||
                _isLowMemoryBytes(availableBytes)));
    final isLargeForRam =
        availableBytes > 0 && fileBytes > 0 && availableBytes < fileBytes * 2;
    final isLowRam = availableBytes > 0 && _isLowMemoryBytes(availableBytes);
    final String warning;
    if (gguf != null && !fits) {
      warning = fittingContext != null
          ? 'This probably won\'t fit in free memory at a context of '
              '$contextTokens tokens. A context of $fittingContext tokens '
              'should fit.'
          : 'This model is probably too large for the free memory on this '
              'phone, even with a small context. Try a smaller model.';
    } else if (isCriticallyLow) {
      warning =
          'Available RAM is lower than recommended. This can crash the app if Android cannot reserve enough memory.';
    } else if (isLargeForRam || isLowRam) {
      warning =
          'This can crash the app if Android cannot reserve enough memory for the model.';
    } else {
      warning = 'Loading local models can use more memory than the file size.';
    }
    final runtimeLabel = lower.endsWith('.gguf') ? 'GGUF' : 'Local model';

    final warningSerious =
        (gguf != null && !fits) || isCriticallyLow || isLargeForRam || isLowRam;

    final sheetContext = Get.context;
    if (sheetContext == null || !sheetContext.mounted) {
      return _ModelLoadAction.cancel;
    }
    final result = await showAppSheet<_ModelLoadAction>(
      sheetContext,
      title: isSameModelLoaded
          ? 'Reload model?'
          : hasLoadedModel
              ? 'Switch model?'
              : isCriticallyLow
                  ? 'Restart recommended'
                  : 'Load model?',
      subtitle: filename,
      builder: (ctx) {
        final t = AppTokens.of(ctx);
        void pop(_ModelLoadAction action) {
          if (ctx.mounted) Navigator.pop(ctx, action);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppGroup(children: [
              _detailRow(ctx, 'Runtime', runtimeLabel),
              _detailRow(
                  ctx,
                  hasLoadedModel ? 'Available after unload' : 'Available RAM',
                  ramLabel),
              _detailRow(ctx, 'Model size', modelLabel),
              if (gguf != null && estimatedBytes != null)
                _detailRow(
                  ctx,
                  'Estimated memory',
                  DownloadService.formatWholeMb(estimatedBytes),
                  note: 'Context '
                      '${DownloadService.formatWholeMb(gguf.kvCacheBytes(contextTokens))} '
                      'for $contextTokens tokens',
                ),
            ]),
            if (hasLoadedModel) ...[
              const SizedBox(height: 12),
              AppNotice(
                isSameModelLoaded
                    ? 'This model is already loaded. It will be unloaded and '
                        'loaded again.'
                    : '$loadedName is loaded. It will be unloaded first.',
                icon: Icons.memory_rounded,
              ),
            ],
            const SizedBox(height: 12),
            AppNotice(
              warning,
              icon: warningSerious
                  ? Icons.warning_amber_rounded
                  : Icons.info_outline_rounded,
              color: warningSerious ? t.orange : null,
            ),
            const SizedBox(height: 20),
            // A model is already loaded: the only choice is to swap it out.
            if (hasLoadedModel)
              Row(children: [
                Expanded(
                  child: TonalButton.neutral(
                    ctx,
                    label: 'Cancel',
                    onTap: () => pop(_ModelLoadAction.cancel),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PrimaryButton(
                    label: 'Unload & continue',
                    onPressed: () => pop(_ModelLoadAction.unloadAndContinue),
                  ),
                ),
              ])
            else ...[
              PrimaryButton(
                label: 'Continue',
                onPressed: () async {
                  await _refreshAvailableRamGb();
                  pop(_ModelLoadAction.continueLoad);
                },
              ),
              if (fittingContext != null) ...[
                const SizedBox(height: 10),
                TonalButton.neutral(
                  ctx,
                  label: 'Load with $fittingContext tokens',
                  onTap: () async {
                    await _settings.setContextSize(fittingContext);
                    pop(_ModelLoadAction.continueLoad);
                  },
                ),
              ],
              if (isCriticallyLow) ...[
                const SizedBox(height: 10),
                TonalButton.neutral(
                  ctx,
                  label: 'Restart app',
                  onTap: () async {
                    pop(_ModelLoadAction.cancel);
                    try {
                      await _androidImportChannel.invokeMethod('restartApp');
                    } catch (_) {
                      SystemNavigator.pop();
                    }
                  },
                ),
              ],
              const SizedBox(height: 10),
              TonalButton.neutral(
                ctx,
                label: 'Cancel',
                onTap: () => pop(_ModelLoadAction.cancel),
              ),
            ],
          ],
        );
      },
    );
    return result ?? _ModelLoadAction.cancel;
  }

  bool _isLowMemoryBytes(int bytes) => bytes < 768 * 1024 * 1024;

  Future<double> _refreshAvailableRamGb() async {
    try {
      final device = Get.find<DeviceInfoService>();
      await device.refreshMemoryInfo();
      return device.availableRamGB.value;
    } catch (_) {
      return 0;
    }
  }

  Future<void> unloadModel() async {
    await _inference.unloadModel();
  }

  /// Phone cluster errors (from ClusterService or the native cluster setup)
  /// already say what to do; anything else gets the generic tips.
  static bool _isClusterError(String rawError) {
    final lower = rawError.toLowerCase();
    return lower.contains('phone cluster') ||
        lower.contains('worker') ||
        lower.contains('cluster:') ||
        lower.contains('too big for these');
  }

  String _getFriendlyErrorMessage(String rawError) {
    final lower = rawError.toLowerCase();
    if (_isClusterError(rawError)) {
      // "ERROR: Failed to load model — Exception: <message>"
      final at = rawError.lastIndexOf('Exception: ');
      return at >= 0 ? rawError.substring(at + 'Exception: '.length) : rawError;
    }
    if (lower.contains('unknown model architecture') ||
        lower.contains('unsupported model architecture')) {
      return 'This GGUF uses a model architecture that is not supported by the bundled llama.cpp runtime. Update the app runtime or try a GGUF exported for a supported architecture.';
    }
    if (lower.contains('missing key') ||
        lower.contains('failed to load gguf split')) {
      return 'This appears to be a split GGUF model, but one or more required model files are missing. Import every split into the same folder before loading it.';
    }
    if (lower.contains('failed to load model from buffer') ||
        lower.contains('invalid_argument') ||
        lower.contains('invalid gguf') ||
        lower.contains('missing or unreadable') ||
        lower.contains('incomplete') ||
        lower.contains('corrupt')) {
      return 'The model file appears to be incomplete or corrupted. This usually happens when the download is interrupted or the file is invalid.';
    }
    if (lower.contains('out of memory') ||
        lower.contains('allocate') ||
        lower.contains('oom') ||
        lower.contains('cannot allocate')) {
      return 'Your device ran out of memory (RAM) trying to load this model. Mobile devices have strict memory limits; try using a smaller or more highly quantized model (e.g., 1B or 3B parameters, q4_k_m quantized).';
    }
    if (lower.contains('opencl') ||
        lower.contains('vulkan') ||
        lower.contains('opengl') ||
        lower.contains('gpu') ||
        lower.contains('cl_') ||
        lower.contains('driver')) {
      return 'A hardware or GPU driver error occurred while initializing the model. Try disabling GPU acceleration or switching to CPU-only inference in Settings.';
    }
    return 'The native AI engine encountered an unexpected error while loading the model. Please check the technical details below for more information.';
  }

  void _showLoadFailedSheet(String filename, String result) {
    final friendlyMsg = _getFriendlyErrorMessage(result);
    final context = Get.context;
    if (context == null) {
      showToast('Model load failed', friendlyMsg,
          tone: ToastTone.error, duration: const Duration(seconds: 6));
      return;
    }
    final isCluster = _isClusterError(result);
    bool showDetails = false;
    showAppSheet<void>(
      context,
      title: isCluster ? 'Phone cluster couldn\'t load' : 'Model load failed',
      subtitle: friendlyMsg,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final t = AppTokens.of(ctx);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader('Troubleshooting tips',
                  padding: EdgeInsets.fromLTRB(0, 0, 0, 10)),
              if (isCluster) ...[
                _buildTipRow(ctx, Icons.hub_outlined,
                    'On each worker, open OneLM > Phone cluster and check that Worker is on and shows its address.'),
                _buildTipRow(ctx, Icons.wifi_rounded,
                    'Keep every device on the same Wi-Fi. iPads must keep OneLM open.'),
              ] else ...[
                _buildTipRow(ctx, Icons.delete_outline_rounded,
                    'Delete the model and try redownloading it completely.'),
                _buildTipRow(ctx, Icons.memory_rounded,
                    'Ensure your device has at least 2-3 GB of free RAM.'),
              ],
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  onTap: () => setState(() => showDetails = !showDetails),
                  borderRadius: BorderRadius.circular(8),
                  splashFactory: NoSplash.splashFactory,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          showDetails
                              ? 'Hide technical details'
                              : 'Show technical details',
                          style: t.label.copyWith(color: t.text),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          showDetails
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: t.muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: showDetails
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Container(
                          constraints: const BoxConstraints(maxHeight: 180),
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: t.fill,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: SingleChildScrollView(
                            child: SelectableText(
                              result,
                              style:
                                  t.mono.copyWith(fontSize: 11.5, height: 1.45),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: 20),
              TonalButton.neutral(ctx,
                  label: 'Close', onTap: () => Navigator.pop(ctx)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTipRow(BuildContext context, IconData icon, String text) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: t.muted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: t.caption.copyWith(color: t.text.withValues(alpha: 0.85)),
            ),
          ),
        ],
      ),
    );
  }

  /// Label / value line used in the load-model sheet.
  Widget _detailRow(BuildContext context, String label, String value,
      {String? note}) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.body.copyWith(fontSize: 14, color: t.muted)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value,
                    textAlign: TextAlign.end,
                    style: t.body
                        .copyWith(fontSize: 14, fontWeight: FontWeight.w500)),
                if (note != null) ...[
                  const SizedBox(height: 2),
                  Text(note, textAlign: TextAlign.end, style: t.small),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
