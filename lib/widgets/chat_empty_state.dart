import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/home_controller.dart';
import '../controllers/model_controller.dart';
import '../core/haptics.dart';
import '../core/ui.dart';
import '../services/cluster_service.dart';
import '../services/inference_service.dart';

String _pretty(String name) =>
    name.replaceAll(RegExp(r'\.(gguf|bin)$', caseSensitive: false), '');

/// Shown in the chat before the first message: which model will answer and,
/// when none is ready, the one action that fixes it. The chat is a test
/// bench for the model, so no greetings or prompt suggestions.
class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final t = AppTokens.of(context);
      final inf = Get.find<InferenceService>();
      final models = Get.find<ModelController>();
      final cluster = Get.isRegistered<ClusterService>()
          ? Get.find<ClusterService>()
          : null;

      final String title;
      final String message;
      Widget? action;
      if (inf.isLoadingModel.value) {
        title = 'Loading model…';
        message = '${(inf.modelLoadProgress.value * 100).round()}%';
      } else if (inf.isModelLoaded.value) {
        title = _pretty(inf.loadedModelName.value);
        final where = cluster?.splitSummary ??
            (inf.isGpuAccelerated.value ? 'GPU' : 'CPU');
        message = '$where\n\nSend a message to try the model.';
      } else {
        final last = models.canLoadLastModel ? models.lastLoadedModelName : '';
        title = 'No model loaded';
        message = last.isEmpty
            ? 'Load a model to try it here.'
            : 'Last used: ${_pretty(last)}';
        action = Wrap(spacing: 8, children: [
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
            label: 'Models',
            primary: last.isEmpty,
            onPressed: () => Get.find<HomeController>().openTab(AppTab.models),
          ),
        ]);
      }

      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Image.asset('assets/icons/appicon.png', width: 40, height: 40),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.title),
            const SizedBox(height: 6),
            Text(message, textAlign: TextAlign.center, style: t.caption),
            if (action != null) ...[const SizedBox(height: 18), action],
          ]),
        ),
      );
    });
  }
}
