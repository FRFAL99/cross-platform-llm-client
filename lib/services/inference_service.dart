import 'dart:async';
import 'dart:math' show max;
import 'package:get/get.dart';
import 'hive_service.dart';
import '../core/constants.dart';
import 'device_info_service.dart';
import 'app_log_service.dart';
import 'cluster_service.dart';
import 'context_window.dart';
import 'history_summary.dart';
import 'lost_worker_retry.dart';
import '../utils/thought_parser.dart';
import 'stop_sequence_filter.dart';
import '../core/ui.dart' show showToast, ToastTone;
import '../models/benchmark_result.dart';
import 'decisions/decision_engine.dart';

// Conditionally import llama_flutter_android — only on Android
import 'inference_android.dart' if (dart.library.html) 'inference_stub.dart'
    as platform;

/// Cross-platform inference service.
/// - Android / iOS: uses llama_flutter_android for local GGUF models
/// - Web: no local inference
class InferenceService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  // ── Observable State ──
  final isModelLoaded = false.obs;
  final isGenerating = false.obs;
  final isLoadingModel = false.obs;
  final isVisionLoaded = false.obs;
  final loadingModelName = ''.obs;
  final loadedModelName = ''.obs;
  final tokenCount = 0.obs;
  final tokensPerSecond = 0.0.obs;
  final contextTokensUsed = 0.obs;
  final contextTokensTotal = 0.obs;
  final modelLoadProgress = 0.0.obs;
  final generationSource = ''.obs;
  final streamingText = ''.obs;
  final gpuName = ''.obs;
  final gpuLayersUsed = 0.obs;
  int _generationId = 0;

  /// Incremented whenever a generation is stopped early (by the user, a
  /// newer generation, or a disconnecting server client). Callers compare it
  /// before/after generate() to detect that their result was cut short.
  int get stopCount => _stopCount;

  /// Token counts of the last finished generation, for the API's `usage`.
  /// Null while generating or when it failed.
  GenerationUsage? lastUsage;
  int _stopCount = 0;
  final isGpuAccelerated = false.obs;
  final loadedModelRuntime = ''.obs;
  final loadedBackend = ''.obs;

  /// Whether the current platform supports local inference.
  bool get supportsLocalInference => platform.supportsLocalInference;

  // Platform-specific engine
  platform.InferenceEngine? _engine;
  String _sessionNativeRuntime = '';

  String get sessionNativeRuntime => _sessionNativeRuntime;

  /// The speed test is running (the model is busy meanwhile).
  final isBenchmarking = false.obs;

  /// Speed test history, newest first.
  List<BenchmarkResult> get benchmarkResults => [
        for (final raw
            in _hive.getSetting<List>(AppConstants.keyBenchmarkResults) ??
                const [])
          if (BenchmarkResult.fromMap(raw) case final r?) r,
      ];

  /// Measures the loaded model like llama-bench (read [promptTokens] in
  /// batches, then generate [genTokens] one by one) and saves the result.
  /// Uses the model exclusively: chat and server requests wait meanwhile.
  /// Returns null if it was stopped.
  Future<BenchmarkResult?> runBenchmark(
      {int promptTokens = 512, int genTokens = 128}) async {
    final engine = _engine;
    if (engine == null || !isModelLoaded.value) {
      throw Exception('Load a model first.');
    }
    if (isGenerating.value || isBenchmarking.value) {
      throw Exception('The model is busy. Try again when it has finished.');
    }
    isBenchmarking.value = true;
    isGenerating.value = true;
    generationSource.value = 'benchmark';
    try {
      final speed =
          await engine.benchmark(prompt: promptTokens, gen: genTokens);
      if (speed == null) return null;
      final cluster = Get.isRegistered<ClusterService>()
          ? Get.find<ClusterService>()
          : null;
      final where = cluster?.splitSummary ??
          'This phone (${isGpuAccelerated.value ? 'GPU' : 'CPU'})';
      final result = BenchmarkResult(
        model: loadedModelName.value,
        setup: where,
        promptTps: speed.promptTokensPerSecond,
        generationTps: speed.generationTokensPerSecond,
        promptTokens: promptTokens,
        generatedTokens: genTokens,
        date: DateTime.now(),
      );
      final history =
          [result, ...benchmarkResults].take(30).map((r) => r.toMap()).toList();
      await _hive.setSetting(AppConstants.keyBenchmarkResults, history);
      Get.find<AppLogService>()
          .info('Speed test: ${result.model} on ${result.setup}: '
              'prompt ${result.promptTps.toStringAsFixed(1)} tok/s, '
              'generation ${result.generationTps.toStringAsFixed(1)} tok/s');
      return result;
    } finally {
      // The test empties the model's cache; the next chat turn refills it.
      isBenchmarking.value = false;
      isGenerating.value = false;
      generationSource.value = '';
    }
  }

  /// A decision request owns the model (like the speed test, a chat turn
  /// waits for it instead of stopping it).
  bool _deciding = false;

  /// Answers a `/v1/decisions` request (typed decisions with probabilities)
  /// by reading the answer letters' logits: no tokens are generated. Throws
  /// a `DecisionRequestError` for an invalid request. Returns null if it was
  /// stopped. A cluster worker that drops is left out (the model reloads)
  /// and the request runs once more.
  Future<Map<String, dynamic>?> decide(Object? body) async {
    final engine = _engine;
    if (engine == null || !isModelLoaded.value) {
      throw Exception('Load a model first.');
    }
    if (isGenerating.value || _deciding) {
      throw Exception('The model is busy. Try again when it has finished.');
    }
    _deciding = true;
    isGenerating.value = true;
    generationSource.value = 'decisions';
    final stops = _stopCount;
    try {
      Future<ScoredPrompts> score(List<DecisionPrompt> prompts) async {
        for (var attempt = 0;; attempt++) {
          try {
            final out = await engine.scoreOptions(
              system: prompts.first.system,
              users: [for (final p in prompts) p.user],
              counts: [for (final p in prompts) p.options],
            );
            if (out == null || _stopCount != stops) {
              throw const _DecisionsStopped();
            }
            return ScoredPrompts([
              for (var i = 0; i < prompts.length; i++)
                OptionScores(out.logits[i], out.promptTokens[i]),
            ], out.sharedPrefixTokens);
          } catch (e) {
            final message = '$e';
            if (attempt > 0 ||
                !message.contains(AppConstants.clusterWorkerLostError)) {
              rethrow;
            }
            final worker = _lostEndpoint(message);
            Get.find<AppLogService>()
                .error('Phone cluster worker lost', details: worker);
            final name = Get.isRegistered<ClusterService>()
                ? Get.find<ClusterService>().nameFor(worker)
                : worker;
            // The reload needs the model free.
            isGenerating.value = false;
            final ok = await _recoverFromLostWorker(name);
            isGenerating.value = true;
            if (!ok || _stopCount != stops) rethrow;
          }
        }
      }

      return await runDecisions(body, score: score, model: {
        'id': loadedModelName.value,
        'runtime': 'llama.cpp',
        'backend': isGpuAccelerated.value ? 'gpu' : 'cpu',
      });
    } on _DecisionsStopped {
      return null;
    } finally {
      isGenerating.value = false;
      _deciding = false;
      if (generationSource.value == 'decisions') generationSource.value = '';
    }
  }

  Future<void> clearBenchmarkResults() =>
      _hive.setSetting(AppConstants.keyBenchmarkResults, const []);

  /// Messages of the last request's history that didn't fit in the context
  /// window and were left out (the oldest ones).
  final droppedHistoryMessages = 0.obs;

  /// Token counts by text, so each turn only counts its new messages.
  final _tokenCounts = <String, int>{};

  /// Keeps the most recent messages that fit in the context window next to
  /// the system prompt, the new prompt and room for the reply, cutting
  /// between messages (never inside one). The native side still trims the
  /// middle of a prompt that is too long on its own.
  Future<List<Map<String, String>>?> _fitHistory({
    required String prompt,
    required String systemPrompt,
    required List<Map<String, String>>? history,
    required int reserveTokens,
  }) async {
    droppedHistoryMessages.value = 0;
    if (history == null || history.isEmpty) return history;
    final keepFrom = await historyCut(
      prompt: prompt,
      systemPrompt: systemPrompt,
      history: history,
      reserveTokens: reserveTokens,
    );
    droppedHistoryMessages.value = keepFrom;
    if (keepFrom > 0) {
      Get.find<AppLogService>().info(
          'Context: left out the $keepFrom oldest of ${history.length} messages');
    }
    return history.sublist(keepFrom);
  }

  /// How many of the oldest [history] messages must be left out so the rest
  /// fits in the context window with [prompt], [systemPrompt] and
  /// [reserveTokens] for the reply (see [ContextWindow.firstToKeep]). Zero
  /// when no model is loaded.
  Future<int> historyCut({
    required String prompt,
    required String systemPrompt,
    required List<Map<String, String>> history,
    required int reserveTokens,
  }) async {
    final ctx = contextTokensTotal.value;
    if (history.isEmpty || ctx <= 0) return 0;
    final counts = await _countTokens(
        [systemPrompt, prompt, for (final m in history) m['content'] ?? '']);
    return ContextWindow.firstToKeep(
      history: history,
      messageTokens: counts.sublist(2),
      systemTokens: counts[0],
      promptTokens: counts[1],
      contextTokens: ctx,
      reserveTokens: reserveTokens,
    );
  }

  /// The reply budget a chat turn uses: the Max tokens setting.
  int get chatReplyTokens =>
      _hive.getSetting<int>(AppConstants.keyMaxTokens,
          defaultValue: AppConstants.defaultMaxTokens) ??
      AppConstants.defaultMaxTokens;

  /// Summarizes [messages] (oldest first), folding in [previous], the
  /// summary of what came before them. Long runs are summarized a part at a
  /// time so each request fits in the context window. Returns null when the
  /// model is missing, a request fails or the user stops it.
  Future<String?> summarizeHistory({
    String? previous,
    required List<Map<String, String>> messages,
  }) async {
    final ctx = contextTokensTotal.value;
    if (messages.isEmpty || ctx <= 0) return previous;
    final counts =
        await _countTokens([for (final m in messages) m['content'] ?? '']);
    final int previousTokens =
        previous == null ? 0 : (await _countTokens([previous])).first;
    // Room left for the transcript: the context minus the instructions,
    // the summary so far and the summary being written.
    const summaryTokens = HistorySummarizer.maxSummaryTokens;
    final budget = ctx -
        summaryTokens * 2 -
        (previousTokens > summaryTokens ? previousTokens : summaryTokens) -
        96;
    var summary = previous;
    for (final group in HistorySummarizer.chunks(messages, counts,
        budget: budget < 256 ? 256 : budget)) {
      final stops = _stopCount;
      final text = await generate(
        prompt: HistorySummarizer.prompt(summary, group),
        systemPrompt: HistorySummarizer.systemPrompt,
        source: 'summary',
        maxTokens: HistorySummarizer.maxSummaryTokens,
        temperature: 0.2,
      );
      if (_stopCount != stops || lastUsage == null) return null;
      final answer = splitThoughtTags(text).answer.trim();
      if (answer.isEmpty ||
          answer.startsWith('ERROR:') ||
          answer.startsWith('⚠️')) {
        Get.find<AppLogService>()
            .warning('Could not summarize earlier messages', details: text);
        return null;
      }
      summary = answer;
    }
    Get.find<AppLogService>()
        .info('Context: summarized ${messages.length} older messages');
    return summary;
  }

  /// Token counts from the model's tokenizer, cached; about 4 characters a
  /// token where the tokenizer isn't available.
  Future<List<int>> _countTokens(List<String> texts) async {
    final missing =
        texts.where((t) => !_tokenCounts.containsKey(t)).toSet().toList();
    if (missing.isNotEmpty) {
      var counted = List<int>.filled(missing.length, -1);
      try {
        counted = await _engine?.countTokens(missing) ?? counted;
      } catch (_) {}
      if (_tokenCounts.length > 2000) _tokenCounts.clear();
      for (var i = 0; i < missing.length; i++) {
        final n = i < counted.length ? counted[i] : -1;
        _tokenCounts[missing[i]] = n >= 0 ? n : (missing[i].length / 4).ceil();
      }
    }
    return [for (final t in texts) _tokenCounts[t]!];
  }

  /// What the last successful load used, to reload after a cluster worker
  /// drops out.
  ({String path, String? name, String? mmproj})? _lastLoad;

  /// The loaded GGUF model has a working vision projector (images allowed).
  bool get ggufVisionLoaded => _engine?.ggufVisionLoaded ?? false;

  Future<String> loadModel(
    String modelPath, {
    String? modelName,
    String? mmprojPath,
  }) async {
    if (!supportsLocalInference) {
      return 'ERROR: Local inference is not available on this platform.';
    }
    if (isLoadingModel.value) return 'ERROR: Model is already loading.';

    if (platform.isRunning32Bit) {
      final lower = modelPath.toLowerCase();
      // A 32-bit process can't map a model this large next to everything else.
      if (lower.endsWith('.gguf') &&
          await _fileBytes(modelPath) > 1536 * 1024 * 1024) {
        return 'ERROR: This model is too large for 32-bit Android. Choose a '
            'GGUF model under 1.5 GB (for example a 1B Q4 model).';
      }
    }

    if (modelPath.toLowerCase().endsWith('.safetensors')) {
      return 'ERROR: .safetensors files are not chat models. Use a GGUF model.';
    }

    try {
      final performanceMode = _hive.getSetting<String>(
            AppConstants.keyPerformanceMode,
            defaultValue: AppConstants.defaultPerformanceMode,
          ) ??
          AppConstants.defaultPerformanceMode;
      // The Performance setting alone decides: CPU safe never uses the GPU;
      // Auto fast and GPU fast try it.
      final allowGgufGpu = performanceMode != 'cpu_safe';
      // Clear crash state left by older versions of the app.
      await _hive.setSetting(AppConstants.keyGgufGpuPending, false);

      await unloadModel();
      isLoadingModel.value = true;
      loadingModelName.value = modelName ?? modelPath.split('/').last;
      modelLoadProgress.value = 0.0;

      _engine = platform.InferenceEngine();

      final contextSize = _hive.getSetting<int>(
            AppConstants.keyContextSize,
            defaultValue: AppConstants.defaultContextSize,
          ) ??
          AppConstants.defaultContextSize;

      final finalContextSize = contextSize;

      final deviceTier = _getDeviceTier();
      final isTensorSoC = _getIsTensorSoC();

      // Phone cluster: GGUF layers spread across worker phones. This phone
      // then runs its share on the CPU.
      var clusterWorkers = 0;
      if (Get.isRegistered<ClusterService>()) {
        clusterWorkers = await Get.find<ClusterService>()
            .applyForNextLoad(modelPath, modelName: modelName);
      }

      final requestedModelName = modelName ?? modelPath.split('/').last;
      var activeModelName = requestedModelName;
      var result = await _loadModelOnEngine(
        modelPath: modelPath,
        contextSize: finalContextSize,
        deviceTier: deviceTier,
        isTensorSoC: isTensorSoC,
        allowGgufGpu: allowGgufGpu && clusterWorkers == 0,
        mmprojPath: mmprojPath,
      );

      if (!result.success) {
        isModelLoaded.value = false;
        isLoadingModel.value = false;
        loadingModelName.value = '';
        modelLoadProgress.value = 0.0;
        loadedModelName.value = '';
        loadedModelRuntime.value = '';
        loadedBackend.value = '';
        gpuName.value = '';
        gpuLayersUsed.value = 0;
        isGpuAccelerated.value = false;
        Get.find<AppLogService>().error(
          'Local model load failed',
          details:
              'model=$requestedModelName, backend=${result.backend}, message=${result.message}',
        );
        return result.message;
      }

      isModelLoaded.value = result.success;
      isLoadingModel.value = false;
      loadingModelName.value = '';
      modelLoadProgress.value = 1.0;
      loadedModelName.value = activeModelName;
      loadedModelRuntime.value = result.runtime;
      if (result.runtime == 'llama') {
        _sessionNativeRuntime = result.runtime;
      }
      loadedBackend.value = result.backend;
      gpuName.value = result.gpuName;
      gpuLayersUsed.value = result.gpuLayers;
      isGpuAccelerated.value = result.backend == 'gpu' || result.gpuLayers > 0;
      contextTokensUsed.value = 0;
      contextTokensTotal.value = finalContextSize;

      _lastLoad = (path: modelPath, name: modelName, mmproj: mmprojPath);
      _tokenCounts.clear();
      await _hive.setSetting(AppConstants.keyLocalModelPath, modelPath);
      await _hive.setSetting(
          AppConstants.keyLocalModelName, loadedModelName.value);
      await _hive.setSetting(
          AppConstants.keyLocalModelRuntime, loadedModelRuntime.value);
      await _hive.setSetting(
          AppConstants.keyLocalModelBackend, loadedBackend.value);

      if (clusterWorkers > 0) {
        final cluster = Get.find<ClusterService>();
        await cluster.refreshSplit(modelPath);
        return 'Model loaded across ${cluster.splitSummary ?? '${clusterWorkers + 1} phones'}.';
      }
      return result.message;
    } catch (e) {
      isModelLoaded.value = false;
      isLoadingModel.value = false;
      loadingModelName.value = '';
      modelLoadProgress.value = 0.0;
      loadedBackend.value = '';
      Get.find<AppLogService>().error('Failed to load local model', details: e);
      return 'ERROR: Failed to load model — $e';
    }
  }

  /// Endpoint of the cluster worker that dropped out during the last
  /// generation, set by [_generateOnce].
  String? _lostWorker;

  /// The reload after a lost worker, shared by every request that hit it.
  Future<bool>? _recovery;

  /// A worker stopped answering mid-answer: the model is missing its layers,
  /// so reload it (the cluster plan leaves out workers that don't answer;
  /// the workers that stayed keep the model's tensors in their cache, so
  /// only the lost worker's share travels again). True if it reloaded.
  Future<bool> _recoverFromLostWorker(String name) {
    final running = _recovery;
    if (running != null) return running;
    final last = _lastLoad;
    if (last == null) return Future.value(false);
    return _recovery = () async {
      try {
        showToast(
            'Phone cluster', '$name stopped answering. Reloading the model…',
            tone: ToastTone.warning);
        final message = await loadModel(last.path,
            modelName: last.name, mmprojPath: last.mmproj);
        if (message.startsWith('ERROR')) {
          showToast('Model not reloaded', message.replaceFirst('ERROR: ', ''),
              tone: ToastTone.error);
          return false;
        }
        showToast('Model reloaded', message, tone: ToastTone.success);
        return true;
      } finally {
        _recovery = null;
      }
    }();
  }

  Future<void> unloadModel() async {
    final engine = _engine;
    _engine = null;
    if (Get.isRegistered<ClusterService>()) {
      Get.find<ClusterService>().clearSplit();
    }
    if (engine != null) {
      // Only count a stop when something was running: callers compare
      // stopCount to tell an interrupted answer, and a reload after a lost
      // cluster worker must not look like one.
      if (isGenerating.value) await stopGeneration();
      await engine.dispose();
    }
    isModelLoaded.value = false;
    isVisionLoaded.value = false;
    loadedModelName.value = '';
    loadingModelName.value = '';
    loadedModelRuntime.value = '';
    loadedBackend.value = '';
    gpuLayersUsed.value = 0;
    isGpuAccelerated.value = false;
    gpuName.value = '';
    contextTokensUsed.value = 0;
    contextTokensTotal.value = 0;
    _sessionNativeRuntime = '';
  }

  /// Generates a reply (see [_generateOnce]). If a phone of the cluster
  /// drops out meanwhile, the model is reloaded on the phones that are left
  /// and the request runs again once, so the caller still gets its answer.
  /// The retry is only transparent while nothing was streamed yet; a caller
  /// that can take back what it showed passes [onRestart], which is called
  /// before the second run starts streaming from the beginning.
  Future<String> generate({
    required String prompt,
    String? systemPrompt,
    List<Map<String, String>>? conversationHistory,
    String source = 'chat',
    String? imagePath,
    String? audioPath,
    int? maxTokens,
    List<String> stopSequences = const [],
    double? temperature,
    double? topP,
    String? grammar,
    String? grammarTrigger,
    void Function(String token)? onToken,
    void Function()? onRestart,
  }) async {
    var stops = _stopCount;
    return LostWorkerRetry.run(
      attempt: (forward) async {
        _lostWorker = null;
        final text = await _generateOnce(
          prompt: prompt,
          systemPrompt: systemPrompt,
          conversationHistory: conversationHistory,
          source: source,
          imagePath: imagePath,
          audioPath: audioPath,
          maxTokens: maxTokens,
          stopSequences: stopSequences,
          temperature: temperature,
          topP: topP,
          grammar: grammar,
          grammarTrigger: grammarTrigger,
          onToken: forward,
        );
        final lost = _lostWorker;
        _lostWorker = null;
        return (text: text, lostWorker: lost);
      },
      nameFor: (worker) => Get.isRegistered<ClusterService>()
          ? Get.find<ClusterService>().nameFor(worker)
          : worker,
      recover: (worker) {
        stops = _stopCount;
        Get.find<AppLogService>()
            .error('Phone cluster worker lost', details: worker);
        final name = Get.isRegistered<ClusterService>()
            ? Get.find<ClusterService>().nameFor(worker)
            : worker;
        return _recoverFromLostWorker(name);
      },
      stopped: () => _stopCount != stops,
      onRetry: (worker) => Get.find<AppLogService>()
          .info('Phone cluster: answering again without $worker'),
      onToken: onToken,
      onRestart: onRestart,
    );
  }

  /// One generation with the loaded model.
  Future<String> _generateOnce({
    required String prompt,
    String? systemPrompt,
    List<Map<String, String>>? conversationHistory,
    String source = 'chat',
    String? imagePath,
    String? audioPath,
    int? maxTokens,
    List<String> stopSequences = const [],
    double? temperature,
    double? topP,
    String? grammar,
    String? grammarTrigger,
    void Function(String token)? onToken,
  }) async {
    lastUsage = null;
    if (!supportsLocalInference || _engine == null || !isModelLoaded.value) {
      return 'ERROR: No model loaded. Go to Models tab to download and load one.';
    }

    // The speed test owns the model until it ends (stopping it midway
    // would race with the native benchmark); wait instead.
    while (isBenchmarking.value || _deciding) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (isGenerating.value) {
      // Wait for previous generation
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!isGenerating.value) break;
      }
      if (isGenerating.value) {
        await stopGeneration();
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }

    // Identifies this generation so a stopped one that finishes late can't
    // reset the state of the generation that replaced it.
    final generationId = ++_generationId;
    bool isCurrent() => generationId == _generationId;

    isGenerating.value = true;
    tokenCount.value = 0;
    tokensPerSecond.value = 0.0;
    generationSource.value = source;
    streamingText.value = '';

    final startTime = DateTime.now();
    DateTime? firstVisibleTokenAt;
    final tokenFlushBuffer = StringBuffer();

    void flushTokenBuffer() {
      if (tokenFlushBuffer.isEmpty) return;
      final text = tokenFlushBuffer.toString();
      tokenFlushBuffer.clear();
      onToken?.call(text);
    }

    final stopFilter = StopSequenceFilter(stopSequences);
    var stopSequenceHit = false;

    try {
      final settingTemperature = _hive.getSetting<double>(
            AppConstants.keyTemperature,
            defaultValue: AppConstants.defaultTemperature,
          ) ??
          AppConstants.defaultTemperature;

      final settingMaxTokens = _hive.getSetting<int>(
            AppConstants.keyMaxTokens,
            defaultValue: AppConstants.defaultMaxTokens,
          ) ??
          AppConstants.defaultMaxTokens;
      final effectiveMaxTokens = (maxTokens != null && maxTokens > 0)
          ? (maxTokens < settingMaxTokens ? maxTokens : settingMaxTokens)
          : settingMaxTokens;

      final fittedHistory = await _fitHistory(
        prompt: prompt,
        systemPrompt: systemPrompt ?? AppConstants.systemPrompt,
        history: conversationHistory,
        reserveTokens: effectiveMaxTokens,
      );

      final result = await _engine!.generate(
        prompt: prompt,
        conversationHistory: fittedHistory,
        systemPrompt: systemPrompt ?? AppConstants.systemPrompt,
        modelName: loadedModelName.value,
        maxTokens: effectiveMaxTokens,
        temperature: temperature ?? settingTemperature,
        topP: topP,
        imagePath: imagePath,
        audioPath: audioPath,
        source: source,
        grammar: grammar,
        grammarTrigger: grammarTrigger,
        onToken: (rawToken) {
          if (!isCurrent()) return;
          var token = rawToken;
          if (stopFilter.isActive) {
            token = stopFilter.add(rawToken);
            if (stopFilter.stopped && !stopSequenceHit) {
              stopSequenceHit = true;
              // Halt the engine directly: this is a normal finish, not a
              // user/server interruption, so stopCount must not change.
              unawaited(
                  _engine?.stop().catchError((_) {}) ?? Future<void>.value());
            }
            if (token.isEmpty) return;
          }
          firstVisibleTokenAt ??= DateTime.now();
          tokenCount.value++;
          streamingText.value += token;
          final speedStart = firstVisibleTokenAt ?? startTime;
          final elapsedSeconds =
              DateTime.now().difference(speedStart).inMilliseconds / 1000.0;
          if (elapsedSeconds > 0) {
            tokensPerSecond.value = tokenCount.value / elapsedSeconds;
          }
          onToken?.call(token);
        },
      );
      if (!isCurrent()) return result;
      if (stopFilter.isActive) {
        final tail = stopFilter.flush();
        if (tail.isNotEmpty) {
          streamingText.value += tail;
          tokenFlushBuffer.write(tail);
        }
      }
      flushTokenBuffer();
      final finalText = stopSequenceHit ? stopFilter.text : result;

      await refreshContextInfo();
      if (isCurrent()) {
        // The context now holds the whole prompt plus the reply.
        final completion = _engine!.lastCompletionTokens;
        lastUsage = GenerationUsage(
          promptTokens: max(0, contextTokensUsed.value - completion),
          completionTokens: completion,
        );
        isGenerating.value = false;
        generationSource.value = '';
      }

      // Detect Tensor SoC + Gemma Q4_K_M corruption: model outputs only
      // special tokens and terminates immediately with empty result.
      if (result.trim().isEmpty &&
          tokenCount.value < 5 &&
          loadedModelName.value.toLowerCase().contains('gemma')) {
        final isTensor = _getIsTensorSoC();
        if (isTensor) {
          return '⚠️ This Gemma model is incompatible with your Pixel\'s Google Tensor chip. '
              'The Q4_K_M quantization format has a known bug on Tensor SoC that produces empty responses.\n\n'
              'Try one of these fixes:\n'
              '1. Download a Q4_0 or Q5_K_M version of the same model\n'
              '2. Use a different model (Qwen, Phi, or Llama-3)';
        }
      }

      if (result.contains(AppConstants.clusterWorkerLostError)) {
        _lostWorker = _lostEndpoint(result);
        return result;
      }
      return finalText;
    } catch (e) {
      if (isCurrent()) {
        isGenerating.value = false;
        generationSource.value = '';
        streamingText.value = '';
        flushTokenBuffer();
      }
      if ('$e'.contains(AppConstants.clusterWorkerLostError)) {
        _lostWorker = _lostEndpoint('$e');
        return 'ERROR: $e';
      }
      Get.find<AppLogService>().error('Local generation failed', details: e);
      return 'ERROR: $e';
    }
  }

  static String _lostEndpoint(String error) =>
      RegExp('${AppConstants.clusterWorkerLostError}([0-9A-Za-z.:\\-]+)')
          .firstMatch(error)
          ?.group(1) ??
      'a worker';

  Future<void> stopGeneration() async {
    _generationId++;
    _stopCount++;
    isGenerating.value = false;
    tokenCount.value = 0;
    generationSource.value = '';
    streamingText.value = '';
    final engine = _engine;
    if (engine != null) {
      unawaited(engine.stop().timeout(const Duration(seconds: 1)).catchError(
            (_) {},
          ));
    }
  }

  /// Reset the native conversation context. Call this whenever the user
  /// switches to a different chat session so old context doesn't leak.
  Future<void> resetConversation() async {
    final engine = _engine;
    if (engine != null) {
      await engine.resetConversation();
    }
  }

  Future<void> refreshContextInfo() async {
    if (!supportsLocalInference || _engine == null || !isModelLoaded.value) {
      return;
    }

    final info = await _engine!.getContextInfo();
    if (info == null) return;

    contextTokensUsed.value = info.tokensUsed;
    contextTokensTotal.value = info.contextSize;
  }

  String _getDeviceTier() {
    try {
      final device = Get.find<DeviceInfoService>();
      return device.deviceTier.value;
    } catch (_) {
      return 'mid';
    }
  }

  bool _getIsTensorSoC() {
    try {
      final device = Get.find<DeviceInfoService>();
      return device.isTensorSoC.value;
    } catch (_) {
      return false;
    }
  }

  Future<platform.LoadResult> _loadModelOnEngine({
    required String modelPath,
    required int contextSize,
    required String deviceTier,
    bool isTensorSoC = false,
    bool allowGgufGpu = false,
    String? mmprojPath,
  }) async {
    try {
      return await _engine!.loadModel(
        modelPath: modelPath,
        contextSize: contextSize,
        deviceTier: deviceTier,
        isTensorSoC: isTensorSoC,
        allowGgufGpu: allowGgufGpu,
        mmprojPath: mmprojPath,
        onProgress: (p) => modelLoadProgress.value = _normalizeProgress(p),
      );
    } catch (e) {
      return platform.LoadResult(
        success: false,
        message: 'ERROR: Failed to load model - $e',
      );
    }
  }

  Future<int> _fileBytes(String path) async {
    try {
      return await platform.fileLength(path);
    } catch (_) {
      return 0;
    }
  }

  double _normalizeProgress(double progress) {
    if (progress.isNaN || progress.isInfinite) return 0.0;
    final normalized = progress > 1 ? progress / 100 : progress;
    return normalized.clamp(0.0, 1.0).toDouble();
  }
}

/// Tokens read and written by one generation.
class GenerationUsage {
  final int promptTokens;
  final int completionTokens;
  const GenerationUsage(
      {required this.promptTokens, required this.completionTokens});

  int get totalTokens => promptTokens + completionTokens;

  Map<String, int> toJson() => {
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'total_tokens': totalTokens,
      };
}

class _DecisionsStopped implements Exception {
  const _DecisionsStopped();
}
