import 'package:flutter_test/flutter_test.dart';
import 'package:onelm/services/cpu_threads.dart';

String cpuinfo(List<String> parts) => [
      for (var i = 0; i < parts.length; i++)
        'processor\t: $i\nBogoMIPS\t: 38.40\nCPU implementer\t: 0x41\n'
            'CPU part\t: ${parts[i]}\n'
    ].join('\n');

void main() {
  test('counts the performance cores of a 4 + 4 phone', () {
    // Dimensity 7300: 4x Cortex-A78 + 4x Cortex-A55.
    final cores = parseCpuCores(
        cpuinfo([...List.filled(4, '0xd05'), ...List.filled(4, '0xd41')]),
        const {});
    expect(recommendedCpuThreads(cores), 4);
  });

  test('counts prime and big cores of a 1 + 3 + 4 phone', () {
    // Snapdragon 7 Gen 3: 1x A715 + 3x A715 + 4x A510.
    final cores = parseCpuCores(
        cpuinfo([...List.filled(4, '0xd46'), ...List.filled(4, '0xd4d')]),
        const {});
    expect(recommendedCpuThreads(cores), 4);
  });

  test('uses every core when none is an efficiency core', () {
    // Snapdragon 8 Elite: Oryon cores only (Qualcomm part numbers).
    final cores = parseCpuCores(cpuinfo(List.filled(8, '0x001')), const {});
    expect(recommendedCpuThreads(cores), 8);
  });

  test('uses one cluster on a phone with efficiency cores only', () {
    final cores = parseCpuCores(cpuinfo(List.filled(8, '0xd05')), const {});
    expect(recommendedCpuThreads(cores), 4);
  });

  test('falls back to frequencies without part numbers', () {
    final cores = parseCpuCores('', {
      for (var i = 0; i < 6; i++) i: 2000000,
      6: 2800000,
      7: 3200000,
    });
    expect(recommendedCpuThreads(cores), 2);
    final even = parseCpuCores('', {for (var i = 0; i < 8; i++) i: 2400000});
    expect(recommendedCpuThreads(even), 8);
  });

  test('defaults to 4 threads when nothing is known', () {
    expect(recommendedCpuThreads(const []), 4);
  });
}
