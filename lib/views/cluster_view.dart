import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import '../core/ui.dart';
import '../services/cluster_service.dart';

/// Phone cluster: pick Master (runs the model) or Worker (lends this phone),
/// and pair them by entering the worker's IP address and pairing code.
class ClusterView extends StatefulWidget {
  const ClusterView({super.key});

  @override
  State<ClusterView> createState() => _ClusterViewState();
}

class _ClusterViewState extends State<ClusterView> {
  final ClusterService cluster = Get.find<ClusterService>();
  Timer? _wifiTimer;

  @override
  void initState() {
    super.initState();
    cluster.refreshWorkerStatus();
    cluster.refreshWifiAddress();
    cluster.ensureWorkerCode();
    if (cluster.role == ClusterRole.master) cluster.relocateWorkers();
    // Pick up Wi-Fi being turned on while this screen is open.
    _wifiTimer = Timer.periodic(
        const Duration(seconds: 3), (_) => cluster.refreshWifiAddress());
  }

  @override
  void dispose() {
    _wifiTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Phone cluster', showBack: true),
      body: Obx(() {
        final role = cluster.role;
        return ListView(
          padding: kPagePadding,
          children: [
            const SizedBox(height: 8),
            AppSegmented<ClusterRole>(
              items: [
                (ClusterRole.off, 'Off'),
                if (ClusterService.canBeMaster) (ClusterRole.master, 'Master'),
                (ClusterRole.worker, 'Worker'),
              ],
              selected: role,
              onChanged: cluster.setRole,
            ),
            const SizedBox(height: 16),
            if (role != ClusterRole.off && cluster.wifiAddress.value == null) ...[
              AppNotice(
                'Turn on Wi-Fi. All phones in the cluster must be on the same Wi-Fi network.',
                icon: Icons.wifi_off_rounded,
                color: t.orange,
              ),
              const SizedBox(height: 16),
            ],
            ...switch (role) {
              ClusterRole.off => _offSection(),
              ClusterRole.master => _masterSection(context),
              ClusterRole.worker => _workerSection(context),
            },
          ],
        );
      }),
    );
  }

  List<Widget> _offSection() => [
        AppNotice(
          ClusterService.canBeMaster
              ? 'Run models too big for one phone by sharing the work across '
                  'phones on the same Wi-Fi.\n\n'
                  'Master: the phone you chat on. It runs the model.\n'
                  'Worker: a phone that lends its memory to the master.'
              : 'Help an Android phone running OneLM run models too big for '
                  'it alone: choose Worker, then enter the address and pairing '
                  'code it shows on that phone.',
          icon: Icons.hub_outlined,
        ),
      ];

  // ── Worker ─────────────────────────────────────────────────────────────

  List<Widget> _workerSection(BuildContext context) {
    final t = AppTokens.of(context);
    final s = cluster.worker.value;
    final address = cluster.workerAddress;

    final Widget body;
    if (s.state == 'error') {
      body = _centered(context, [
        Icon(Icons.error_outline_rounded, size: 40, color: t.red),
        const SizedBox(height: 12),
        Text('Worker stopped', style: t.bodyStrong),
        const SizedBox(height: 4),
        Text(s.error ?? 'Unknown error', style: t.caption, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        PillButton(label: 'Try again', primary: true, onPressed: cluster.startWorker),
      ]);
    } else if (s.peer != null) {
      body = _centered(context, [
        _PulsingDot(color: t.green),
        const SizedBox(height: 14),
        Text('Sharing with master', style: t.bodyStrong.copyWith(fontSize: 18)),
        const SizedBox(height: 4),
        Text(s.peer!, style: t.caption),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: _Stat(label: 'Holding', value: _gb(s.heldMb))),
          Expanded(child: _Stat(label: 'Free at start', value: _gb(s.ramMb))),
          Expanded(child: _Stat(label: 'Memory speed', value: '${s.bandwidth.toStringAsFixed(1)} GB/s')),
        ]),
      ]);
    } else if (!s.running || address == null) {
      body = _centered(context, [
        const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
        const SizedBox(height: 16),
        Text(s.running ? 'Waiting for Wi-Fi…' : 'Measuring this phone…', style: t.caption),
      ]);
    } else {
      body = _centered(context, [
        Text('Enter these on the master phone', style: t.caption),
        const SizedBox(height: 8),
        SelectableText(address,
            style: t.bodyStrong.copyWith(fontSize: 26, fontFamily: 'FiraCode')),
        const SizedBox(height: 14),
        Text('Pairing code', style: t.small),
        const SizedBox(height: 4),
        Row(mainAxisSize: MainAxisSize.min, children: [
          SelectableText(cluster.workerCode.value,
              style: t.bodyStrong.copyWith(fontSize: 22, fontFamily: 'FiraCode')),
          IconButton(
            tooltip: 'Copy code',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.copy_rounded, size: 18, color: t.muted),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: cluster.workerCode.value));
              showToast('Copied', 'Pairing code copied.', tone: ToastTone.success);
            },
          ),
        ]),
        const SizedBox(height: 8),
        Row(mainAxisSize: MainAxisSize.min, children: [
          StatusDot(t.green, size: 8),
          const SizedBox(width: 6),
          Text('Ready', style: t.caption),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _Stat(label: 'Free memory', value: _gb(s.ramMb))),
          Expanded(child: _Stat(label: 'Memory speed', value: '${s.bandwidth.toStringAsFixed(1)} GB/s')),
        ]),
      ]);
    }

    return [
      if (s.throttled) ...[
        AppNotice(
          'Android is slowing this worker down (slow cores only), which slows '
          'the whole cluster. Set OneLM\'s battery use to Unrestricted, '
          'then turn Worker off and on.',
          icon: Icons.speed_rounded,
          color: t.orange,
        ),
        const SizedBox(height: 8),
        const Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            label: 'Set Unrestricted',
            primary: true,
            onPressed: LlamaCluster.requestBatteryUnrestricted,
          ),
        ),
        const SizedBox(height: 16),
      ],
      AppCard(padding: const EdgeInsets.fromLTRB(16, 24, 16, 20), child: body),
      if (!ClusterService.workerStopsWithApp && s.peer == null) ...[
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            label: 'New pairing code',
            icon: Icons.refresh_rounded,
            onPressed: () => _confirmNewCode(context),
          ),
        ),
      ],
      SectionFootnote(ClusterService.workerStopsWithApp
          ? 'Keep this device plugged in, on the same Wi-Fi, with OneLM open: '
              'iOS pauses apps in the background. Close OneLM to stop sharing.'
          : 'Keep this phone plugged in and on the same Wi-Fi, with OneLM '
              'open: the screen stays on while sharing, because Android slows '
              'background work. Set Phone cluster to Off to stop. Only a master '
              'that knows the pairing code can use this phone, and everything '
              'between the phones is encrypted.'),
    ];
  }

  Future<void> _confirmNewCode(BuildContext context) async {
    final ok = await showAppSheet<bool>(
      context,
      title: 'Make a new pairing code?',
      subtitle: 'Master phones that use the current code will need the new '
          'one. Do this if someone you don\'t trust saw the code.',
      builder: (ctx) => PrimaryButton(
        label: 'New code',
        onPressed: () => Navigator.pop(ctx, true),
      ),
    );
    if (ok == true) await cluster.newWorkerCode();
  }

  Widget _centered(BuildContext context, List<Widget> children) =>
      Column(crossAxisAlignment: CrossAxisAlignment.center, children: children);

  // ── Master ─────────────────────────────────────────────────────────────

  List<Widget> _masterSection(BuildContext context) {
    final t = AppTokens.of(context);
    return [
      if (cluster.split.length > 1) ...[
        _SplitCard(shares: cluster.split),
        const SizedBox(height: 16),
      ],
      PrimaryButton(
        label: 'Add a worker by IP',
        icon: Icons.keyboard_rounded,
        onPressed: () => _enterIp(context),
      ),
      SectionHeader('Workers (${cluster.workers.length})'),
      if (cluster.workers.isEmpty)
        const AppGroup(children: [
          EmptyState(
            icon: Icons.devices_other_rounded,
            title: 'No workers yet',
            message: 'On each other phone, open Phone cluster, choose Worker, '
                'then enter the address and pairing code it shows.',
          ),
        ])
      else
        AppGroup(dividerIndent: 60, children: [
          for (final w in cluster.workers)
            AppRow(
              icon: Icons.smartphone_rounded,
              title: w.model ?? w.name,
              subtitle: [
                w.endpoint,
                if (!cluster.hasCode(w)) 'needs its pairing code',
                if (w.ramMb != null) '${_gb(w.ramMb!)} free',
                if (w.bandwidth != null) '${w.bandwidth!.toStringAsFixed(1)} GB/s',
              ].join(' · '),
              onTap: () => _enterCode(context, w),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (!cluster.hasCode(w)) AppTag('Code', color: t.orange),
                IconButton(
                  icon: Icon(Icons.close_rounded, color: t.muted),
                  tooltip: 'Remove',
                  onPressed: () => cluster.remove(w),
                ),
              ]),
            ),
        ]),
      const SectionFootnote(
        'Used the next time you load a GGUF model. If the model fits on this '
        'phone you can keep it here, which is faster. If it doesn\'t, the '
        'fastest phones get the biggest share and phones that aren\'t needed '
        'are left out.',
      ),
      const SectionHeader('Other ways to add'),
      Row(children: [
        PillButton(
          label: cluster.isScanning.value ? 'Searching…' : 'Find nearby',
          icon: Icons.wifi_find_rounded,
          onPressed: cluster.isScanning.value ? null : cluster.scanNearby,
        ),
      ]),
      if (cluster.found.isNotEmpty) ...[
        const SizedBox(height: 12),
        AppGroup(dividerIndent: 60, children: [
          for (final w in cluster.found)
            AppRow(
              icon: Icons.smartphone_rounded,
              title: w.model ?? w.name,
              subtitle: w.endpoint,
              trailing: PillButton(
                label: 'Add',
                primary: true,
                onPressed: () => _addFound(context, w),
              ),
            ),
        ]),
      ],
    ];
  }

  Future<void> _enterIp(BuildContext context) async {
    final ip = TextEditingController();
    final code = TextEditingController();
    final ok = await showAppSheet<bool>(
      context,
      title: 'Add a worker',
      subtitle: 'Both are shown on the worker phone',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: ip,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: appInputDecoration(ctx,
                hint: '192.168.1.20:${LlamaCluster.defaultPort}'),
          ),
          const SizedBox(height: 10),
          _codeField(ctx, code, onSubmitted: () => Navigator.pop(ctx, true)),
          const SizedBox(height: 16),
          PrimaryButton(label: 'Add', onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    final ipText = ip.text, codeText = code.text;
    ip.dispose();
    code.dispose();
    if (ok == true) await _report(cluster.addManual(ipText, codeText));
  }

  /// Asks for a worker's pairing code: to add a found worker, or for one
  /// added before pairing codes existed (or whose code changed).
  Future<String?> _askCode(BuildContext context, ClusterWorker w) async {
    final code = TextEditingController();
    final ok = await showAppSheet<bool>(
      context,
      title: 'Pairing code for ${w.model ?? w.name}',
      subtitle: 'Shown under the address on the worker phone',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _codeField(ctx, code, autofocus: true, onSubmitted: () => Navigator.pop(ctx, true)),
          const SizedBox(height: 16),
          PrimaryButton(label: 'Pair', onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    final text = code.text;
    code.dispose();
    return ok == true ? text : null;
  }

  Future<void> _addFound(BuildContext context, ClusterWorker w) async {
    final code = await _askCode(context, w);
    if (code != null) await _report(cluster.addFound(w, code));
  }

  Future<void> _enterCode(BuildContext context, ClusterWorker w) async {
    final code = await _askCode(context, w);
    if (code != null) await _report(cluster.setCode(w, code));
  }

  Widget _codeField(BuildContext ctx, TextEditingController ctrl,
          {bool autofocus = false, required VoidCallback onSubmitted}) =>
      TextField(
        controller: ctrl,
        autofocus: autofocus,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.characters,
        style: AppTokens.of(ctx).mono,
        decoration: appInputDecoration(ctx, hint: 'Pairing code, e.g. ABCD-EFGH-JK23'),
        onSubmitted: (_) => onSubmitted(),
      );

  Future<void> _report(Future<String?> adding) async {
    final error = await adding;
    if (error != null) {
      showToast('Couldn\'t add worker', error, tone: ToastTone.error);
    } else {
      showToast('Worker added', 'Used the next time you load a GGUF model.',
          tone: ToastTone.success);
    }
  }
}

String _gb(num mb) => '${(mb / 1024).toStringAsFixed(1)} GB';

/// How the loaded model is spread across phones: a stacked bar and legend.
class _SplitCard extends StatelessWidget {
  final List<ClusterShare> shares;
  const _SplitCard({required this.shares});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final colors = [t.accent, t.green, t.orange, const Color(0xFFAF52DE), t.red];
    final total = shares.fold<double>(0, (a, s) => a + s.mb);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Loaded model', style: t.bodyStrong),
        const SizedBox(height: 2),
        Text('Running on ${shares.length} phones · ${_gb(total)}', style: t.caption),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 12,
            child: Row(children: [
              for (var i = 0; i < shares.length; i++)
                Expanded(
                  flex: (shares[i].mb / total * 1000).round().clamp(1, 1000),
                  child: Container(
                    margin: EdgeInsets.only(right: i == shares.length - 1 ? 0 : 2),
                    color: colors[i % colors.length],
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        for (var i = 0; i < shares.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              StatusDot(colors[i % colors.length], size: 10),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  shares[i].isThisPhone ? '${shares[i].name} (this phone)' : shares[i].name,
                  style: t.body,
                ),
              ),
              Text('${(shares[i].mb / total * 100).round()}%', style: t.bodyStrong),
              const SizedBox(width: 10),
              SizedBox(
                width: 58,
                child: Text(_gb(shares[i].mb), textAlign: TextAlign.right, style: t.caption),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      Text(value, style: t.bodyStrong),
      const SizedBox(height: 2),
      Text(label, style: t.small, textAlign: TextAlign.center),
    ]);
  }
}

/// Live indicator for an active connection.
class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 56,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Stack(alignment: Alignment.center, children: [
          Container(
            width: 24 + 32 * _c.value,
            height: 24 + 32 * _c.value,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withValues(alpha: 0.35 * (1 - _c.value)),
            ),
          ),
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
            child: const Icon(Icons.hub_rounded, size: 14, color: Colors.white),
          ),
        ]),
      ),
    );
  }
}
