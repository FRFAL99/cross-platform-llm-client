import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/model_controller.dart';
import '../core/ui.dart';
import '../models/ai_model.dart';
import '../services/download_service.dart';
import '../services/inference_service.dart';

part 'model_view_import.dart';
part 'model_view_status.dart';
part 'model_view_cards.dart';
part 'model_view_featured.dart';
part 'model_view_widgets.dart';

const _tabular = [FontFeature.tabularFigures()];

String _prettyModel(String name) =>
    name.replaceAll(RegExp(r'\.(gguf|bin)$', caseSensitive: false), '');

/// Surface for grouped content inside a sheet (sheet bg differs from page bg).
Color _sheetSurface(AppTokens t) =>
    t.isDark ? Colors.white.withValues(alpha: 0.05) : t.surface;

class ModelView extends GetView<ModelController> {
  const ModelView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(
        context,
        title: 'Models',
        actions: [
          Obx(() {
            return _TextAction(
              icon: Icons.add_rounded,
              label: 'Import',
              color: t.accent,
              onTap: controller.isImporting.value
                  ? null
                  : () => _showImportSheet(context),
            );
          }),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await controller.refreshDownloaded();
        },
        color: t.accent,
        child: Obx(() {
          final scope = controller.modelScope.value;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              _buildScopeToggle(context),
              const SizedBox(height: 16),
              _buildActiveModelBanner(context),
              _buildActiveDownloadsBanner(context),
              if (scope == 'local') ...[
                _buildImportingProgress(context),
                ..._buildLibrary(context),
              ] else ...[
                _buildFeatured(context),
                _buildLocalFilterChips(context),
                ..._buildBrowse(context),
              ],
            ],
          );
        }),
      ),
    );
  }

  Widget _buildScopeToggle(BuildContext context) {
    return Obx(() => AppSegmented<String>(
          items: const [
            ('local', 'My models'),
            ('browse', 'Browse'),
          ],
          selected: controller.modelScope.value,
          onChanged: (value) => controller.modelScope.value = value,
        ));
  }

  Widget _buildLocalActions(BuildContext context) {
    final inference = Get.find<InferenceService>();
    return Obx(() {
      final busy =
          controller.isImporting.value || inference.isLoadingModel.value;
      return PillButton(
        label: 'Import file',
        icon: Icons.file_upload_outlined,
        onPressed: busy ? null : () => _showImportSheet(context),
      );
    });
  }

  Widget _buildLocalFilterChips(BuildContext context) {
    final labels = [
      ('general', 'Chat'),
      ('uncensored', 'Uncensored'),
      ('vision', 'Vision'),
    ];
    return Obx(() {
      final selected = controller.localFilter.value.isEmpty
          ? controller.defaultLocalFilter
          : controller.localFilter.value;
      return AppChips<String>(
        items: labels,
        selected: selected,
        onSelected: controller.setLocalFilter,
      );
    });
  }
}
