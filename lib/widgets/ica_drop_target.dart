import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';

@visibleForTesting
String buildImportSummaryMessage(ImportBatchResult result) {
  final skippedCount = result.issues.length;
  final skippedLabel = skippedCount == 1 ? 'file' : 'files';

  if (!result.hasImports) {
    const baseMessage = 'No compatible strategies or folders were imported.';
    if (skippedCount == 0) {
      return baseMessage;
    }
    return '$baseMessage Skipped $skippedCount $skippedLabel.';
  }

  String message;
  if (result.strategiesImported > 0 && result.foldersCreated > 0) {
    final strategiesLabel =
        result.strategiesImported == 1 ? 'strategy' : 'strategies';
    final foldersLabel = result.foldersCreated == 1 ? 'folder' : 'folders';
    message = 'Imported ${result.strategiesImported} $strategiesLabel into '
        '${result.foldersCreated} $foldersLabel.';
  } else if (result.strategiesImported > 0) {
    final strategiesLabel =
        result.strategiesImported == 1 ? 'strategy' : 'strategies';
    message = 'Imported ${result.strategiesImported} $strategiesLabel.';
  } else {
    final foldersLabel = result.foldersCreated == 1 ? 'folder' : 'folders';
    message = 'Imported ${result.foldersCreated} $foldersLabel.';
  }

  if (skippedCount == 0) {
    return message;
  }

  return '$message Skipped $skippedCount $skippedLabel.';
}

class IcaDropTarget extends ConsumerStatefulWidget {
  const IcaDropTarget({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _CustomDropTargetState();
}

class _CustomDropTargetState extends ConsumerState<IcaDropTarget> {
  bool isDragging = false;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (details) {
        setState(() {
          isDragging = true;
        });
        // log("I'm in gurt");
      },
      onDragExited: (details) {
        setState(() {
          isDragging = false;
        });
      },
      onDragDone: (details) async {
        if (mounted) {
          setState(() {
            isDragging = false;
          });
        }
        try {
          final result = await ref
              .read(strategyProvider.notifier)
              .loadFromFileDrop(details.files);

          if (result.hasImports || result.issues.isNotEmpty) {
            Settings.showToast(
              message: buildImportSummaryMessage(result),
              backgroundColor: result.hasImports
                  ? Settings.tacticalVioletTheme.primary
                  : Settings.tacticalVioletTheme.destructive,
            );
          }
        } catch (_) {
          Settings.showToast(
            message: 'Failed to import dropped items.',
            backgroundColor: Settings.tacticalVioletTheme.destructive,
          );
        }
      },
      child: Stack(
        children: [
          Positioned.fill(child: widget.child),
          if (isDragging)
            const Positioned.fill(
              child: ColoredBox(
                color: Color.fromARGB(118, 2, 2, 2),
              ),
            ),
          if (isDragging)
            const Positioned.fill(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.download, size: 60),
                    SizedBox(
                      height: 10,
                    ),
                    Text(
                      "Import strategies, folders, or .zip archives",
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    )
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
