part of 'chat_view.dart';

// Chat screen: the input bar and the attach menu.

extension _InputSection on ChatView {
  // ── Input Bar ──
  Widget _inputBar(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      color: isDark ? Colors.black : Colors.white,
      child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Attachment preview
            Obx(() {
              final name = controller.selectedFileName.value;
              if (name == null) return const SizedBox.shrink();
              return Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: AttachmentPreview(
                    fileName: name,
                    fileType: controller.selectedFileType.value,
                    fileSize: controller.selectedFileSize.value > 0
                        ? controller.selectedFileSize.value
                        : null,
                    imagePath: controller.selectedImagePath.value,
                    imageBase64: controller.selectedImageBase64.value,
                    onRemove: () {
                      controller.clearImage();
                      controller.clearFile();
                    },
                  ));
            }),
            // Composer: one rounded surface holding the field and its actions.
            Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF141416)
                      : const Color(0xFFF5F5F7),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.09)
                          : Colors.black.withValues(alpha: 0.07),
                      width: 0.5),
                ),
                child:
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  // Attach button: documents for any loaded model, photos
                  // too when it has a vision projector.
                  Obx(() {
                    final inf = Get.find<InferenceService>();
                    if (!inf.isModelLoaded.value) {
                      return const SizedBox.shrink();
                    }
                    return _AttachButton(
                      isDark: isDark,
                      allowMedia: inf.isVisionLoaded.value,
                      onCamera: () =>
                          controller.pickImage(source: ImageSource.camera),
                      onImage: controller.pickImage,
                      onFile: () => controller.pickFile(documentsOnly: true),
                      context: context,
                    );
                  }),
                  // Text field
                  // Same 40px base height as the buttons so a single line sits
                  // centred; taller multi-line input keeps buttons at the bottom.
                  Expanded(child: Obx(() {
                    // Nothing loaded: the field is disabled and tapping it
                    // goes to Models.
                    final noModel = _localModelMissing();
                    final loadingModel =
                        Get.find<InferenceService>().isLoadingModel.value;
                    return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: noModel && !loadingModel
                            ? () => Get.find<HomeController>().openTab(AppTab.models)
                            : null,
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 40),
                          alignment: Alignment.centerLeft,
                          child: TextField(
                            enabled: !noModel,
                            controller: controller.textController,
                            focusNode: controller.inputFocus,
                            textCapitalization: TextCapitalization.sentences,
                            onChanged: (v) => controller.inputText.value = v,
                            maxLines: 5,
                            minLines: 1,
                            style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 15,
                                color: isDark ? Colors.white : Colors.black),
                            decoration: InputDecoration(
                              hintText: !noModel
                                  ? 'Ask anything'
                                  : loadingModel
                                      ? 'Loading model…'
                                      : 'Load a model to start chatting',
                              hintStyle: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 15,
                                  color: Theme.of(context).hintColor),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              isDense: true,
                              filled: false,
                            ),
                            onSubmitted: (_) => controller.sendMessage(),
                          ),
                        ));
                  })),
                  const SizedBox(width: 6),
                  // Send / stop button
                  Obx(() {
                    final loading = controller.isLoading.value;
                    final noModel = _localModelMissing();
                    final hasContent = controller.inputText.value.isNotEmpty ||
                        controller.selectedFileName.value != null ||
                        controller.selectedImagePath.value != null;
                    final canSend = hasContent && !noModel;

                    final Color bgColor;
                    final IconData iconData;
                    final VoidCallback? onTap;
                    if (loading) {
                      // Generating → solid neutral stop
                      bgColor = isDark ? Colors.white : Colors.black;
                      iconData = Icons.stop_rounded;
                      onTap = controller.stopGenerating;
                    } else if (canSend) {
                      bgColor = _appleBlue(context);
                      iconData = Icons.arrow_upward_rounded;
                      onTap = controller.sendMessage;
                    } else {
                      // Nothing to send yet: a quiet, inert arrow.
                      bgColor = Theme.of(context)
                          .hintColor
                          .withValues(alpha: isDark ? 0.18 : 0.12);
                      iconData = Icons.arrow_upward_rounded;
                      onTap = null;
                    }

                    return GestureDetector(
                      onTap: onTap,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                            color: bgColor, shape: BoxShape.circle),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          transitionBuilder: (child, anim) =>
                              ScaleTransition(scale: anim, child: child),
                          child: Icon(iconData,
                              key: ValueKey(iconData),
                              color: loading
                                  ? (isDark ? Colors.black : Colors.white)
                                  : canSend
                                      ? Colors.white
                                      : Theme.of(context)
                                          .hintColor
                                          .withValues(alpha: 0.6),
                              size: 20),
                        ),
                      ),
                    );
                  }),
                ])),
          ])),
    );
  }

  bool _localModelMissing() =>
      !Get.find<InferenceService>().isModelLoaded.value;
}

// ── Attach Button ──
class _AttachButton extends StatelessWidget {
  final bool isDark;

  /// Photos/camera need a vision-capable model; documents work everywhere.
  final bool allowMedia;
  final VoidCallback onCamera;
  final VoidCallback onImage;
  final VoidCallback onFile;
  final BuildContext context;

  const _AttachButton({
    required this.isDark,
    required this.allowMedia,
    required this.onCamera,
    required this.onImage,
    required this.onFile,
    required this.context,
  });

  @override
  Widget build(BuildContext buildContext) {
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _showMenu(buildContext),
        child: SizedBox(
          width: 36,
          height: 40,
          child: Icon(Icons.add_rounded,
              color: Theme.of(buildContext)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.7),
              size: 24),
        ),
      ),
    );
  }

  /// Popover anchored above the + button, growing out of it.
  void _showMenu(BuildContext ctx) {
    Haptics.selectionClick();
    FocusManager.instance.primaryFocus?.unfocus();
    final box = ctx.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.of(ctx).size;
    final dark = Theme.of(ctx).brightness == Brightness.dark;

    final items = [
      (
        icon: Icons.photo_camera_outlined,
        label: 'Camera',
        enabled: allowMedia,
        onTap: onCamera,
      ),
      (
        icon: Icons.photo_outlined,
        label: 'Photos',
        enabled: allowMedia,
        onTap: onImage,
      ),
      (
        icon: Icons.attach_file_rounded,
        label: 'Files',
        enabled: true,
        onTap: onFile,
      ),
    ];

    showGeneralDialog(
      context: ctx,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black.withValues(alpha: dark ? 0.35 : 0.12),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (dialogCtx, _, __) {
        final fg = dark ? Colors.white : const Color(0xFF0B0B0C);
        final muted = dark ? const Color(0xFF8E8E93) : const Color(0xFF6E6E73);
        return Stack(children: [
          Positioned(
            left: origin.dx - 6,
            bottom: screen.height - origin.dy + 10,
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 236,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: dark ? const Color(0xFF242427) : Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                      color: dark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.black.withValues(alpha: 0.06),
                      width: 0.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: dark ? 0.5 : 0.12),
                      blurRadius: 32,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final it in items)
                    Opacity(
                      opacity: it.enabled ? 1 : 0.4,
                      child: InkWell(
                        onTap: it.enabled
                            ? () {
                                Navigator.pop(dialogCtx);
                                it.onTap();
                              }
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          child: Row(children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: dark
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : Colors.black.withValues(alpha: 0.05),
                              ),
                              child: Icon(it.icon, size: 21, color: fg),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(it.label,
                                        style: TextStyle(
                                            fontFamily: 'Inter',
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                            letterSpacing: -0.2,
                                            color: fg)),
                                    if (!it.enabled)
                                      Text('Needs a vision model',
                                          style: TextStyle(
                                              fontFamily: 'Inter',
                                              fontSize: 12,
                                              color: muted)),
                                  ]),
                            ),
                          ]),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ]);
      },
      transitionBuilder: (_, anim, __, child) {
        final curved =
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween(begin: 0.92, end: 1.0).animate(curved),
            alignment: Alignment(-1 + 2 * (origin.dx / screen.width),
                -1 + 2 * (origin.dy / screen.height)),
            child: child,
          ),
        );
      },
    );
  }
}
