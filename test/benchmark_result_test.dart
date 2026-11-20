import 'package:flutter_test/flutter_test.dart';
import 'package:onelm/models/benchmark_result.dart';

void main() {
  test('benchmark results round-trip through their stored map', () {
    final r = BenchmarkResult(
      model: 'qwen.gguf',
      setup: 'This phone (CPU)',
      promptTps: 85.4,
      generationTps: 12.3,
      promptTokens: 512,
      generatedTokens: 128,
      date: DateTime(2026, 11, 20, 11, 30),
    );
    final back = BenchmarkResult.fromMap(r.toMap())!;
    expect(back.model, r.model);
    expect(back.setup, r.setup);
    expect(back.promptTps, r.promptTps);
    expect(back.generationTps, r.generationTps);
    expect(back.date, r.date);
    expect(BenchmarkResult.fromMap({'model': 'x'}), isNull);
    expect(BenchmarkResult.fromMap('junk'), isNull);
  });
}
