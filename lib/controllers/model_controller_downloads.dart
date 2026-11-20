part of 'model_controller.dart';

// ModelController: downloading, pausing and deleting model files.

extension ModelDownloads on ModelController {
  Future<void> downloadModel(AiModel model) async {
    if (externalDownloadId.value != null &&
        importFileName.value == model.filename) {
      showToast('Already downloading',
          'This model is downloading to your Downloads folder. Wait for it to finish first.',
          tone: ToastTone.warning);
      return;
    }
    try {
      // Vision models need their projector too; fetch both together.
      if (model.hasVisionProjector &&
          model.mmprojUrl.isNotEmpty &&
          !await _download.isModelDownloaded(model.mmprojFilename) &&
          !_download.activeDownloads.containsKey(model.mmprojFilename)) {
        unawaited(_downloadVisionFile(model));
      }
      await _download.downloadModel(
        url: model.url,
        filename: model.filename,
      );
      await refreshDownloaded();
    } catch (e) {
      Get.find<AppLogService>().error('Model download failed', details: e);
      showToast('Download Failed', '$e', tone: ToastTone.error);
    }
  }

  /// Copies a downloaded model (and its vision file, if any) from app
  /// storage to the phone's public Downloads folder.
  Future<void> saveToDownloads(AiModel model) async {
    final files = [
      model.filename,
      if (model.hasVisionProjector && isVisionFileReady(model))
        model.mmprojFilename,
    ];
    final saved = <String>[];
    for (final name in files) {
      if (activeDownloads.containsKey('save:$name')) continue;
      try {
        final path = await _download.modelPath(name);
        final result = await _androidImportChannel.invokeMethod<String>(
            'saveToDownloads', {'path': path, 'name': name});
        if (result != null) saved.add(result);
      } on PlatformException catch (e) {
        Get.find<AppLogService>().error('Save to Downloads failed', details: e);
        showToast('Not saved', e.message ?? 'Could not save $name.',
            tone: ToastTone.error);
        return;
      }
    }
    if (saved.isNotEmpty) {
      showToast(
        'Saved to Downloads',
        saved.length == 1
            ? '${saved.first} is in your Downloads folder.'
            : '${saved.length} files (model + vision file) are in your Downloads folder.',
        tone: ToastTone.success,
      );
    }
  }

  /// Background download of a GGUF vision model's projector file.
  Future<void> _downloadVisionFile(AiModel model) async {
    try {
      await _download.downloadModel(
          url: model.mmprojUrl, filename: model.mmprojFilename);
    } catch (e) {
      Get.find<AppLogService>()
          .error('Vision file download failed', details: e);
    }
  }

  Future<void> downloadModelToDownloads(AiModel model) async {
    if (model.url.trim().isEmpty) {
      showToast('Download Unavailable', 'This model has no download URL.',
          tone: ToastTone.warning);
      return;
    }

    if (!Platform.isAndroid) {
      showToast(
        'Android Only',
        'Use the app download button or import a local model on this platform.',
        tone: ToastTone.info,
      );
      return;
    }

    // Both downloads report progress under the same filename; running them
    // together mixes up their progress.
    if (isDownloadingModel(model.filename)) {
      showToast('Already downloading',
          'Wait for the in-app download of this model to finish first.',
          tone: ToastTone.warning);
      return;
    }

    try {
      isImporting.value = true;
      importFileName.value = model.filename;
      importStatus.value = 'Starting download...';
      importCopiedBytes.value = 0;
      importTotalBytes.value = 0;
      importBytesPerSecond.value = 0;

      final result =
          await _androidImportChannel.invokeMapMethod<String, dynamic>(
        'downloadToDownloads',
        {'url': model.url, 'filename': model.filename},
      );
      externalDownloadId.value = result?['downloadId'] as int?;
      final filename = result?['filename'] as String? ?? model.filename;
      showToast(
        'Download Started',
        '$filename is downloading to your Downloads folder.',
        tone: ToastTone.info,
      );
    } on PlatformException catch (e) {
      isImporting.value = false;
      externalDownloadId.value = null;
      Get.find<AppLogService>().error(
        'Download to Downloads failed',
        details: '${e.code}: ${e.message}',
      );
      showToast('Download Failed', e.message ?? e.code, tone: ToastTone.error);
    } catch (e) {
      isImporting.value = false;
      externalDownloadId.value = null;
      Get.find<AppLogService>()
          .error('Download to Downloads failed', details: e);
      showToast('Download Failed', '$e', tone: ToastTone.error);
    }
  }

  Future<void> cancelExternalDownload() async {
    final id = externalDownloadId.value;
    if (id != null) {
      try {
        await _androidImportChannel
            .invokeMethod('cancelDownloadToDownloads', {'downloadId': id});
      } catch (e) {
        Get.find<AppLogService>().error('Cancel download failed', details: e);
      }
      externalDownloadId.value = null;
      isImporting.value = false;
      importStatus.value = 'Download cancelled';
    }
  }

  /// Android's DownloadManager offers no pause API, so stopping there cancels
  /// the download; elsewhere progress is kept and the next download resumes.
  bool get canPauseDownloads => !Platform.isAndroid;

  void pauseDownload(String filename) {
    _download.pauseDownload(filename);
  }

  /// Removes a custom model entry added from a URL in an earlier version,
  /// cancelling any download and deleting any partial or complete file.
  Future<void> removeCustomModel(AiModel model) async {
    if (_download.activeDownloads.containsKey(model.filename)) {
      _download.pauseDownload(model.filename);
    }
    if (_inference.loadedModelName.value == model.filename) {
      await _inference.unloadModel();
    }
    await _download.deleteModel(model.filename);
    customModels.removeWhere((m) => m.filename == model.filename);
    availableModels
        .removeWhere((m) => m.isCustom && m.filename == model.filename);
    await _saveCustomModels();
    await refreshDownloaded();
  }

  Future<void> deleteModel(String filename) async {
    final model =
        availableModels.firstWhereOrNull((m) => m.filename == filename);
    if (model != null && model.hasVisionProjector) {
      try {
        await _download.deleteModel(model.mmprojFilename);
      } catch (_) {}
    }
    await _download.deleteModel(filename);
    await refreshDownloaded();
    // Unload if this was the active model
    if (_inference.loadedModelName.value == filename) {
      await _inference.unloadModel();
    }
  }
}
