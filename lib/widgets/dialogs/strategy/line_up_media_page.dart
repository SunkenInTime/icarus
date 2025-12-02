import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/custom_text_field.dart';

class LineupMediaPage extends StatefulWidget {
  final TextEditingController youtubeLinkController;
  final List<String> imagePaths; // Placeholder for actual image data
  final VoidCallback onAddImage;
  final Function(int index) onRemoveImage;

  const LineupMediaPage({
    super.key,
    required this.youtubeLinkController,
    required this.imagePaths,
    required this.onAddImage,
    required this.onRemoveImage,
  });

  @override
  State<LineupMediaPage> createState() => _LineupMediaPageState();
}

class _LineupMediaPageState extends State<LineupMediaPage> {
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
              color: Settings.abilityBGColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Settings.highlightColor),
            ),
            padding: const EdgeInsets.all(12),
            child: widget.imagePaths.isEmpty
                ? _buildEmptyState()
                : _buildImageGrid(),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8.0),
          child: Text("Notes", style: TextStyle(color: Colors.white)),
        ),
        const CustomTextField(
          hintText: "Add any notes here...",

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
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_photo_alternate_outlined,
                size: 48, color: Colors.white54),
            SizedBox(height: 8),
            Text(
              "Click here to add images",
              style: TextStyle(color: Colors.white54),
            ),
          ],
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
      itemCount: widget.imagePaths.length + 1, // +1 for the Add button
      itemBuilder: (context, index) {
        if (index == widget.imagePaths.length) {
          return _buildAddButton();
        }
        return _buildImageTile(index);
      },
    );
  }

  Widget _buildAddButton() {
    return GestureDetector(
      onTap: widget.onAddImage,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildImageTile(int index) {
    final file = File(widget.imagePaths[index]);
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
      ],
    );
  }
}
