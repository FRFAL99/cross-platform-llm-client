import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../services/download_service.dart';
import '../services/gguf_metadata.dart';
import '../services/inference_service.dart';
import '../services/hive_service.dart';
import '../services/app_log_service.dart';
import '../services/device_info_service.dart';
import '../models/ai_model.dart';
import '../core/constants.dart';
import '../core/ui.dart';
import '../services/cluster_service.dart';
import '../services/speed_estimate.dart';
import 'settings_controller.dart';

part 'model_controller_downloads.dart';
part 'model_controller_loading.dart';
part 'model_controller_import.dart';

enum _ModelLoadAction { cancel, unloadAndContinue, continueLoad }

/// A model file found by scanning a folder the user picked.
class FolderModelFile {
  final String uri;
  final String name;
  final int size;
  const FolderModelFile(
      {required this.uri, required this.name, required this.size});
}

/// Android side of file import and app restart (MainActivity).
const _androidImportChannel = MethodChannel('com.aichat.ai_chat/model_import');

class ModelController extends GetxController {
  final DownloadService _download = Get.find<DownloadService>();
  final InferenceService _inference = Get.find<InferenceService>();
  final HiveService _hive = Get.find<HiveService>();
  final SettingsController _settings = Get.find<SettingsController>();

  static const _customModelsKey = 'custom_url_models';

  Map<String, DownloadProgress> get activeDownloads =>
      _download.activeDownloads;

  final availableModels = <AiModel>[].obs;
  final downloadedFiles = <String>[].obs;

  /// Vision projector (mmproj) files on disk. They're hidden from the model
  /// list but tell us whether a vision model can read images yet.
  final visionFiles = <String>{}.obs;
  final isImporting = false.obs;
  final customModels = <AiModel>[].obs;
  final fileSizes = <String, int>{}.obs;
  final modelScope = 'local'.obs;
  final localFilter = ''.obs;
  final importFileName = ''.obs;
  final importStatus = ''.obs;
  final importCopiedBytes = 0.obs;
  final importTotalBytes = 0.obs;
  final importBytesPerSecond = 0.0.obs;
  final sortSmallestFirst = true.obs;
  final externalDownloadId = Rx<int?>(null);

  void toggleSort() {
    sortSmallestFirst.value = !sortSmallestFirst.value;
  }

  static const localFilters = [
    'general',
    'uncensored',
    'vision',
  ];

  List<AiModel> get displayedModels {
    // Loading a model doesn't move it: the list keeps its normal order and
    // the loaded model is marked in place.
    final models = [...availableModels];
    models.sort((a, b) {
      final aDownloaded = isDownloaded(a.filename);
      final bDownloaded = isDownloaded(b.filename);
      if (aDownloaded != bDownloaded) return aDownloaded ? -1 : 1;

      if (sortSmallestFirst.value) {
        final aBytes = _knownModelBytes(a);
        final bBytes = _knownModelBytes(b);
        if (aBytes > 0 && bBytes > 0 && aBytes != bBytes) {
          return aBytes.compareTo(bBytes);
        }
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return models;
  }

  List<AiModel> get filteredDisplayedModels {
    final filter =
        localFilter.value.isEmpty ? defaultLocalFilter : localFilter.value;
    final filtered = displayedModels.where(ofFilter(filter)).toList();
    // The filter's recommended pick goes first; the rest keep their order
    // (List.sort isn't stable, so partition instead).
    return [
      ...filtered.where((m) => m.recommendedFor.contains(filter)),
      ...filtered.where((m) => !m.recommendedFor.contains(filter)),
    ];
  }

  String get defaultLocalFilter => 'general';

  /// Test for the models a list filter shows.
  bool Function(AiModel) ofFilter(String filter) => switch (filter) {
        'uncensored' => isUncensoredModel,
        'vision' => isVisionModel,
        _ => isGeneralModel,
      };

  double get importProgress => importTotalBytes.value <= 0
      ? 0.0
      : (importCopiedBytes.value / importTotalBytes.value)
          .clamp(0.0, 1.0)
          .toDouble();

  int get downloadedCount => downloadedFiles.length;

  String get activeLocalModelName => _inference.loadedModelName.value;

  @override
  void onInit() {
    super.onInit();
    _loadCustomModels();
    availableModels.value = AppConstants.availableModels
        .map((m) => AiModel.fromMap(m))
        .toList()
      ..addAll(customModels);
    refreshDownloaded();
  }

  void _loadCustomModels() {
    final raw =
        _hive.getSetting<List>(_customModelsKey, defaultValue: []) ?? [];
    customModels.value = raw
        .whereType<Map>()
        .map((m) => AiModel.fromMap(Map<String, String>.from(m)))
        .toList();
  }

  Future<void> _saveCustomModels() async {
    await _hive.setSetting(
      _customModelsKey,
      customModels.map((m) => m.toMap()).toList(),
    );
  }

  Future<void> refreshDownloaded() async {
    await _deletePartialImports();
    final allFiles = await _download.getDownloadedModels();
    visionFiles
      ..clear()
      ..addAll(allFiles.where(_isVisionProjectorFile));
    final files =
        allFiles.where((file) => !_isVisionProjectorFile(file)).toList();
    downloadedFiles.value = files;
    for (final file in files) {
      fileSizes[file] = await _download.getModelSize(file);
    }

    // Add any downloaded files that are not in availableModels
    final existingFilenames = availableModels.map((m) {
      if (m.filename.toLowerCase().endsWith('.zip')) {
        return m.filename.substring(0, m.filename.length - 4);
      }
      return m.filename;
    }).toSet();
    for (final file in files) {
      if (!existingFilenames.contains(file)) {
        // An imported copy of a catalogue vision model (any capitalisation,
        // e.g. the original Hugging Face name) keeps the catalogue's vision
        // file, so images work after one in-app download.
        final known = _catalogVisionMatch(file);
        if (known != null) {
          availableModels.add(known.copyWith(
            filename: file,
            url: '',
            size: _formatModelSize(file),
            description: 'Imported · can read images with its vision file',
            isImported: true,
          ));
          continue;
        }
        availableModels.add(AiModel(
          name: file,
          filename: file,
          url: '',
          size: _formatModelSize(file),
          description: 'Imported from local storage',
          template: 'chatml',
          runtime: AiModel.runtimeLlama,
          isImported: true,
        ));
      }
    }

    // Remove any imported models that are no longer downloaded
    availableModels.removeWhere(
        (model) => model.isImported && !files.contains(model.filename));

    if (localFilter.value.isEmpty) {
      localFilter.value = defaultLocalFilter;
    }
  }

  bool isDownloaded(String filename) {
    if (filename.toLowerCase().endsWith('.zip')) {
      return downloadedFiles
          .contains(filename.substring(0, filename.length - 4));
    }
    return downloadedFiles.contains(filename);
  }

  bool _isVisionProjectorFile(String filename) {
    final lower = filename.toLowerCase();
    return lower.endsWith('.gguf') && lower.contains('mmproj');
  }

  /// Catalogue vision model whose file this is, matched case-insensitively
  /// on our filename or the original download name.
  AiModel? _catalogVisionMatch(String file) {
    final lower = file.toLowerCase();
    for (final m in AppConstants.availableModels) {
      if ((m['mmproj_filename'] ?? '').isEmpty) continue;
      final urlName = Uri.tryParse(m['url'] ?? '')?.pathSegments.last ?? '';
      if ((m['filename'] ?? '').toLowerCase() == lower ||
          urlName.toLowerCase() == lower) {
        return AiModel.fromMap(m);
      }
    }
    return null;
  }

  /// The model's vision file is on disk, so images can be used once loaded.
  bool isVisionFileReady(AiModel model) =>
      model.hasVisionProjector && visionFiles.contains(model.mmprojFilename);

  /// Size of a model's vision file from the catalogue ("986 MB"), if known.
  String visionFileSizeLabel(AiModel model) {
    for (final m in AppConstants.availableModels) {
      if (m['mmproj_filename'] != model.mmprojFilename) continue;
      final match = RegExp(r'\+\s*([\d.]+\s*(?:MB|GB))', caseSensitive: false)
          .firstMatch(m['size'] ?? '');
      return match?.group(1) ?? '';
    }
    return '';
  }

  /// Downloads just the vision file for a model that's already on disk.
  Future<void> downloadVisionFile(AiModel model) async {
    if (!model.hasVisionProjector || model.mmprojUrl.isEmpty) return;
    if (isDownloadingModel(model.mmprojFilename)) return;
    await _downloadVisionFile(model);
  }

  bool _isIncompleteCatalogFile(AiModel model, int fileBytes) {
    if (model.url.trim().isEmpty || model.isImported || fileBytes <= 0) {
      return false;
    }
    final expectedBytes = _declaredModelBytes(model);
    if (expectedBytes <= 0) return false;
    // Relax threshold to 85% to comfortably accommodate HuggingFace decimal-scaled catalog sizes
    // and rounded metadata sizes (e.g. 770.3MB listed as 0.8GB) while still blocking failed downloads.
    return fileBytes < (expectedBytes * 0.85).round();
  }

  bool get isDownloading => _download.isDownloadingAny;

  String get lastLoadedModelName =>
      _hive.getSetting<String>(AppConstants.keyLocalModelName) ?? '';

  bool get canLoadLastModel =>
      lastLoadedModelName.isNotEmpty && isDownloaded(lastLoadedModelName);

  DownloadProgress? getDownloadProgress(String filename) =>
      _download.activeDownloads[filename];

  bool isDownloadingModel(String filename) =>
      _download.activeDownloads.containsKey(filename);

  void setLocalFilter(String filter) {
    if (localFilters.contains(filter)) {
      localFilter.value = filter;
    }
  }

  /// Can read images: GGUF models that come with a vision projector
  /// (mmproj) file.
  bool isVisionModel(AiModel model) => model.hasVisionProjector;

  bool isUncensoredModel(AiModel model) {
    return AppConstants.isUncensoredModelName(
      '${model.name} ${model.filename} ${model.description}',
    );
  }

  bool isLlamaModel(AiModel model) {
    return model.runtime == AiModel.runtimeLlama ||
        model.filename.toLowerCase().endsWith('.gguf');
  }

  bool isGeneralModel(AiModel model) =>
      !isVisionModel(model) && !isUncensoredModel(model);

  String modelSizeLabel(AiModel model) {
    final bytes = fileSizes[model.filename] ?? 0;
    if (bytes > 0) return DownloadService.formatBytes(bytes);
    return model.size;
  }

  /// This phone's speed from its newest speed test, or null before any.
  /// Reactive: rebuilds an Obx when a speed test finishes.
  DeviceSpeed? get deviceSpeed {
    _inference.benchmarkRevision.value;
    return DeviceSpeed.fromResults(_inference.benchmarkResults, (tested) {
      final m = availableModels
          .firstWhereOrNull((m) => m.name == tested || m.filename == tested);
      return m == null ? 0 : _knownModelBytes(m);
    });
  }

  /// Estimated speed of [model] on this phone, null before any speed test.
  SpeedEstimate? speedEstimate(AiModel model) {
    final bytes = _knownModelBytes(model);
    if (bytes <= 0) return null;
    return deviceSpeed?.estimate(bytes, model.name);
  }

  /// The best catalogue model of a type for this phone: the biggest that
  /// fits in RAM and still generates at a usable speed (speed_estimate.dart).
  /// Null before any speed test.
  AiModel? bestForPhone(bool Function(AiModel) ofType) {
    final speed = deviceSpeed;
    if (speed == null) return null;
    final candidates = [
      for (final m in availableModels)
        if (!m.isImported && !m.isCustom && ofType(m))
          ModelCandidate(m, m.name, _knownModelBytes(m),
              totalBytes: _declaredTotalBytes(m)),
    ];
    final ram = Get.find<DeviceInfoService>().totalRamGB.value;
    return bestModelFor(candidates, speed, ram)?.model;
  }

  /// Weights plus vision file, from the catalogue's size ("731 MB + 583 MB
  /// vision"), or the file on disk.
  int _declaredTotalBytes(AiModel model) {
    var total = 0;
    for (final m in RegExp(r'([\d.]+)\s*(GB|MB)', caseSensitive: false)
        .allMatches(model.size)) {
      final value = double.tryParse(m.group(1) ?? '') ?? 0;
      total +=
          (value * (m.group(2)!.toUpperCase() == 'GB' ? 1e9 : 1e6)).round();
    }
    return total > 0 ? total : _knownModelBytes(model);
  }

  int _knownModelBytes(AiModel model) {
    final detected = fileSizes[model.filename] ?? 0;
    if (detected > 0) return detected;
    return _declaredModelBytes(model);
  }

  int _declaredModelBytes(AiModel model) {
    final match = RegExp(r'([\d.]+)\s*(GB|MB)', caseSensitive: false)
        .firstMatch(model.size);
    if (match == null) return 0;
    final value = double.tryParse(match.group(1) ?? '') ?? 0;
    final unit = (match.group(2) ?? '').toUpperCase();
    // Catalog sizes follow Hugging Face (decimal: 1 GB = 10^9 bytes).
    // Reading them as binary inflated every expectation by ~7% and flagged
    // complete downloads as incomplete.
    if (unit == 'GB') return (value * 1000 * 1000 * 1000).round();
    if (unit == 'MB') return (value * 1000 * 1000).round();
    return 0;
  }

  String _formatModelSize(String filename) {
    final bytes = fileSizes[filename] ?? 0;
    if (bytes <= 0) return 'Local File';
    return DownloadService.formatBytes(bytes);
  }
}
