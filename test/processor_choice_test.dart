import 'package:flutter_test/flutter_test.dart';
import 'package:onelm/models/benchmark_result.dart';
import 'package:onelm/services/processor_choice.dart';

BenchmarkResult run(String model, String setup, double pp, double tg) =>
    BenchmarkResult(
      model: model,
      setup: setup,
      promptTps: pp,
      generationTps: tg,
      promptTokens: 512,
      generatedTokens: 128,
      date: DateTime(2026, 11, 26),
    );

void main() {
  const model = 'lfm2.5-1.2b-instruct-q4_k_m.gguf';

  test('Auto uses the CPU until both processors were tested', () {
    expect(autoUsesGpu(const [], model), isFalse);
    expect(
        autoUsesGpu([run(model, 'This phone (GPU)', 400, 40)], model), isFalse);
  });

  test('Auto keeps the CPU when the GPU is slower', () {
    final results = [
      run(model, 'This phone (CPU)', 80, 22),
      run(model, 'This phone (GPU)', 3.5, 8.3),
    ];
    expect(autoUsesGpu(results, model), isFalse);
  });

  test('Auto picks the GPU when it generates faster, per model', () {
    final results = [
      run(model, 'This phone (GPU)', 300, 30),
      run(model, 'This phone (CPU)', 80, 22),
    ];
    expect(autoUsesGpu(results, model), isTrue);
    expect(autoUsesGpu(results, 'other.gguf'), isFalse);
  });

  test('cluster runs do not count', () {
    final results = [
      run(model, 'Pixel 8 72% · POCO F1 28%', 300, 30),
      run(model, 'This phone (CPU)', 80, 22),
    ];
    expect(autoUsesGpu(results, model), isFalse);
  });
}
