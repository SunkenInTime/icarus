import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';

String buildImportSummaryMessage(ImportBatchResult result) {
  final skippedCount = result.issues.length;
  final skippedLabel = skippedCount == 1 ? 'file' : 'files';
  final extraSegments = <String>[];

  if (result.themeProfilesImported > 0) {
    final profilesLabel =
        result.themeProfilesImported == 1 ? 'theme profile' : 'theme profiles';
    extraSegments.add(
      'Imported ${result.themeProfilesImported} $profilesLabel.',
    );
  }
  if (result.globalStateRestored) {
    extraSegments.add('Restored library settings.');
  }

  if (!result.hasImports) {
    const baseMessage = 'No compatible strategies or folders were imported.';
    if (skippedCount == 0) {
      return baseMessage;
    }
    return '$baseMessage Skipped $skippedCount $skippedLabel.';
  }

  String message;
  if (result.strategiesImported == 0 &&
      result.foldersCreated == 0 &&
      extraSegments.isNotEmpty) {
    message = extraSegments.join(' ');
    extraSegments.clear();
  } else if (result.strategiesImported > 0 && result.foldersCreated > 0) {
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
    if (extraSegments.isEmpty) {
      return message;
    }
    return '$message ${extraSegments.join(' ')}';
  }

  final extraSuffix =
      extraSegments.isEmpty ? '' : ' ${extraSegments.join(' ')}';
  return '$message$extraSuffix Skipped $skippedCount $skippedLabel.';
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
            final message = buildImportSummaryMessage(result);
            if (result.hasImports) {
              Settings.showToast(
                message: message,
                backgroundColor: Settings.tacticalVioletTheme.primary,
              );
              if (result.issues.isNotEmpty) {
                AppErrorReporter.reportWarning(
                  message,
                  source: 'IcaDropTarget.onDragDone',
                );
              }
            } else {
              AppErrorReporter.reportError(
                message,
                source: 'IcaDropTarget.onDragDone',
              );
            }
          }
        } catch (error, stackTrace) {
          AppErrorReporter.reportError(
            'Failed to import dropped items.',
            error: error,
            stackTrace: stackTrace,
            source: 'IcaDropTarget.onDragDone',
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
                      "Import strategies, folders, or backup archives",
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
