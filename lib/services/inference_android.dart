import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io' show Platform, File;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:llama_flutter_android/llama_flutter_android.dart';

/// Whether the current platform supports local inference.
bool get supportsLocalInference => Platform.isAndroid || Platform.isIOS;

/// True when the app runs as a 32-bit process (32-bit Android, e.g. Android
/// Go phones). The address space limits model size.
bool get isRunning32Bit =>
    Abi.current() == Abi.androidArm || Abi.current() == Abi.androidIA32;

Future<int> fileLength(String path) => File(path).length();

/// Result from model loading.
class LoadResult {
  final bool success;
  final String message;
  final String gpuName;
  final int gpuLayers;
  final String runtime;
  final String backend;
  LoadResult({
    required this.success,
    required this.message,
    this.gpuName = '',
    this.gpuLayers = 0,
    this.runtime = '',
    this.backend = '',
  });
}

/// Android & iOS inference engine — wraps llama_flutter_android.
class InferenceEngine {
  LlamaController? _controller;
  StreamSubscription? _subscription;
  StreamSubscription? _loadProgressSub;
  Timer? _idleTimer;
  void Function()? _onStop;
  // GGUF model loaded together with a working vision projector.
  bool _ggufVisionLoaded = false;
  bool get ggufVisionLoaded => _ggufVisionLoaded;
  bool _disposed = false;
  bool _hasLoadedModel = false;
  String? _modelPath;

  Future<LoadResult> loadModel({
    required String modelPath,
    required int contextSize,

    /// CPU threads: one per performance core (DeviceInfoService.cpuThreads).
    required int cpuThreads,
    bool isTensorSoC = false,
    bool allowGgufGpu = true,
    String? mmprojPath,
    void Function(double)? onProgress,
  }) async {
    _disposed = false;
    if (modelPath.toLowerCase().endsWith('.litertlm')) {
      return LoadResult(
        success: false,
        message: 'LiteRT models are no longer supported. Use a GGUF model.',
      );
    }

    _ggufVisionLoaded = false;
    _controller = LlamaController();

    // The native plugin can still hold a model this engine never loaded
    // (e.g. after a Dart hot restart, or if an earlier unload was skipped).
    // Free it first so the model the user picked actually loads.
    try {
      if (await _controller!.isModelLoaded()) {
        print('[Inference] Freeing a stale native model before loading');
        await _controller!.dispose();
        _controller = LlamaController();
      }
    } catch (_) {}

    // ── GPU Detection ──
    int gpuLayers = 0;
    String gpuNameStr = '';

    try {
      if (!allowGgufGpu) {
        throw StateError('GPU disabled by CPU Safe mode');
      }
      final gpu = await _controller!.detectGpu();
      gpuNameStr = gpu.gpuName;

      print('[Inference] GPU: ${gpu.gpuName}');
      print('[Inference]   Vulkan: ${gpu.vulkanSupported}');
      print('[Inference]   Free RAM: ${gpu.freeRamBytes ~/ 1024 ~/ 1024}MB');
      print('[Inference]   Recommended layers: ${gpu.recommendedGpuLayers}');

      // The plugin decides eligibility (SoC/driver blocklist, free RAM).
      if (gpu.vulkanSupported && gpu.recommendedGpuLayers > 0) {
        // On phones the GPU shares system RAM, and offloading copies the
        // weights into GPU buffers (CPU mode maps the file instead). If the
        // model + vision file won't fit in free RAM with that copy, Android's
        // low-memory killer closes the app — so stay on the CPU.
        final modelBytes = await _fileLength(modelPath);
        final visionBytes =
            mmprojPath == null ? 0 : await _fileLength(mmprojPath);
        final needed = ((modelBytes + visionBytes) * 1.25).round();
        final free = gpu.freeRamBytes;
        if (free > 0 && needed > free) {
          print('[Inference] Model needs ~${needed ~/ (1024 * 1024)}MB for GPU '
              'offload but only ${free ~/ (1024 * 1024)}MB is free — using CPU');
        } else {
          gpuLayers = gpu.recommendedGpuLayers;
          print(
              '[Inference] ✓ GPU offload: $gpuLayers layers on ${gpu.gpuName}');
        }
      }
    } catch (e) {
      print('[Inference] GPU detection failed: $e — CPU fallback');
    }

    // ── Thread Tuning ──
    // One thread per performance core: threads on the efficiency cores make
    // llama.cpp wait for its slowest thread. With the GPU, the CPU only feeds
    // it and runs the layers left on the CPU.
    int threads = gpuLayers > 0 ? cpuThreads.clamp(1, 4) : cpuThreads;

    // Google Tensor SoC (Pixel 6/7/8) has known Q4_K_M dequant bugs
    // that corrupt logits at >1 thread on Gemma models. Force single-threaded
    // to eliminate KV cache races in the quantization dot-product path.
    final modelName = modelPath.toLowerCase();
    if (isTensorSoC && modelName.contains('gemma')) {
      threads = 1;
      print(
          '[Inference] Tensor SoC + Gemma detected — forcing single-threaded inference');
    }

    // ── Load Progress ──
    await _loadProgressSub?.cancel();
    _loadProgressSub = null;
    try {
      _loadProgressSub = _controller!.loadProgress.listen((progress) {
        onProgress?.call(_normalizeProgress(progress));
      });
    } catch (_) {}

    // ── Load ──
    final visionError = await _controller!.loadModel(
      modelPath: modelPath,
      threads: threads,
      contextSize: contextSize,
      gpuLayers: gpuLayers,
      mmprojPath: mmprojPath,
    );
    _hasLoadedModel = true;
    _modelPath = modelPath;
    _ggufVisionLoaded = mmprojPath != null && visionError == null;
    if (visionError != null) {
      print('[Inference] Vision projector not loaded: $visionError');
    }

    final accel = gpuLayers > 0
        ? 'GPU ($gpuLayers layers, $gpuNameStr)'
        : 'CPU ($threads threads)';
    print('[Inference] ✓ Model loaded: $accel, ctx=$contextSize');

    return LoadResult(
      success: true,
      message: 'Model loaded ($accel).',
      gpuName: gpuNameStr,
      gpuLayers: gpuLayers,
      runtime: 'llama',
      backend: gpuLayers > 0 ? 'gpu' : 'cpu',
    );
  }

  double _normalizeProgress(double progress) {
    if (progress.isNaN || progress.isInfinite) return 0.0;
    final normalized = progress > 1 ? progress / 100 : progress;
    return normalized.clamp(0.0, 1.0).toDouble();
  }

  Future<String> generate({
    required String prompt,
    List<Map<String, String>>? conversationHistory,
    required String systemPrompt,
    required String modelName,
    required int maxTokens,
    required double temperature,
    double? topP,
    String? imagePath,
    String? audioPath,
    String source = 'chat',
    String? grammar,
    String? grammarTrigger,
    void Function(String token)? onToken,
  }) async {
    if (_controller == null) throw Exception('No model loaded');
    lastCompletionTokens = 0;
    if (imagePath != null && imagePath.isNotEmpty && !_ggufVisionLoaded) {
      return 'This model can\'t read images. Load a vision model (one marked '
          'Vision in Models) to ask about photos.';
    }
    if (audioPath != null && audioPath.isNotEmpty) {
      return 'GGUF audio input is not available in this build yet. Text files can be read when their content is attached, but audio needs a model/runtime path that supports audio input.';
    }

    final completer = Completer<String>();
    final buffer = StringBuffer();
    bool completed = false;
    final controller = _controller;

    // Timeouts and stop must halt the native engine too; cancelling the Dart
    // subscription alone leaves llama.cpp generating in the background.
    void finish(String result, {bool stopNative = true}) {
      if (!completed && !_disposed) {
        completed = true;
        _idleTimer?.cancel();
        _subscription?.cancel();
        _onStop = null;
        if (stopNative) {
          unawaited(controller
                  ?.stop()
                  .timeout(const Duration(seconds: 1))
                  .catchError((_) {}) ??
              Future<void>.value());
        }
        if (!completer.isCompleted) completer.complete(result);
      }
    }

    _onStop = () {
      finish(buffer.toString());
    };

    // ── Use generateChat() for native template handling ──
    Stream<String>? stream;
    try {
      final messages = _buildChatMessages(
          prompt, conversationHistory, systemPrompt,
          imagePath: imagePath);
      stream = _controller!.generateChat(
        messages: messages,
        template: null,
        maxTokens: maxTokens,
        temperature: temperature,
        topP: topP ?? 0.9,
        topK: 40,
        minP: 0.05,
        repeatPenalty: 1.1,
        repeatLastN: 64,
        grammar: grammar,
        grammarTrigger: grammarTrigger,
      );
      print('[Inference] generateChat() started (${messages.length} messages)');
    } catch (e) {
      print('[Inference] generateChat() failed: $e — fallback to generate()');
      try {
        await _controller!.stop();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 100));
      final fullPrompt =
          _buildPrompt(prompt, conversationHistory, systemPrompt, modelName);
      stream = _controller!.generate(
        prompt: fullPrompt,
        maxTokens: maxTokens,
        temperature: temperature,
        topP: 0.9,
        topK: 40,
        minP: 0.05,
        repeatPenalty: 1.1,
        repeatLastN: 64,
      );
    }

    int tokenCount = 0;
    _subscription = stream.listen(
      (token) {
        lastCompletionTokens++;
        if (tokenCount == 0) {
          print('[Inference] ✓ FIRST TOKEN received! Prefill done.');
        }
        // Any token (even one that cleans to nothing) means the engine is
        // alive. The limit only catches a stuck engine: big models on CPU
        // can pause several seconds between tokens.
        _idleTimer?.cancel();
        _idleTimer = Timer(_tokenStallTimeout, () {
          print('[Inference] Idle timeout — $tokenCount tokens');
          finish(buffer.toString());
        });
        final clean = _sanitizeGemmaGarbage(token);
        if (clean.isEmpty) return;
        buffer.write(clean);
        tokenCount++;
        onToken?.call(clean);
      },
      onDone: () {
        print('[Inference] Stream onDone — $tokenCount tokens total');
        finish(buffer.toString(), stopNative: false);
      },
      onError: (error) {
        print('[Inference] Stream error: $error');
        finish('ERROR: Generation failed — $error');
      },
    );

    // Prefill timeout
    _idleTimer = Timer(const Duration(seconds: 60), () {
      if (tokenCount == 0) {
        finish(
            'ERROR: Model did not respond. Try a smaller model or shorter conversation.');
      }
    });

    // Hard timeout
    Future.delayed(_hardTimeout(maxTokens, minSeconds: 180), () {
      if (!completed) {
        final partial = buffer.toString();
        finish(partial.isEmpty
            ? 'ERROR: Generation timed out.'
            : '$partial$_timeLimitNote');
      }
    });

    return await completer.future;
  }

  /// Tokens the model produced in the last generation (one stream event
  /// per native token, including ones that print nothing).
  int lastCompletionTokens = 0;

  /// Speed of the loaded model ([prompt tok/s, generation tok/s]), or null
  /// if stopped. Throws when this platform can't measure it.
  Future<LlamaBenchmark?> benchmark({int prompt = 512, int gen = 128}) async {
    if (_controller == null) throw Exception('No model loaded');
    try {
      return await LlamaTools.benchmark(prompt: prompt, gen: gen);
    } on MissingPluginException {
      throw Exception('The speed test is only available on Android.');
    }
  }

  /// Answer-letter logits of decision prompts, read without generating
  /// (see [LlamaTools.scoreOptions]). Null if stopped.
  Future<LlamaOptionScores?> scoreOptions({
    required String system,
    required List<String> users,
    required List<int> counts,
  }) async {
    if (_controller == null) throw Exception('No model loaded');
    try {
      return await LlamaTools.scoreOptions(
          system: system, users: users, counts: counts, modelPath: _modelPath);
    } on MissingPluginException {
      throw Exception('Decisions are only available on Android.');
    }
  }

  /// Token counts for [texts] with the loaded model's tokenizer; -1 where
  /// unknown (no model, or a platform without token counting).
  Future<List<int>> countTokens(List<String> texts) async {
    if (_controller == null || texts.isEmpty) {
      return List.filled(texts.length, -1);
    }
    try {
      return await LlamaTools.countTokens(texts);
    } catch (_) {
      return List.filled(texts.length, -1);
    }
  }

  Future<void> stop() async {
    if (_disposed) return;
    _idleTimer?.cancel();
    final stopCallback = _onStop;
    _onStop = null;
    stopCallback?.call();
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    try {
      await _controller?.stop().timeout(const Duration(milliseconds: 800));
    } catch (_) {}
  }

  /// Reset any persistent conversation state so the next generation
  /// starts with a clean context. Essential when switching chat sessions.
  Future<void> resetConversation() async {
    // llama.cpp (GGUF) is stateless per-generation — no native
    // conversation object to reset.
  }

  Future<ContextInfo?> getContextInfo() async {
    try {
      return await _controller?.getContextInfo();
    } catch (_) {
      return null;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    if (_hasLoadedModel) {
      try {
        await _controller?.dispose();
      } catch (_) {}
    }
    unawaited(_loadProgressSub?.cancel() ?? Future<void>.value());
    _loadProgressSub = null;
    _controller = null;
    _hasLoadedModel = false;
  }

  // ── Helpers ──

  /// Safety cap on a single generation. It scales with the token budget
  /// (allowing ~1 token/s) so slow phones aren't cut off mid-answer; the idle
  /// timeouts already catch a model that has stopped producing tokens.
  static Duration _hardTimeout(int maxTokens, {int minSeconds = 180}) =>
      Duration(seconds: maxTokens > minSeconds ? maxTokens : minSeconds);

  static const _timeLimitNote =
      '\n\n⚠️ Stopped: this reply hit the time limit for one response.';

  Future<int> _fileLength(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return 0;
    }
  }

  /// How long generation may go without a new token before it's treated as
  /// stuck and ended.
  static const _tokenStallTimeout = Duration(seconds: 30);

  /// Strip Gemma garbage tokens that leak when Q4_K_M dequant is corrupt
  /// on Google Tensor SoC. Harmless on devices that don't produce them.
  /// NOTE: Do NOT trim() — SentencePiece tokens rely on leading spaces.
  String _sanitizeGemmaGarbage(String text) {
    return text
        .replaceAll(RegExp(r'<unused\d+>'), '')
        .replaceAll(RegExp(r'\[@BOS@\]'), '')
        .replaceAll('<bos>', '')
        .replaceAll('<mask>', '')
        .replaceAll('<pad>', '')
        .replaceAll('<unk>', '')
        .replaceAll('<s>', '')
        .replaceAll('</s>', '');
  }

  List<ChatMessage> _buildChatMessages(
    String prompt,
    List<Map<String, String>>? history,
    String systemPrompt, {
    String? imagePath,
  }) {
    final messages = <ChatMessage>[];
    messages.add(ChatMessage(role: 'system', content: systemPrompt));

    if (history != null && history.isNotEmpty) {
      // InferenceService already fitted the history to the context window
      // by tokens; this cap only guards against pathological lists.
      var recent = history.length > 400
          ? history.sublist(history.length - 400)
          : List.of(history);
      if (recent.isNotEmpty &&
          recent.last['role'] == 'user' &&
          recent.last['content'] == prompt) {
        recent = recent.sublist(0, recent.length - 1);
      }
      for (final msg in recent) {
        final content = msg['content'] ?? '';
        messages
            .add(ChatMessage(role: msg['role'] ?? 'user', content: content));
      }
    }

    messages
        .add(ChatMessage(role: 'user', content: prompt, imagePath: imagePath));
    return messages;
  }

  String _buildPrompt(
    String userMessage,
    List<Map<String, String>>? history,
    String systemPrompt,
    String modelName,
  ) {
    // Auto-detect template from model name
    final name = modelName.toLowerCase();
    if (name.contains('gemma')) {
      return _buildGemma(userMessage, history, systemPrompt);
    }
    if (name.contains('llama-3') || name.contains('llama3')) {
      return _buildLlama3(userMessage, history, systemPrompt);
    }
    return _buildChatML(userMessage, history, systemPrompt);
  }

  String _buildChatML(
      String msg, List<Map<String, String>>? history, String sys) {
    final buf = StringBuffer();
    buf.write('<|im_start|>system\n$sys<|im_end|>\n');
    if (history != null) {
      final recent =
          history.length > 8 ? history.sublist(history.length - 8) : history;
      for (final m in recent) {
        final content = m['content'] ?? '';
        final trunc =
            content.length > 300 ? '${content.substring(0, 300)}...' : content;
        buf.write('<|im_start|>${m['role'] ?? 'user'}\n$trunc<|im_end|>\n');
      }
    }
    buf.write('<|im_start|>user\n$msg<|im_end|>\n<|im_start|>assistant\n');
    return buf.toString();
  }

  String _buildGemma(
      String msg, List<Map<String, String>>? history, String sys) {
    final buf = StringBuffer();
    buf.write(
        '<start_of_turn>user\n$sys<end_of_turn>\n<start_of_turn>model\nUnderstood.<end_of_turn>\n');
    if (history != null) {
      final recent =
          history.length > 4 ? history.sublist(history.length - 4) : history;
      for (final m in recent) {
        final role = m['role'] == 'assistant' ? 'model' : 'user';
        final content = m['content'] ?? '';
        final trunc =
            content.length > 300 ? '${content.substring(0, 300)}...' : content;
        buf.write('<start_of_turn>$role\n$trunc<end_of_turn>\n');
      }
    }
    buf.write('<start_of_turn>user\n$msg<end_of_turn>\n<start_of_turn>model\n');
    return buf.toString();
  }

  String _buildLlama3(
      String msg, List<Map<String, String>>? history, String sys) {
    final buf = StringBuffer();
    buf.write(
        '<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n$sys<|eot_id|>');
    if (history != null) {
      final recent =
          history.length > 4 ? history.sublist(history.length - 4) : history;
      for (final m in recent) {
        final content = m['content'] ?? '';
        final trunc =
            content.length > 300 ? '${content.substring(0, 300)}...' : content;
        buf.write(
            '<|start_header_id|>${m['role'] ?? 'user'}<|end_header_id|>\n\n$trunc<|eot_id|>');
      }
    }
    buf.write(
        '<|start_header_id|>user<|end_header_id|>\n\n$msg<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n');
    return buf.toString();
  }
}
