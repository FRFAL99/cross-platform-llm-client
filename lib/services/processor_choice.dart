import '../models/benchmark_result.dart';

/// Whether the "Auto" processor mode should run [modelName] on the GPU.
///
/// llama.cpp's Vulkan backend is slower than the CPU on most phones,
/// especially at reading the prompt (Mali and Adreno drivers lack the fast
/// matrix paths desktop GPUs have), so Auto uses the CPU. It switches to the
/// GPU only when speed tests of this model on this phone show the GPU
/// generating faster than the CPU.
bool autoUsesGpu(List<BenchmarkResult> results, String modelName) {
  BenchmarkResult? latest(String backend) {
    for (final r in results) {
      // Newest first.
      if (r.model == modelName && r.backend == backend) return r;
    }
    return null;
  }

  final gpu = latest('gpu');
  final cpu = latest('cpu');
  if (gpu == null || cpu == null) return false;
  return gpu.generationTps > cpu.generationTps * 1.05 &&
      gpu.promptTps >= cpu.promptTps * 0.5;
}
