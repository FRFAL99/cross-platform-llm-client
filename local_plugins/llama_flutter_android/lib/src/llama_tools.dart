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

/// Answer-letter logits of multiple-choice prompts, read without generating.
class LlamaOptionScores {
  /// Tokens all prompts share, read once.
  final int sharedPrefixTokens;

  /// Per prompt: its token count.
  final List<int> promptTokens;

  /// Per prompt: one logit per answer letter (A, B, …).
  final List<List<double>> logits;

  const LlamaOptionScores(
      this.sharedPrefixTokens, this.promptTokens, this.logits);
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

  /// Scores multiple-choice prompts: each user message, with [system],
  /// is formatted with the model's chat template (picked from [modelPath],
  /// thinking off), and the logits of its first [counts] answer letters are
  /// read in one forward pass. The prompts' shared start is read once and
  /// stays in the cache. Null if stopped. Must not run while the model is
  /// generating. Throws a PlatformException whose message starts with
  /// `CLUSTER_WORKER_LOST:` when a cluster worker dropped.
  static Future<LlamaOptionScores?> scoreOptions({
    required String system,
    required List<String> users,
    required List<int> counts,
    String? modelPath,
  }) async {
    final out = await _channel.invokeListMethod<double>('scoreOptions', {
      'system': system,
      'users': users,
      'counts': counts,
      'modelPath': modelPath,
    });
    if (out == null) return null;
    var at = 1;
    final tokens = <int>[];
    final logits = <List<double>>[];
    for (final count in counts) {
      tokens.add(out[at].round());
      logits.add(out.sublist(at + 1, at + 1 + count));
      at += 1 + count;
    }
    return LlamaOptionScores(out[0].round(), tokens, logits);
  }
}
