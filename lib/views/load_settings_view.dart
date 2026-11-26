import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/settings_controller.dart';
import '../core/ui.dart';
import '../services/device_info_native.dart' as platform_info;
import '../services/device_info_service.dart';
import '../widgets/setting_slider.dart';

const _tabular = [FontFeature.tabularFigures()];

/// How models are loaded on this phone: processor, context window, and what
/// the phone can handle. Opened from the Models tab.
class LoadSettingsView extends GetView<SettingsController> {
  const LoadSettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Load settings', showBack: true),
      body: Obx(() => ListView(
            padding: kPagePadding,
            children: [
              const SectionHeader('Processor',
                  padding: EdgeInsets.fromLTRB(4, 8, 4, 8)),
              _performanceGroup(context),
              const SectionHeader('Context window'),
              AppGroup(children: [_contextSlider()]),
              const SectionFootnote(
                  'How much text the model keeps in memory: the conversation '
                  'for the chat, the whole request for the API server.'),
              const SectionHeader('This phone'),
              AppGroup(children: [_deviceCard(context)]),
              const SectionFootnote(
                  'Changes apply the next time a model is loaded.'),
            ],
          )),
    );
  }

  String get _modeLabel => switch (controller.performanceMode.value) {
        'gpu_fast' => 'GPU',
        'cpu_safe' => 'CPU only',
        _ => 'Auto',
      };

  /// Short summary for the row that opens this page.
  static String summary(SettingsController c) {
    final mode = switch (c.performanceMode.value) {
      'gpu_fast' => 'GPU',
      'cpu_safe' => 'CPU',
      _ => 'Auto',
    };
    return '$mode · context ${c.contextSize.value}';
  }

  Widget _performanceGroup(BuildContext context) {
    const modes = [
      (
        value: 'auto_fast',
        title: 'Auto',
        subtitle: 'CPU, which is faster on most phones. Switches to the GPU '
            'when speed tests of a model show the GPU winning here',
        icon: Icons.auto_awesome_outlined
      ),
      (
        value: 'gpu_fast',
        title: 'GPU',
        subtitle: 'Always tries the GPU (Vulkan). Faster only on some '
            'phones, and some drivers crash',
        icon: Icons.bolt_rounded
      ),
      (
        value: 'cpu_safe',
        title: 'CPU only',
        subtitle: 'Never touches the GPU. Most stable',
        icon: Icons.shield_outlined
      ),
    ];
    return AppGroup(dividerIndent: 60, children: [
      for (final m in modes)
        AppRow(
          icon: m.icon,
          title: m.title,
          subtitle: m.subtitle,
          selected: controller.performanceMode.value == m.value,
          onTap: () => controller.setPerformanceMode(m.value),
        ),
    ]);
  }

  Widget _contextSlider() {
    const maxContext = 8192.0;
    final current =
        controller.contextSize.value.toDouble().clamp(512.0, maxContext);
    if (current != controller.contextSize.value.toDouble()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.setContextSize(current.toInt());
      });
    }
    return GuardedSettingSlider(
      label: 'Context size',
      value: current,
      min: 512,
      max: maxContext,
      divisions: 15,
      safeMax: Get.find<DeviceInfoService>().maxSafeContextSize.toDouble(),
      onChanged: (v) => controller.setContextSize(v.toInt()),
      displayValue: '${current.toInt()} tokens',
      warning: 'Context this large will eat all your RAM!',
    );
  }

  Widget _deviceCard(BuildContext context) {
    final t = AppTokens.of(context);
    final device = Get.find<DeviceInfoService>();
    final ram = device.totalRamGB.value.toStringAsFixed(1);
    final (String tierName, String tierHint) =
        switch (device.deviceTier.value) {
      'low' => ('Low RAM', 'Use small models only'),
      'mid' => ('Mid-range', 'Good for 1–3B models'),
      'high' => ('High-end', 'Can run 3–7B models'),
      'ultra' => ('Ultra', 'Full performance mode'),
      _ => ('', ''),
    };
    final isLow = device.deviceTier.value == 'low';
    final soc = device.socFamily.value;
    final quantWarning = soc.quantWarning;

    Widget kv(String k, String v, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Text(k, style: t.caption.copyWith(fontSize: 14)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(v,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: t.body.copyWith(
                      fontSize: 14,
                      color: color ?? t.text,
                      fontFeatures: _tabular)),
            ),
          ]),
        );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const IconBadge(Icons.smartphone_rounded),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$ram GB RAM',
                  style: t.bodyStrong.copyWith(fontFeatures: _tabular)),
              if (tierHint.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(tierHint, style: t.caption),
              ],
            ]),
          ),
          if (tierName.isNotEmpty) ...[
            const SizedBox(width: 10),
            AppTag(tierName, color: isLow ? t.orange : null),
          ],
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Container(height: 0.5, color: t.hairline),
        ),
        kv('Processor mode', _modeLabel),
        kv('CPU threads', '${device.cpuThreads.value} (performance cores)'),
        kv('Available memory',
            '${device.availableRamGB.value.toStringAsFixed(1)} GB'),
        kv('Recommended context', '${device.recommendedContextSize}'),
        kv('Recommended max tokens', '${device.recommendedMaxTokens}'),
        if (soc != platform_info.SocFamily.unknown) ...[
          kv('Chipset', soc.displayName),
          kv('Recommended quant', soc.recommendedQuant,
              color: quantWarning != null ? t.orange : null),
        ],
        if (quantWarning != null) ...[
          const SizedBox(height: 10),
          AppNotice(quantWarning,
              icon: Icons.warning_amber_rounded, color: t.orange),
        ],
      ]),
    );
  }
}
