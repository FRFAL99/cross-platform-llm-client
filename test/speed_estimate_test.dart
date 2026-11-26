import 'package:flutter_test/flutter_test.dart';
import 'package:onelm/models/benchmark_result.dart';
import 'package:onelm/services/speed_estimate.dart';

BenchmarkResult run(String setup, double pp, double tg, {int bytes = 0}) =>
    BenchmarkResult(
      model: 'LFM2.5 1.2B Instruct (Q4_K_M)',
      setup: setup,
      promptTps: pp,
      generationTps: tg,
      promptTokens: 512,
      generatedTokens: 128,
      date: DateTime(2026, 11, 26),
      modelBytes: bytes,
    );

void main() {
  test('reads mixture-of-experts and parameter counts from names', () {
    expect(activeWeightFraction('Kimi Moonlight 16B-A3B (Q3_K_S)'),
        closeTo(3 / 16, 1e-9));
    expect(activeWeightFraction('Qwen3 1.7B'), 1);
    expect(parameterBillions('Llama-3.2-1B Instruct (Q4_K_M)', 0), 1);
    expect(parameterBillions('Qwen2.5-3B Instruct (Q4_K_M)', 0), 3);
    expect(parameterBillions('Gemma 4 26B-A4B Instruct', 0), 26);
    expect(parameterBillions('Phi-3.5 Mini Instruct (Q4_K_M)', 2.4e9 ~/ 1),
        closeTo(4, 1e-9));
  });

  test('estimates other models from one speed test', () {
    // Francesco's Motorola on the CPU: 13.5 tok/s with a 731 MB model.
    final speed = DeviceSpeed.fromResults(
        [run('This phone (CPU)', 98.3, 13.5, bytes: 731000000)], (_) => 0)!;
    final twice = speed.estimate(1462000000, 'Qwen3 1.7B');
    expect(twice.generationTps, closeTo(6.75, 1e-6));
    expect(twice.promptTps, closeTo(49.15, 1e-6));
    // A 16B-A3B MoE reads only 3/16 of its 7.1 GB per token.
    final moe = speed.estimate(7100000000, 'Kimi 16B-A3B');
    expect(moe.generationTps, closeTo(13.5 * 731 / (7100 * 3 / 16), 1e-6));
  });

  test('uses the faster processor and ignores clusters and unknown sizes', () {
    final results = [
      run('Pixel 8 72% · POCO F1 28%', 200, 40, bytes: 731000000),
      run('This phone (GPU)', 3.5, 8.3, bytes: 731000000),
      run('This phone (CPU)', 98.3, 13.5),
    ];
    expect(DeviceSpeed.fromResults(results, (_) => 0)!.source.setup,
        'This phone (GPU)');
    expect(DeviceSpeed.fromResults(results, (_) => 731000000)!.source.setup,
        'This phone (CPU)');
    expect(DeviceSpeed.fromResults(const [], (_) => 0), isNull);
  });

  test('picks the biggest model that is still fast enough and fits', () {
    final speed = DeviceSpeed.fromResults(
        [run('This phone (CPU)', 98.3, 13.5, bytes: 731000000)], (_) => 0)!;
    const models = [
      ModelCandidate('lfm', 'LFM2.5 1.2B Instruct', 731000000),
      ModelCandidate('llama', 'Llama-3.2-1B Instruct', 800000000),
      ModelCandidate('qwen3b', 'Qwen2.5-3B Instruct', 2100000000),
      ModelCandidate('gemma26', 'Gemma 4 26B-A4B', 10000000000),
    ];
    // 3B runs at ~4.7 tok/s: too slow. 26B doesn't fit in 8 GB.
    expect(bestModelFor(models, speed, 8)!.model, 'lfm');
    // Nothing fast enough: the fastest that fits.
    final slow = DeviceSpeed.fromResults(
        [run('This phone (CPU)', 20, 2, bytes: 731000000)], (_) => 0)!;
    expect(bestModelFor(models, slow, 8)!.model, 'lfm');
    expect(bestModelFor(models, speed, 1), isNull);
  });
}
