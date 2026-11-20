part of 'model_controller.dart';

// ModelController: importing GGUF files from storage or a folder.

extension ModelImport on ModelController {
  Future<void> importModelFromStorage() async {
    if (isImporting.value) {
      showToast('Import in Progress', 'Wait for the current import to finish.',
          tone: ToastTone.warning);
      return;
    }

    if (Platform.isAndroid) {
      await _importModelWithAndroidPicker();
      return;
    }

    String? partialImportPath;
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.any,
        withData: false,
        withReadStream: true,
      );

      if (result != null) {
        final picked = result.files.single;
        final filename = picked.name;
        final lower = filename.toLowerCase();

        if (!lower.endsWith('.gguf')) {
          showToast('Unsupported Model', 'Only .gguf files can be imported.',
              tone: ToastTone.warning);
          return;
        }

        final file = picked.path == null ? null : File(picked.path!);
        final totalBytes = picked.size > 0
            ? picked.size
            : file == null
                ? 0
                : await file.length();
        if (totalBytes <= 0) {
          showToast('Import Failed', 'The selected file is empty.',
              tone: ToastTone.error);
          return;
        }

        final sourceStream = picked.readStream ?? file?.openRead();
        if (sourceStream == null) {
          showToast(
            'Import Failed',
            'Unable to read the selected file. Try selecting it from local storage.',
            tone: ToastTone.error,
          );
          return;
        }

        final modelsDir = await _download.modelsDir;
        final destPath = '$modelsDir/$filename';
        final partPath = '$destPath.part';
        partialImportPath = partPath;
        final destFile = File(destPath);
        final partFile = File(partPath);
        var shouldReplace = false;

        if (await destFile.exists()) {
          final replace = await _confirmReplace(filename);
          if (!replace) return;
          shouldReplace = true;
        }

        isImporting.value = true;
        importFileName.value = filename;
        importStatus.value = 'Copying to app storage...';
        importCopiedBytes.value = 0;
        importTotalBytes.value = totalBytes;
        importBytesPerSecond.value = 0;

        if (await partFile.exists()) {
          await partFile.delete();
        }

        await _copyWithProgress(sourceStream, partFile);
        if (shouldReplace && await destFile.exists()) {
          await destFile.delete();
        }
        await partFile.rename(destPath);
        fileSizes[filename] = await File(destPath).length();

        await refreshDownloaded();
        modelScope.value = 'local';
        importStatus.value = 'Import complete';
        showToast('Import Successful', 'Model $filename imported.',
            tone: ToastTone.success);
      }
    } catch (e) {
      if (partialImportPath != null) {
        final partialFile = File(partialImportPath);
        if (await partialFile.exists()) {
          await partialFile.delete();
        }
      }
      Get.find<AppLogService>().error('Model import failed', details: e);
      showToast('Import Failed', '$e', tone: ToastTone.error);
    } finally {
      isImporting.value = false;
      importFileName.value = '';
      importStatus.value = '';
      importCopiedBytes.value = 0;
      importTotalBytes.value = 0;
      importBytesPerSecond.value = 0;
    }
  }

  Future<void> _importModelWithAndroidPicker() async {
    try {
      isImporting.value = true;
      importFileName.value = '';
      importStatus.value = 'Select a model file...';
      importCopiedBytes.value = 0;
      importTotalBytes.value = 0;
      importBytesPerSecond.value = 0;

      final result =
          await _androidImportChannel.invokeMapMethod<String, dynamic>(
        'pickAndImportModel',
        {'modelsDir': await _download.modelsDir},
      );

      if (result?['cancelled'] == true) return;

      final filename = result?['filename'] as String?;
      if (filename != null && filename.isNotEmpty) {
        fileSizes[filename] = (result?['bytes'] as num?)?.toInt() ??
            await _download.getModelSize(filename);
        await refreshDownloaded();
        modelScope.value = 'local';
        showToast('Import Successful', 'Model $filename imported.',
            tone: ToastTone.success);
      }
    } on PlatformException catch (e) {
      Get.find<AppLogService>().error(
        'Android model import failed',
        details: '${e.code}: ${e.message}',
      );
      showToast('Import Failed', e.message ?? e.code, tone: ToastTone.error);
    } catch (e) {
      Get.find<AppLogService>()
          .error('Android model import failed', details: e);
      showToast('Import Failed', '$e', tone: ToastTone.error);
    } finally {
      isImporting.value = false;
      importFileName.value = '';
      importStatus.value = '';
      importCopiedBytes.value = 0;
      importTotalBytes.value = 0;
      importBytesPerSecond.value = 0;
    }
  }

  /// Folder import is Android only (storage access framework tree picker).
  bool get supportsFolderImport => Platform.isAndroid;

  /// Opens the system folder picker and lists the model files inside.
  /// Returns null when the user cancels.
  Future<List<FolderModelFile>?> pickModelFolder() async {
    try {
      final result = await _androidImportChannel
          .invokeMapMethod<String, dynamic>('pickModelFolder');
      if (result == null || result['cancelled'] == true) return null;
      return (result['files'] as List? ?? [])
          .map((f) => Map<String, dynamic>.from(f as Map))
          .map((f) => FolderModelFile(
                uri: f['uri'] as String,
                name: f['name'] as String,
                size: (f['size'] as num).toInt(),
              ))
          .toList();
    } on PlatformException catch (e) {
      Get.find<AppLogService>()
          .error('Folder scan failed', details: '${e.code}: ${e.message}');
      showToast('Couldn\'t read folder', e.message ?? e.code,
          tone: ToastTone.error);
      return null;
    }
  }

  /// Copies the chosen files into app storage one after another, with the
  /// same progress card as a single import.
  Future<void> importFolderFiles(List<FolderModelFile> files) async {
    if (files.isEmpty) return;
    if (isImporting.value) {
      showToast('Import in Progress', 'Wait for the current import to finish.',
          tone: ToastTone.warning);
      return;
    }
    final modelsDir = await _download.modelsDir;
    var imported = 0;
    final failed = <String>[];
    isImporting.value = true;
    try {
      for (final file in files) {
        importFileName.value = file.name;
        importStatus.value = 'Copying to app storage...';
        importCopiedBytes.value = 0;
        importTotalBytes.value = file.size;
        importBytesPerSecond.value = 0;
        try {
          final result =
              await _androidImportChannel.invokeMapMethod<String, dynamic>(
            'importModelUri',
            {'uri': file.uri, 'modelsDir': modelsDir},
          );
          final name = result?['filename'] as String? ?? file.name;
          fileSizes[name] = (result?['bytes'] as num?)?.toInt() ?? file.size;
          imported++;
        } on PlatformException catch (e) {
          failed.add(file.name);
          Get.find<AppLogService>().error('Folder import failed',
              details: '${file.name} · ${e.code}: ${e.message}');
        }
      }
      await refreshDownloaded();
      modelScope.value = 'local';
      if (failed.isEmpty) {
        showToast('Import Successful',
            imported == 1 ? '1 model imported.' : '$imported models imported.',
            tone: ToastTone.success);
      } else {
        showToast('Some imports failed',
            '$imported imported · couldn\'t import ${failed.join(', ')}',
            tone: ToastTone.warning);
      }
    } finally {
      isImporting.value = false;
      importFileName.value = '';
      importStatus.value = '';
      importCopiedBytes.value = 0;
      importTotalBytes.value = 0;
      importBytesPerSecond.value = 0;
    }
  }

  Future<void> _copyWithProgress(
    Stream<List<int>> source,
    File destination,
  ) async {
    final startedAt = DateTime.now();
    final sink = destination.openWrite();
    try {
      await for (final chunk in source) {
        sink.add(chunk);
        importCopiedBytes.value += chunk.length;
        final elapsed =
            DateTime.now().difference(startedAt).inMilliseconds / 1000;
        if (elapsed > 0) {
          importBytesPerSecond.value = importCopiedBytes.value / elapsed;
        }
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close();
      if (await destination.exists()) {
        await destination.delete();
      }
      rethrow;
    }
  }

  Future<bool> _confirmReplace(String filename) async {
    final context = Get.context;
    if (context == null) return false;
    return confirmSheet(
      context,
      title: 'Model already exists',
      message:
          'A model file named "$filename" is already imported in your local app storage. Would you like to replace it?',
      confirmLabel: 'Replace file',
    );
  }

  /// Removes `.part` files left behind by imports or download finalisation
  /// that crashed. Several writers use `.part` concurrently (Android import,
  /// download finalise, desktop/iOS import), and this runs on every refresh,
  /// so only delete files that no active job owns and that haven't been
  /// written to recently; deleting a live one corrupts that download.
  Future<void> _deletePartialImports() async {
    const staleAfter = Duration(minutes: 10);
    try {
      final dir = Directory(await _download.modelsDir);
      if (!await dir.exists()) return;
      final busy = {
        ..._download.activeDownloads.keys,
        if (isImporting.value) importFileName.value,
      };
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final lower = name.toLowerCase();
        // A '.download' partial whose finished file already exists is a
        // leftover from an interrupted download that was later restarted.
        if (lower.endsWith('.download')) {
          final target = name.substring(0, name.length - '.download'.length);
          if (busy.contains(target)) continue;
          if (await File('${dir.path}/$target').exists()) await entity.delete();
          continue;
        }
        if (!lower.endsWith('.part')) continue;
        final target = name.substring(0, name.length - '.part'.length);
        if (busy.contains(target)) continue;
        final age = DateTime.now().difference(await entity.lastModified());
        if (age < staleAfter) continue;
        await entity.delete();
      }
    } catch (_) {}
  }
}
