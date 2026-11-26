/// One run of the on-device speed test.
class BenchmarkResult {
  final String model;

  /// Where the model ran: "This phone (GPU)", or the cluster split
  /// ("Pixel 8 72% · POCO F1 28%").
  final String setup;

  /// Tokens per second reading a prompt (pp512 in llama-bench terms).
  final double promptTps;

  /// Tokens per second generating (tg128).
  final double generationTps;
  final int promptTokens;
  final int generatedTokens;
  final DateTime date;

  const BenchmarkResult({
    required this.model,
    required this.setup,
    required this.promptTps,
    required this.generationTps,
    required this.promptTokens,
    required this.generatedTokens,
    required this.date,
  });

  /// 'cpu' or 'gpu' for a run on this phone alone, 'cluster' otherwise.
  String get backend => switch (setup) {
        'This phone (GPU)' => 'gpu',
        'This phone (CPU)' => 'cpu',
        _ => 'cluster',
      };

  Map<String, dynamic> toMap() => {
        'model': model,
        'setup': setup,
        'promptTps': promptTps,
        'generationTps': generationTps,
        'promptTokens': promptTokens,
        'generatedTokens': generatedTokens,
        'date': date.toIso8601String(),
      };

  static BenchmarkResult? fromMap(Object? raw) {
    if (raw is! Map) return null;
    try {
      return BenchmarkResult(
        model: raw['model'] as String,
        setup: raw['setup'] as String? ?? '',
        promptTps: (raw['promptTps'] as num).toDouble(),
        generationTps: (raw['generationTps'] as num).toDouble(),
        promptTokens: (raw['promptTokens'] as num?)?.toInt() ?? 512,
        generatedTokens: (raw['generatedTokens'] as num?)?.toInt() ?? 128,
        date: DateTime.parse(raw['date'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}
