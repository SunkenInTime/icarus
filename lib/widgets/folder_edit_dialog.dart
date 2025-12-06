import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/widgets/color_picker_button.dart';
import 'package:icarus/widgets/custom_button.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/folder_tile.dart';
import 'package:icarus/widgets/sidebar_widgets/color_buttons.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class FolderEditDialog extends ConsumerStatefulWidget {
  const FolderEditDialog({
    super.key,
    this.folder,
  });
  final Folder? folder;
  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _FolderEditDialogState();
}

class _FolderEditDialogState extends ConsumerState<FolderEditDialog> {
  final TextEditingController _folderNameController = TextEditingController();

  IconData _selectedIcon = Folder.folderIcons[0];
  FolderColor _selectedColor = FolderColor.red;
  Color? _customColor;
  @override
  void dispose() {
    _folderNameController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Listen to text changes and rebuild
    _selectedColor = widget.folder?.color ?? FolderColor.generic;
    if (widget.folder != null) {
      _folderNameController.text = widget.folder!.name;
      _selectedIcon = widget.folder!.icon;
      _customColor = widget.folder!.customColor;
    }
    _folderNameController.addListener(() {
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: Text(widget.folder != null ? "Edit Folder" : "Add Folder"),
      actions: [
        SizedBox(
          width: 250,
          child: CustomTextField(
            hintText: "Folder Name",
            controller: _folderNameController,
          ),
        ),
        // const SizedBox(width: 30),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: ShadButton(
            leading: const Icon(Icons.check),
            onPressed: () async {
              if (widget.folder != null) {
                ref.read(folderProvider.notifier).editFolder(
                      folder: widget.folder!,
                      newName: _folderNameController.text.isEmpty
                          ? "New Folder"
                          : _folderNameController.text,
                      newIcon: _selectedIcon,
                      newColor: _selectedColor,
                      newCustomColor: _customColor,
                    );
                if (context.mounted) Navigator.of(context).pop();
                return;
              }
              await ref.read(folderProvider.notifier).createFolder(
                    name: _folderNameController.text.isEmpty
                        ? "New Folder"
                        : _folderNameController.text,
                    icon: _selectedIcon,
                    color: _selectedColor,
                    customColor: _customColor,
                  );

              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text("Done"),
          ),
        )
      ],
      child: SizedBox(
        width: 358,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 300,
              width: 358,
              decoration: BoxDecoration(
                color: Settings.tacticalVioletTheme.card,
                border: Border.all(
                  color: Settings.tacticalVioletTheme.border,
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Stack(
                children: [
                  const Positioned.fill(
                      child: ClipRRect(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                    child: Padding(
                      padding: EdgeInsets.all(2.0),
                      child: DotGrid(),
                    ),
                  )),
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.center,
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: FolderTile(
                          folder: Folder(
                            icon: _selectedIcon,
                            name: _folderNameController.text,
                            id: "null",
                            dateCreated: DateTime.now(),
                            color: _selectedColor,
                            customColor: _customColor,
                          ),
                          isDemo: true,
                        ),
                      ),
                    ),
                  )
                ],
              ),
            ),
            // const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  for (final color in Folder.folderColors)
                    Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: ColorButtons(
                        height: 30,
                        width: 30,
                        color: Folder.folderColorMap[color]!,
                        isSelected: _selectedColor == color,
                        onTap: () {
                          setState(() {
                            _selectedColor = color;
                          });
                          // ref.read(penProvider.notifier).setColor(index);
                        },
                      ),
                    ),
                  ColorPickerButton(
                    height: 30,
                    width: 30,
                    onTap: () {
                      // Open color picker dialog
                      showDialog(
                        context: context,
                        builder: (context) {
                          return ShadDialog(
                            title: const Text("Pick a custom color"),
                            actions: <Widget>[
                              ShadButton(
                                child: const Text('Done'),
                                onPressed: () {
                                  Navigator.of(context).pop();
                                },
                              ),
                            ],
                            child: Material(
                              child: SizedBox(
                                width: 300,
                                child: ColorPicker(
                                  portraitOnly: true,
                                  pickerColor:
                                      Folder.folderColorMap[_selectedColor] ??
                                          _customColor!,
                                  onColorChanged: (color) {
                                    setState(() {
                                      _selectedColor = FolderColor.custom;
                                      _customColor = color;
                                    });
                                  },
                                  pickerAreaHeightPercent: 0.8,
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  )
                ],
              ),
            ),
            Container(
              height: 200,
              width: 358,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Settings.tacticalVioletTheme.border,
                  width: 1,
                ),
                color: Settings.tacticalVioletTheme.card,
                borderRadius: BorderRadius.circular(12),
              ),
              child: GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7, // Number of icons per row
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1,
                ),
                itemCount: Folder.folderIcons.length,
                itemBuilder: (context, index) {
                  return IconButton(
                      onPressed: () {
                        setState(() {
                          _selectedIcon = Folder.folderIcons[index];
                        });
                      },
                      isSelected: _selectedIcon == Folder.folderIcons[index],
                      icon: Icon(
                        Folder.folderIcons[index],
                        size: 24,
                        color: Colors.white,
                      ),
                      selectedIcon: Icon(
                        Folder.folderIcons[index],
                        size: 24,
                        color: Settings.tacticalVioletTheme.primary,
                      ));
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
