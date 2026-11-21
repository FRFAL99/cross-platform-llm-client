import 'package:get/get.dart';
import '../controllers/home_controller.dart';
import '../controllers/chat_controller.dart';
import '../controllers/model_controller.dart';
import '../controllers/settings_controller.dart';
import '../views/home_view.dart';
import '../views/chat_view.dart';

abstract class AppRoutes {
  static const home = '/';
  static const chat = '/chat';
}

class AppPages {
  static final pages = [
    GetPage(
      name: AppRoutes.home,
      page: () => const HomeView(),
      binding: BindingsBuilder(() {
        Get.lazyPut(() => HomeController());
        // Kept for the whole session: the chat page comes and goes, its
        // conversation and a running answer must not.
        Get.put(ChatController(), permanent: true);
        Get.lazyPut(() => ModelController());
        Get.lazyPut(() => SettingsController());
      }),
    ),
    GetPage(
      name: AppRoutes.chat,
      page: () => const ChatView(),
    ),
  ];
}
