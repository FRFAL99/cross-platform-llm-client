/// How many CPU threads llama.cpp should use on this phone.
///
/// Phone CPUs mix fast and slow cores (big.LITTLE). llama.cpp splits each
/// matrix multiplication evenly-ish across its threads and waits for the
/// slowest one, so putting threads on the efficiency cores (Cortex-A53/A55/
/// A510/A520) usually makes both prompt reading and generation *slower*
/// than leaving them out. The best default is one thread per performance
/// core.
library;

/// ARM "CPU part" ids (from /proc/cpuinfo) of in-order efficiency cores.
const _efficiencyParts = {
  0xd03, // Cortex-A53
  0xd04, // Cortex-A35
  0xd05, // Cortex-A55
  0xd46, // Cortex-A510
  0xd80, // Cortex-A520
};

/// One CPU core as seen by the kernel.
class CpuCore {
  /// ARM part number (`CPU part` in /proc/cpuinfo), or null if unknown.
  final int? part;

  /// Maximum frequency in kHz (`cpuinfo_max_freq`), or null if unknown.
  final int? maxFreqKhz;

  const CpuCore({this.part, this.maxFreqKhz});
}

/// Thread count for llama.cpp on the CPU: the number of performance cores,
/// between 1 and 8. Falls back to 4 when nothing is known about the cores.
int recommendedCpuThreads(List<CpuCore> cores) {
  if (cores.isEmpty) return 4;
  int clamp(int n) => n.clamp(1, 8);

  // Best signal: the core design. Efficiency cores are in-order designs with
  // well-known part numbers; everything else (A7x, X-series, Oryon...) is a
  // performance core.
  if (cores.every((c) => c.part != null)) {
    final fast = cores.where((c) => !_efficiencyParts.contains(c.part)).length;
    if (fast > 0) return clamp(fast);
    // Only efficiency cores (budget phones): they usually come as two
    // clusters of four, and one cluster's worth of threads is fastest.
    return clamp(cores.length >= 8 ? 4 : cores.length);
  }

  // Otherwise, frequencies: drop the slowest cluster when it is clearly
  // slower than the fastest core.
  final freqs = [
    for (final c in cores)
      if (c.maxFreqKhz != null && c.maxFreqKhz! > 0) c.maxFreqKhz!
  ];
  if (freqs.length != cores.length) {
    return clamp(cores.length >= 8 ? 4 : cores.length);
  }
  final top = freqs.reduce((a, b) => a > b ? a : b);
  final low = freqs.reduce((a, b) => a < b ? a : b);
  if (low >= top * 0.85) return clamp(cores.length);
  return clamp(freqs.where((f) => f > low).length);
}

/// Parses /proc/cpuinfo into one [CpuCore] per `processor` entry, taking the
/// maximum frequency of core `i` from [maxFreqKhz] (index = core number).
List<CpuCore> parseCpuCores(String cpuinfo, Map<int, int> maxFreqKhz) {
  final cores = <CpuCore>[];
  int? index;
  int? part;
  void flush() {
    if (index != null) {
      cores.add(CpuCore(part: part, maxFreqKhz: maxFreqKhz[index]));
    }
    index = null;
    part = null;
  }

  for (final line in cpuinfo.split('\n')) {
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final key = line.substring(0, colon).trim().toLowerCase();
    final value = line.substring(colon + 1).trim();
    if (key == 'processor') {
      flush();
      index = int.tryParse(value);
    } else if (key == 'cpu part') {
      part = int.tryParse(value.replaceFirst(RegExp('^0x'), ''), radix: 16);
    }
  }
  flush();
  // No per-core entries (some kernels): fall back to the frequency list.
  if (cores.isEmpty) {
    final ids = maxFreqKhz.keys.toList()..sort();
    return [for (final i in ids) CpuCore(maxFreqKhz: maxFreqKhz[i])];
  }
  return cores;
}
