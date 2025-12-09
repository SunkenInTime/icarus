import 'dart:io' show File, Directory;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:path/path.dart' as path;

class LineupMediaPage extends ConsumerStatefulWidget {
  final TextEditingController youtubeLinkController;
  final List<SimpleImageData> images; // Placeholder for actual image data
  final VoidCallback onAddImage;
  final Function(int index) onRemoveImage;
  final TextEditingController notesController;
  const LineupMediaPage({
    super.key,
    required this.youtubeLinkController,
    required this.images,
    required this.onAddImage,
    required this.onRemoveImage,
    required this.notesController,
  });

  @override
  ConsumerState<LineupMediaPage> createState() => _LineupMediaPageState();
}

class _LineupMediaPageState extends ConsumerState<LineupMediaPage> {
  late final Directory imageFolderPath;

  Future<void> _setImageDirectory(String strategyID) async {
    imageFolderPath = await PlacedImageProvider.getImageFolder(strategyID);
  }

  @override
  void initState() {
    super.initState();
    final strategyID = ref.read(strategyProvider).id;
    _setImageDirectory(strategyID);
  }

  @override
  void dispose() {
    widget.youtubeLinkController.dispose();
    widget.notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Youtube link", style: TextStyle(color: Colors.white)),
        const SizedBox(height: 8),
        CustomTextField(
          controller: widget.youtubeLinkController,
          hintText: "Paste YouTube link here...",
        ),
        const SizedBox(height: 24),
        const Text("Images", style: TextStyle(color: Colors.white)),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Settings.tacticalVioletTheme.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Settings.tacticalVioletTheme.border),
            ),
            padding: const EdgeInsets.all(12),
            child:
                widget.images.isEmpty ? _buildEmptyState() : _buildImageGrid(),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8.0),
          child: Text("Notes", style: TextStyle(color: Colors.white)),
        ),
        CustomTextField(
          hintText: "Add any notes here...",
          controller: widget.notesController,
          // onEnterPressed: (intent) {
          //   // Handle enter pressed if needed
          // },
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return GestureDetector(
      onTap: widget.onAddImage,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_photo_alternate_outlined,
                  size: 48, color: Settings.tacticalVioletTheme.cardForeground),
              const SizedBox(height: 8),
              Text(
                "Click here to add images",
                style: TextStyle(
                    color: Settings.tacticalVioletTheme.cardForeground),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImageGrid() {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: widget.images.length + 1, // +1 for the Add button
      itemBuilder: (context, index) {
        if (index == widget.images.length) {
          return _buildAddButton();
        }
        return _buildImageTile(index);
      },
    );
  }

  Widget _buildAddButton() {
    return GestureDetector(
      onTap: widget.onAddImage,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          decoration: BoxDecoration(
            color: Settings.tacticalVioletTheme.secondary,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Settings.tacticalVioletTheme.border),
          ),
          child: const Icon(Icons.add, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildImageTile(int index) {
    final String fullImagePath = path.join(imageFolderPath.path,
        widget.images[index].id + widget.images[index].fileExtension);
    final file = File(fullImagePath);
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            image: DecorationImage(
              image: FileImage(file), // Placeholder
              fit: BoxFit.cover,
            ),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: () => widget.onRemoveImage(index),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
