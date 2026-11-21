import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import '../controllers/chat_controller.dart';
import '../controllers/settings_controller.dart';
import '../controllers/model_controller.dart';
import '../controllers/home_controller.dart';
import '../services/cluster_service.dart';
import '../services/inference_service.dart';
import '../utils/thought_parser.dart';
import '../widgets/attachment_preview.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/chat_drawer.dart';
import '../widgets/chat_empty_state.dart';
import '../core/ui.dart';
import '../widgets/thought_disclosure.dart';
import '../core/haptics.dart';

part 'chat_view_app_bar.dart';
part 'chat_view_stream.dart';
part 'chat_view_input.dart';

// ── Apple-style color helpers ──
Color _appleBlue(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? const Color(0xFF0A84FF)
    : const Color(0xFF007AFF);

Color _sep(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? Colors.white.withValues(alpha: 0.08)
    : Colors.black.withValues(alpha: 0.08);

class ChatView extends GetView<ChatController> {
  const ChatView({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Widget scaffold = Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      appBar: _appBar(context, isDark),
      // Past conversations slide in from the right; the left edge is the
      // back gesture.
      endDrawer: const ChatDrawer(),
      drawerScrimColor: Colors.black.withValues(alpha: isDark ? 0.6 : 0.32),
      body: Column(
        children: [
          _modelLoadingBar(context, isDark),
          Expanded(child: Obx(() {
            if (controller.currentSessionId.value.isEmpty ||
                controller.messages.isEmpty) {
              return _emptyState(context, isDark);
            }
            final streaming = controller.isStreaming.value;
            final text = controller.streamingResponse.value;
            final n = controller.messages.length;
            return NotificationListener<ScrollUpdateNotification>(
              onNotification: (note) {
                if (note.dragDetails != null && streaming) {
                  if ((note.scrollDelta ?? 0) < 0) {
                    controller.pauseStreamingFollow();
                  } else {
                    controller.resumeStreamingFollowIfNearBottom();
                  }
                }
                return false;
              },
              child: ListView.builder(
                controller: controller.scrollController,
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                itemCount: n + (streaming ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i == n && streaming) {
                    return _streamBubble(context, text, isDark);
                  }
                  return ChatBubble(message: controller.messages[i]);
                },
              ),
            );
          })),
          _inputBar(context, isDark),
        ],
      ),
    );

    if (Platform.isIOS) {
      return GestureDetector(
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        behavior: HitTestBehavior.translucent,
        child: scaffold,
      );
    }
    return scaffold;
  }
}
