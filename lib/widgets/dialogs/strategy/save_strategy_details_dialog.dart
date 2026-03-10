import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class StrategySaveDetails {
  const StrategySaveDetails({
    required this.name,
    required this.folderId,
  });

  final String name;
  final String? folderId;
}

Future<StrategySaveDetails?> showStrategySaveDetailsDialog({
  required BuildContext context,
  required String title,
  required String confirmLabel,
  required String initialName,
  String? initialFolderId,
}) {
  return showShadDialog<StrategySaveDetails>(
    context: context,
    builder: (context) {
      return _StrategySaveDetailsDialog(
        title: title,
        confirmLabel: confirmLabel,
        initialName: initialName,
        initialFolderId: initialFolderId,
      );
    },
  );
}

class _StrategySaveDetailsDialog extends StatefulWidget {
  const _StrategySaveDetailsDialog({
    required this.title,
    required this.confirmLabel,
    required this.initialName,
    required this.initialFolderId,
  });

  final String title;
  final String confirmLabel;
  final String initialName;
  final String? initialFolderId;

  @override
  State<_StrategySaveDetailsDialog> createState() =>
      _StrategySaveDetailsDialogState();
}

class _StrategySaveDetailsDialogState extends State<_StrategySaveDetailsDialog> {
  late final TextEditingController _nameController;
  String? _selectedFolderId;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _selectedFolderId = widget.initialFolderId;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(
      StrategySaveDetails(name: name, folderId: _selectedFolderId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final folders = Hive.box<Folder>(HiveBoxNames.foldersBox)
        .values
        .toList(growable: false)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return ShadDialog(
      title: Text(widget.title),
      actions: [
        ShadButton.secondary(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ShadButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
      child: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CustomTextField(
              hintText: 'Strategy name',
              controller: _nameController,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              value: _selectedFolderId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Folder',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Root'),
                ),
                ...folders.map(
                  (folder) => DropdownMenuItem<String?>(
                    value: folder.id,
                    child: Text(folder.name),
                  ),
                ),
              ],
              onChanged: (value) {
                setState(() => _selectedFolderId = value);
              },
            ),
          ],
        ),
      ),
    );
  }
}
