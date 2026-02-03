import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class LoadGameDialog extends ConsumerStatefulWidget {
  const LoadGameDialog({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _LoadGameDialogState();
}

class _LoadGameDialogState extends ConsumerState<LoadGameDialog> {
  bool _useDefault = true;
  XFile? _selectedFile;

  Future<void> _pickFile() async {
    if (kIsWeb) {
      Settings.showToast(
        message: 'This feature is only supported in the Windows version.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }
    if (!Platform.isWindows) {
      Settings.showToast(
        message: 'This feature is only supported in the Windows version.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    setState(() {
      _selectedFile = file.xFile;
      _useDefault = false;
    });
  }

  Future<void> _load() async {
    final notifier = ref.read(strategyProvider.notifier);

    String? strategyId;
    if (_useDefault) {
      strategyId = await notifier.importEmbeddedMatchJson();
    } else {
      final xFile = _selectedFile;
      if (xFile == null) {
        Settings.showToast(
          message: 'Choose a match JSON file or enable the default JSON.',
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
        return;
      }
      strategyId = await notifier.importValorantMatchJsonFromXFile(xFile);
    }

    if (!mounted) return;
    Navigator.of(context).pop(strategyId);
  }

  @override
  Widget build(BuildContext context) {
    final fileLabel = _useDefault
        ? 'Bundled: assets/data/match_data.json'
        : (_selectedFile == null
            ? 'No file selected'
            : (_selectedFile!.name.isNotEmpty
                ? _selectedFile!.name
                : _selectedFile!.path));
    final canLoad = _useDefault || _selectedFile != null;

    return ShadDialog(
      title: const Text('Load game'),
      description: const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text(
          'Import a Valorant match JSON to generate pages. If you are evaluating for the hackathon, please use the bundled default JSON.',
        ),
      ),
      actions: [
        ShadButton.secondary(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        ShadButton(
          onPressed: canLoad ? _load : null,
          child: const Text('Load'),
        ),
      ],
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    'Use bundled default match JSON',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                ShadCheckbox(
                  value: _useDefault,
                  onChanged: (value) {
                    setState(() {
                      _useDefault = value;
                      if (_useDefault) _selectedFile = null;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            ShadButton.secondary(
              onPressed: _useDefault ? null : _pickFile,
              leading: const Icon(Icons.upload_file),
              child: const Text('Choose match JSON file'),
            ),
            const SizedBox(height: 8),
            Text(
              fileLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Settings.tacticalVioletTheme.mutedForeground),
            ),
            const SizedBox(height: 8),
            Text(
              _useDefault
                  ? 'Using bundled JSON (recommended for demo/hackathon evaluation).'
                  : 'Tip: The file name becomes the strategy title.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Settings.tacticalVioletTheme.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }
}
