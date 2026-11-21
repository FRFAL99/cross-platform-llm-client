import 'package:get/get.dart';

import '../core/routes.dart';

/// The four tabs of the main screen. The chat is not a tab: it is a test
/// bench for the loaded model and opens on its own page from Home.
abstract class AppTab {
  static const home = 0;
  static const models = 1;
  static const server = 2;
  static const cluster = 3;
}

class HomeController extends GetxController {
  final currentTab = AppTab.home.obs;

  void changeTab(int index) {
    currentTab.value = index;
  }

  /// Shows [index] from anywhere, closing pages pushed over the tabs
  /// (the chat, settings, the speed test).
  void openTab(int index) {
    Get.until((route) => route.isFirst);
    changeTab(index);
  }

  void openChat() => Get.toNamed(AppRoutes.chat);
}
