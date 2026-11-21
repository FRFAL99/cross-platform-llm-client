import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/home_controller.dart';
import '../core/haptics.dart';
import '../core/ui.dart';
import '../services/cluster_service.dart';
import 'cluster_view.dart';
import 'dashboard_view.dart';
import 'model_view.dart';
import 'server_view.dart';

/// Main screen: the four things the app does, one tab each. Home shows the
/// state of all of them; the chat and settings open on their own pages.
class HomeView extends GetView<HomeController> {
  const HomeView({super.key});

  static const _tabs = [
    _NavItem(
        icon: Icons.space_dashboard_outlined,
        activeIcon: Icons.space_dashboard_rounded,
        label: 'Home'),
    _NavItem(
        icon: Icons.layers_outlined,
        activeIcon: Icons.layers_rounded,
        label: 'Models'),
    _NavItem(
        icon: Icons.lan_outlined,
        activeIcon: Icons.lan_rounded,
        label: 'Server'),
    _NavItem(
        icon: Icons.hub_outlined,
        activeIcon: Icons.hub_rounded,
        label: 'Cluster'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      body: Obx(() => IndexedStack(
            index: controller.currentTab.value,
            children: [
              const DashboardView(),
              const ModelView(),
              const ServerView(),
              if (Get.isRegistered<ClusterService>())
                const ClusterView()
              else
                const _ClusterUnsupported(),
            ],
          )),
      bottomNavigationBar: Obx(() => _bottomNav(context, t)),
    );
  }

  Widget _bottomNav(BuildContext context, AppTokens t) {
    final current = controller.currentTab.value;
    return Container(
      decoration: BoxDecoration(
        color: t.bg,
        border: Border(top: BorderSide(color: t.hairline, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 54,
          child: Row(children: [
            for (var i = 0; i < _tabs.length; i++)
              Expanded(
                child: Semantics(
                  selected: current == i,
                  button: true,
                  label: _tabs[i].label,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (current != i) Haptics.selectionClick();
                      controller.changeTab(i);
                    },
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          current == i ? _tabs[i].activeIcon : _tabs[i].icon,
                          size: 23,
                          color: current == i ? t.accent : t.muted,
                        ),
                        const SizedBox(height: 3),
                        Text(_tabs[i].label,
                            style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 10.5,
                                letterSpacing: 0.1,
                                fontWeight: current == i
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: current == i ? t.accent : t.muted)),
                      ],
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _NavItem(
      {required this.icon, required this.activeIcon, required this.label});
}

class _ClusterUnsupported extends StatelessWidget {
  const _ClusterUnsupported();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTokens.of(context).bg,
      appBar: appScreenBar(context, title: 'Cluster'),
      body: const EmptyState(
        icon: Icons.hub_outlined,
        title: 'Not available here',
        message: 'The phone cluster runs on Android and iOS.',
      ),
    );
  }
}
