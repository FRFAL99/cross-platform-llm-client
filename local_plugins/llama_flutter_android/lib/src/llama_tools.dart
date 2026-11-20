import 'package:flutter/services.dart';

/// Speed of the loaded model, like llama-bench's pp/tg numbers.
class LlamaBenchmark {
  /// Prompt processing: tokens read per second (in batches).
  final double promptTokensPerSecond;

  /// Generation: tokens produced per second (one at a time).
  final double generationTokensPerSecond;

  const LlamaBenchmark(
      this.promptTokensPerSecond, this.generationTokensPerSecond);
}

/// Helpers that work on the loaded model (Android).
class LlamaTools {
  LlamaTools._();

  static const _channel = MethodChannel('llama_flutter_android/tools');

  /// Measures the loaded model: [prompt] tokens processed in batches, then
  /// [gen] tokens generated one by one, each from an empty cache; best of
  /// [reps]. Clears the conversation cache. Null if stopped. Must not run
  /// while the model is generating.
  static Future<LlamaBenchmark?> benchmark(
      {int prompt = 512, int gen = 128, int reps = 1}) async {
    final out = await _channel.invokeListMethod<double>(
        'benchmark', {'prompt': prompt, 'gen': gen, 'reps': reps});
    if (out == null || out.length < 2) return null;
    return LlamaBenchmark(out[0], out[1]);
  }

  /// Token count of each text for the loaded model (-1 without a model).
  static Future<List<int>> countTokens(List<String> texts) async {
    if (texts.isEmpty) return const [];
    final out =
        await _channel.invokeListMethod<int>('countTokens', {'texts': texts});
    return out ?? List.filled(texts.length, -1);
  }
}
