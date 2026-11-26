import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../core/ui.dart';
import '../models/benchmark_result.dart';
import '../services/cluster_service.dart';
import '../services/inference_service.dart';

/// On-device speed test of the loaded model, on this phone or the cluster.
class BenchmarkView extends StatefulWidget {
  const BenchmarkView({super.key});

  @override
  State<BenchmarkView> createState() => _BenchmarkViewState();
}

class _BenchmarkViewState extends State<BenchmarkView> {
  final InferenceService inference = Get.find<InferenceService>();
  late List<BenchmarkResult> _history = inference.benchmarkResults;
  BenchmarkResult? _last;

  Future<void> _run() async {
    try {
      final result = await inference.runBenchmark();
      if (!mounted) return;
      setState(() {
        _last = result;
        _history = inference.benchmarkResults;
      });
      if (result == null) {
        showToast('Speed test stopped', 'No result was saved.');
      }
    } catch (e) {
      showToast('Speed test', '$e'.replaceFirst('Exception: ', ''),
          tone: ToastTone.error);
    }
  }

  Future<void> _clear() async {
    await inference.clearBenchmarkResults();
    if (mounted) setState(() => _history = const []);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Speed test', showBack: true),
      body: Obx(() {
        final loaded = inference.isModelLoaded.value;
        final running = inference.isBenchmarking.value;
        final cluster = Get.isRegistered<ClusterService>()
            ? Get.find<ClusterService>()
            : null;
        final split = cluster?.splitSummary;
        return ListView(
          padding: kPagePadding,
          children: [
            const SizedBox(height: 8),
            AppCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        loaded
                            ? inference.loadedModelName.value
                            : 'No model loaded',
                        style: t.bodyStrong),
                    const SizedBox(height: 2),
                    Text(
                      !loaded
                          ? 'Load a model in Models, then come back.'
                          : split != null
                              ? 'Phone cluster: $split'
                              : 'This phone · ${inference.isGpuAccelerated.value ? 'GPU' : 'CPU'}',
                      style: t.caption,
                    ),
                    const SizedBox(height: 16),
                    if (running)
                      Row(children: [
                        const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Text('Measuring… keep the app open',
                                style: t.caption)),
                        PillButton(
                            label: 'Stop', onPressed: inference.stopGeneration),
                      ])
                    else
                      PrimaryButton(
                        label: 'Run speed test',
                        icon: Icons.speed_rounded,
                        onPressed: loaded ? _run : null,
                      ),
                    if (_last != null && !running) ...[
                      const SizedBox(height: 16),
                      Row(children: [
                        Expanded(
                            child: _Big(
                                value: _last!.generationTps,
                                label: 'Generation · tok/s')),
                        Expanded(
                            child: _Big(
                                value: _last!.promptTps,
                                label: 'Prompt reading · tok/s')),
                      ]),
                    ],
                  ]),
            ),
            const SectionFootnote(
              'Reads a 512-token prompt, then writes 128 tokens, like llama-bench '
              '(pp512, tg128). Generation speed is how fast answers appear; '
              'prompt reading is how long it takes before they start. Takes '
              'from a few seconds to a few minutes; chat and API requests wait '
              'meanwhile. The chat\'s cached context is cleared.',
            ),
            if (split == null)
              const SectionFootnote(
                'CPU or GPU? On most phones the CPU is faster. To compare, run '
                'the test, switch Processor mode to GPU in Models › Load '
                'settings, reload the model and run it again: Auto then uses '
                'whichever was faster for that model.',
              ),
            if (_history.isNotEmpty) ...[
              Row(children: [
                const Expanded(child: SectionHeader('History')),
                TextButton(onPressed: _clear, child: const Text('Clear')),
              ]),
              AppGroup(children: [
                for (final r in _history)
                  AppRow(
                    title: r.model.replaceAll(RegExp(r'\.gguf$'), ''),
                    subtitle: '${r.setup} · ${_date(r.date)}',
                    trailing: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('${r.generationTps.toStringAsFixed(1)} tok/s',
                            style: t.bodyStrong),
                        Text('prompt ${r.promptTps.toStringAsFixed(0)}',
                            style: t.small),
                      ],
                    ),
                  ),
              ]),
            ],
          ],
        );
      }),
    );
  }

  static String _date(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}

class _Big extends StatelessWidget {
  final double value;
  final String label;
  const _Big({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value.toStringAsFixed(value >= 100 ? 0 : 1),
          style: t.title.copyWith(fontSize: 28, letterSpacing: -0.5)),
      Text(label, style: t.small),
    ]);
  }
}
