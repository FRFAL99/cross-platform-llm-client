part of 'model_view.dart';

// Models screen: importing GGUF files from a file or a folder.

extension _ImportSection on ModelView {
  // ── Import ────────────────────────────────────────────────────────────

  void _showImportSheet(BuildContext context) {
    showAppSheet<void>(
      context,
      title: 'Import model',
      subtitle: 'Add .gguf files from your phone.',
      builder: (ctx) => AppGroup(dividerIndent: 60, children: [
        AppRow(
          icon: Icons.insert_drive_file_outlined,
          title: 'Import file',
          subtitle: 'Choose a single model file',
          chevron: true,
          onTap: () {
            Navigator.pop(ctx);
            controller.importModelFromStorage();
          },
        ),
        if (controller.supportsFolderImport)
          AppRow(
            icon: Icons.folder_open_rounded,
            title: 'Import from folder',
            subtitle: 'Scan a folder and pick the models to add',
            chevron: true,
            onTap: () {
              Navigator.pop(ctx);
              _importFromFolder(context);
            },
          ),
      ]),
    );
  }

  Future<void> _importFromFolder(BuildContext context) async {
    final files = await controller.pickModelFolder();
    if (files == null || !context.mounted) return;
    if (files.isEmpty) {
      showToast('No models found', 'That folder has no .gguf files.',
          tone: ToastTone.warning);
      return;
    }
    final chosen = await showAppSheet<List<FolderModelFile>>(
      context,
      title: 'Models in folder',
      subtitle: '${files.length} ${files.length == 1 ? 'file' : 'files'} found',
      builder: (_) => _FolderImportList(files: files, controller: controller),
    );
    if (chosen != null && chosen.isNotEmpty) {
      await controller.importFolderFiles(chosen);
    }
  }

  Widget _buildEmptyLibrary(BuildContext context) {
    return EmptyState(
      icon: Icons.download_rounded,
      title: 'No models on this phone yet',
      message: 'Download one from Browse, or import a model file.',
      action: Wrap(spacing: 8, children: [
        PillButton(
          label: 'Browse models',
          primary: true,
          onPressed: () => controller.modelScope.value = 'browse',
        ),
        _buildLocalActions(context),
      ]),
    );
  }
}

/// Checklist of model files found in a folder. Files already in the app
/// are shown but can't be picked again.
class _FolderImportList extends StatefulWidget {
  final List<FolderModelFile> files;
  final ModelController controller;
  const _FolderImportList({required this.files, required this.controller});

  @override
  State<_FolderImportList> createState() => _FolderImportListState();
}

class _FolderImportListState extends State<_FolderImportList> {
  late final Set<String> _selected = {
    for (final f in widget.files)
      if (!_imported(f)) f.uri,
  };

  bool _imported(FolderModelFile f) => widget.controller.isDownloaded(f.name);

  static String _size(int bytes) => bytes >= 1024 * 1024 * 1024
      ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final picked =
        widget.files.where((f) => _selected.contains(f.uri)).toList();
    final total = picked.fold<int>(0, (sum, f) => sum + f.size);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppGroup(children: [
        for (final f in widget.files)
          AppRow(
            title: f.name,
            subtitle: _imported(f)
                ? '${_size(f.size)} · Already in the app'
                : _size(f.size),
            trailing: Checkbox(
              value: _imported(f) ? true : _selected.contains(f.uri),
              onChanged: _imported(f)
                  ? null
                  : (v) => setState(() => v == true
                      ? _selected.add(f.uri)
                      : _selected.remove(f.uri)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5)),
              activeColor: t.accent,
            ),
            onTap: _imported(f)
                ? null
                : () => setState(() => _selected.contains(f.uri)
                    ? _selected.remove(f.uri)
                    : _selected.add(f.uri)),
          ),
      ]),
      const SizedBox(height: 16),
      PrimaryButton(
        label: picked.isEmpty
            ? 'Nothing selected'
            : 'Import ${picked.length} · ${_size(total)}',
        icon: Icons.download_rounded,
        onPressed: picked.isEmpty ? null : () => Navigator.pop(context, picked),
      ),
      const SizedBox(height: 8),
      Text('Files are copied into app storage, so make sure there is room.',
          textAlign: TextAlign.center, style: t.small),
    ]);
  }
}
