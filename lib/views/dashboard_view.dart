import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/home_controller.dart';
import '../controllers/model_controller.dart';
import '../controllers/server_controller.dart';
import '../core/haptics.dart';
import '../core/ui.dart';
import '../services/cluster_service.dart';
import '../services/inference_service.dart';
import 'benchmark_view.dart';
import 'settings_view.dart';

const _tabular = [FontFeature.tabularFigures()];

String _pretty(String name) =>
    name.replaceAll(RegExp(r'\.(gguf|bin)$', caseSensitive: false), '');

/// Home tab: the state of everything the app does, with the one action each
/// part needs next. Model → server → cluster → speed, top to bottom.
class DashboardView extends GetView<HomeController> {
  const DashboardView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(
        context,
        title: 'OneLM',
        actions: [
          AppBarIcon(
            icon: Icons.settings_outlined,
            tooltip: 'Settings',
            onPressed: () => Get.to(() => const SettingsView()),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const _ModelCard(),
          const SizedBox(height: 12),
          const _ServerCard(),
          if (Get.isRegistered<ClusterService>()) ...[
            const SizedBox(height: 12),
            const _ClusterCard(),
          ],
          const SizedBox(height: 12),
          const _SpeedCard(),
        ],
      ),
    );
  }
}

/// Card with a small label, a status line and a row of actions.
class _StatusCard extends StatelessWidget {
  final String label;
  final Color dot;
  final String title;
  final String? meta;
  final Widget? extra;
  final List<Widget> actions;
  final VoidCallback? onTap;

  const _StatusCard({
    required this.label,
    required this.dot,
    required this.title,
    this.meta,
    this.extra,
    this.actions = const [],
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return AppCard(
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: t.label),
        const SizedBox(height: 8),
        Row(children: [
          StatusDot(dot, size: 8),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.bodyStrong.copyWith(fontSize: 16.5)),
          ),
        ]),
        if (meta != null && meta!.isNotEmpty) ...[
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Text(meta!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.caption.copyWith(fontFeatures: _tabular)),
          ),
        ],
        if (extra != null) ...[const SizedBox(height: 12), extra!],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      ]),
    );
  }
}

// ── Model ────────────────────────────────────────────────────────────────

class _ModelCard extends StatelessWidget {
  const _ModelCard();

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final t = AppTokens.of(context);
      final home = Get.find<HomeController>();
      final models = Get.find<ModelController>();
      final inf = Get.find<InferenceService>();
      final cluster = Get.isRegistered<ClusterService>()
          ? Get.find<ClusterService>()
          : null;
      void openModels() => home.changeTab(AppTab.models);

      if (inf.isLoadingModel.value) {
        final name = inf.loadedModelName.value.isNotEmpty
            ? inf.loadedModelName.value
            : models.lastLoadedModelName;
        return _StatusCard(
          label: 'Model',
          dot: t.orange,
          title: name.isEmpty ? 'Loading model…' : _pretty(name),
          meta: 'Loading · ${(inf.modelLoadProgress.value * 100).round()}%',
          extra: AppProgressBar(value: inf.modelLoadProgress.value),
          onTap: openModels,
        );
      }

      if (inf.isModelLoaded.value) {
        final where = cluster?.splitSummary ??
            (inf.isGpuAccelerated.value ? 'GPU' : 'CPU');
        final ctx = inf.contextTokensTotal.value;
        return _StatusCard(
          label: 'Model',
          dot: t.green,
          title: _pretty(inf.loadedModelName.value),
          meta: [
            'Ready',
            where,
            if (ctx > 0) 'context $ctx',
          ].join(' · '),
          onTap: openModels,
          actions: [
            PillButton(
              label: 'Try in chat',
              icon: Icons.chat_bubble_outline_rounded,
              primary: true,
              onPressed: () {
                Haptics.selectionClick();
                home.openChat();
              },
            ),
            PillButton(label: 'Switch', onPressed: openModels),
            PillButton(
              label: 'Unload',
              onPressed:
                  models.isImporting.value ? null : () => models.unloadModel(),
            ),
          ],
        );
      }

      if (models.downloadedCount == 0) {
        return _StatusCard(
          label: 'Model',
          dot: t.orange,
          title: 'No model on this phone',
          meta: 'Download a GGUF model from the catalogue or import one.',
          onTap: openModels,
          actions: [
            PillButton(
              label: 'Browse models',
              icon: Icons.download_rounded,
              primary: true,
              onPressed: () {
                models.modelScope.value = 'browse';
                openModels();
              },
            ),
          ],
        );
      }

      final last = models.canLoadLastModel ? models.lastLoadedModelName : '';
      return _StatusCard(
        label: 'Model',
        dot: t.faint,
        title: last.isEmpty ? 'No model loaded' : _pretty(last),
        meta: last.isEmpty
            ? '${models.downloadedCount} on this phone'
            : 'Not loaded · last used',
        onTap: openModels,
        actions: [
          if (last.isNotEmpty)
            PillButton(
              label: 'Load',
              icon: Icons.play_arrow_rounded,
              primary: true,
              onPressed: () {
                Haptics.lightImpact();
                models.loadModel(last);
              },
            ),
          PillButton(
            label: last.isEmpty ? 'Choose a model' : 'Choose another',
            primary: last.isEmpty,
            onPressed: () {
              models.modelScope.value = 'local';
              openModels();
            },
          ),
        ],
      );
    });
  }
}

// ── Server ───────────────────────────────────────────────────────────────

class _ServerCard extends StatelessWidget {
  const _ServerCard();

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final t = AppTokens.of(context);
      final server = Get.find<ServerController>();
      final home = Get.find<HomeController>();
      final running = server.isRunning.value;
      final starting = server.isStarting.value;
      final network = server.allowNetwork.value;
      final hasModel = server.hasLocalModel;
      void openServer() => home.changeTab(AppTab.server);

      final String title;
      final String meta;
      final Color dot;
      if (running) {
        dot = t.green;
        title = network ? 'Running · local network' : 'Running · this phone';
        meta = network
            ? 'Other devices on the Wi-Fi connect with the API key.'
            : 'Only apps on this phone can connect.';
      } else if (starting) {
        dot = t.orange;
        title = 'Starting…';
        meta = '';
      } else {
        dot = t.faint;
        title = 'Stopped';
        meta = hasModel
            ? 'Expose the loaded model as an OpenAI-compatible API.'
            : 'Load a model first, then start the server.';
      }

      return _StatusCard(
        label: 'API server',
        dot: dot,
        title: title,
        meta: meta,
        onTap: openServer,
        extra: running
            ? _CopyField(
                text: server.openAiBaseUrl,
                onCopy: () => server.copyText(server.openAiBaseUrl, 'Base URL'),
              )
            : null,
        actions: [
          if (running)
            PillButton(
              label: 'Stop',
              destructive: true,
              onPressed: () {
                Haptics.mediumImpact();
                server.stopServer();
              },
            )
          else
            PillButton(
              label: starting ? 'Starting…' : 'Start',
              icon: Icons.play_arrow_rounded,
              primary: hasModel,
              onPressed: starting || !hasModel
                  ? null
                  : () {
                      Haptics.mediumImpact();
                      server.startServer();
                    },
            ),
          PillButton(label: 'Details', onPressed: openServer),
        ],
      );
    });
  }
}

class _CopyField extends StatelessWidget {
  final String text;
  final VoidCallback onCopy;
  const _CopyField({required this.text, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Material(
      color: t.fill,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          Haptics.lightImpact();
          onCopy();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
          child: Row(children: [
            Expanded(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.mono.copyWith(fontSize: 13)),
            ),
            const SizedBox(width: 8),
            Icon(Icons.copy_rounded, size: 16, color: t.muted),
          ]),
        ),
      ),
    );
  }
}

// ── Cluster ──────────────────────────────────────────────────────────────

class _ClusterCard extends StatelessWidget {
  const _ClusterCard();

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final t = AppTokens.of(context);
      final cluster = Get.find<ClusterService>();
      final home = Get.find<HomeController>();
      void openCluster() => home.changeTab(AppTab.cluster);

      final String title;
      final String meta;
      final Color dot;
      switch (cluster.role) {
        case ClusterRole.master:
          final n = cluster.workers.length;
          dot = n > 0 ? t.green : t.orange;
          title = 'Master · $n ${n == 1 ? 'worker' : 'workers'}';
          meta = cluster.splitSummary ??
              (n > 0
                  ? 'The next model you load is spread across the phones.'
                  : 'Add a worker phone to run bigger models.');
        case ClusterRole.worker:
          final running = cluster.worker.value.running;
          dot = running ? t.green : t.orange;
          title = running ? 'Worker · sharing this phone' : 'Worker · starting';
          meta = 'A master phone uses this phone\'s memory.';
        case ClusterRole.off:
          dot = t.faint;
          title = 'Off';
          meta = 'Spread a model across phones on the same Wi-Fi.';
      }
      return _StatusCard(
        label: 'Phone cluster',
        dot: dot,
        title: title,
        meta: meta,
        onTap: openCluster,
        actions: [
          PillButton(
            label: cluster.role == ClusterRole.off ? 'Set up' : 'Manage',
            onPressed: openCluster,
          ),
        ],
      );
    });
  }
}

// ── Speed ────────────────────────────────────────────────────────────────

class _SpeedCard extends StatelessWidget {
  const _SpeedCard();

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final t = AppTokens.of(context);
      final inf = Get.find<InferenceService>();
      // Read so the card refreshes when a test ends.
      final running = inf.isBenchmarking.value;
      final loaded = inf.isModelLoaded.value;
      final results = inf.benchmarkResults;
      final last = results.isEmpty ? null : results.first;
      void open() => Get.to(() => const BenchmarkView());

      return _StatusCard(
        label: 'Speed',
        dot: running
            ? t.orange
            : last != null
                ? t.accent
                : t.faint,
        title: running
            ? 'Measuring…'
            : last != null
                ? '${last.generationTps.toStringAsFixed(1)} tok/s'
                : 'Not measured yet',
        meta: last != null
            ? '${_pretty(last.model)} · ${last.setup}'
            : 'Measure how fast the loaded model reads and writes.',
        onTap: open,
        actions: [
          PillButton(
            label: last == null ? 'Run speed test' : 'Speed test',
            icon: Icons.timer_outlined,
            onPressed: loaded || last != null ? open : null,
          ),
        ],
      );
    });
  }
}
