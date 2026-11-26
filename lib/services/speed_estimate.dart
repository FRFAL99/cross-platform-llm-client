/// Estimates how fast other models would run on this phone from one speed
/// test, and picks the best model that still runs at a usable speed.
///
/// Generating a token reads every active weight once, so on a phone
/// generation speed is set by memory bandwidth: tok/s × bytes read per token
/// is roughly constant for a device. One speed test of any model measures
/// that constant; dividing it by another model's bytes per token estimates
/// that model's speed. Prompt reading is compute-bound and also scales with
/// the active weights, so it is estimated the same way. Estimates, not
/// measurements: real speeds differ by quantization type (Q4_0 reads prompts
/// faster on ARM) and drop when the phone gets hot.
library;

import '../models/benchmark_result.dart';

/// Generation speed under which answers feel slow (people read about 5-8
/// tokens per second).
const double usableGenerationTps = 10;

/// Fraction of the weights a mixture-of-experts model reads per token,
/// from names like "Kimi Moonlight 16B-A3B" (3 of 16 billion). 1 for dense
/// models.
double activeWeightFraction(String name) {
  final m = RegExp(r'(\d+(?:\.\d+)?)B-A(\d+(?:\.\d+)?)B', caseSensitive: false)
      .firstMatch(name);
  if (m == null) return 1;
  final total = double.parse(m.group(1)!);
  final active = double.parse(m.group(2)!);
  if (total <= 0 || active <= 0 || active >= total) return 1;
  return active / total;
}

/// Billions of parameters from the model's name ("Qwen3 1.7B" → 1.7, total
/// for mixture-of-experts "16B-A3B" → 16), else guessed from the file size
/// at ~4.8 bits per weight (Q4_K_M). Bigger is a rough proxy for smarter.
double parameterBillions(String name, int fileBytes) {
  final m = RegExp(r'(?<![\d.])(\d+(?:\.\d+)?)B\b', caseSensitive: false)
      .firstMatch(name);
  final parsed = m == null ? null : double.tryParse(m.group(1)!);
  if (parsed != null && parsed > 0) return parsed;
  return fileBytes / 0.6e9;
}

/// Bytes of weights read to generate one token.
double bytesPerToken(int fileBytes, String name) =>
    fileBytes * activeWeightFraction(name);

/// Estimated speed of a model on this phone.
class SpeedEstimate {
  final double generationTps;
  final double promptTps;
  const SpeedEstimate(this.generationTps, this.promptTps);

  bool get usable => generationTps >= usableGenerationTps;
}

/// What one speed test says about this phone.
class DeviceSpeed {
  /// Bytes of weights read per second while generating.
  final double generationBytesPerSecond;

  /// Bytes of weights processed per second while reading a prompt.
  final double promptBytesPerSecond;

  /// The run this was measured from.
  final BenchmarkResult source;

  const DeviceSpeed._(
      this.generationBytesPerSecond, this.promptBytesPerSecond, this.source);

  /// From the newest speed test on this phone alone (not a cluster) whose
  /// model size is known: from the run itself, else from [sizeOf] (looks a
  /// model up by the name it was tested under; 0 when unknown). When the
  /// newest runs on CPU and GPU differ, the faster one counts, since Auto
  /// uses the faster processor.
  static DeviceSpeed? fromResults(
      List<BenchmarkResult> results, int Function(String model) sizeOf) {
    DeviceSpeed? best;
    final seen = <String>{};
    for (final r in results) {
      if (r.backend == 'cluster' || !seen.add(r.backend)) continue;
      final bytes = r.modelBytes > 0 ? r.modelBytes : sizeOf(r.model);
      if (bytes <= 0 || r.generationTps <= 0) continue;
      final perToken = bytesPerToken(bytes, r.model);
      final speed =
          DeviceSpeed._(r.generationTps * perToken, r.promptTps * perToken, r);
      if (best == null ||
          speed.generationBytesPerSecond > best.generationBytesPerSecond) {
        best = speed;
      }
    }
    return best;
  }

  /// Estimated speed of a model of [fileBytes] named [name].
  SpeedEstimate estimate(int fileBytes, String name) {
    final perToken = bytesPerToken(fileBytes, name);
    if (perToken <= 0) return const SpeedEstimate(0, 0);
    return SpeedEstimate(
        generationBytesPerSecond / perToken, promptBytesPerSecond / perToken);
  }
}

/// A model to choose among: its name and size (weights plus any vision
/// file, which must fit in memory too).
class ModelCandidate<T> {
  final T model;
  final String name;
  final int weightBytes;
  final int totalBytes;
  const ModelCandidate(this.model, this.name, this.weightBytes,
      {int? totalBytes})
      : totalBytes = totalBytes ?? weightBytes;
}

/// Whether a model of [bytes] fits comfortably on a phone with [totalRamGB]:
/// Android and other apps keep about half the RAM, and the context needs
/// some on top of the weights.
bool fitsInRam(int bytes, double totalRamGB) =>
    totalRamGB <= 0 || bytes <= totalRamGB * 1e9 * 0.5;

/// The best model for this phone: the one with the most parameters (a rough
/// proxy for quality; the bigger file breaks ties) that fits in RAM and
/// generates at [usableGenerationTps] or more. If none is that fast, the
/// fastest one that fits. Null if nothing fits.
ModelCandidate<T>? bestModelFor<T>(
    List<ModelCandidate<T>> candidates, DeviceSpeed speed, double totalRamGB) {
  final fitting = candidates
      .where((c) => c.weightBytes > 0 && fitsInRam(c.totalBytes, totalRamGB))
      .toList();
  if (fitting.isEmpty) return null;
  final usable = fitting
      .where((c) => speed.estimate(c.weightBytes, c.name).usable)
      .toList();
  if (usable.isNotEmpty) {
    int byQuality(ModelCandidate<T> a, ModelCandidate<T> b) {
      final p = parameterBillions(b.name, b.weightBytes)
          .compareTo(parameterBillions(a.name, a.weightBytes));
      return p != 0 ? p : b.weightBytes.compareTo(a.weightBytes);
    }

    usable.sort(byQuality);
    return usable.first;
  }
  fitting.sort((a, b) => speed
      .estimate(b.weightBytes, b.name)
      .generationTps
      .compareTo(speed.estimate(a.weightBytes, a.name).generationTps));
  return fitting.first;
}
