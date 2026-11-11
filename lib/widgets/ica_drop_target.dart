import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/widgets/replay/open_replays.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Says what came in and what didn't. Updating is the one thing a user can do
/// about files from a newer Icarus, so the summary always asks for it.
String buildImportSummaryMessage(
  AppLocalizations l10n,
  ImportBatchResult result,
) {
  final newerCount = result.issues
      .where((issue) => issue.code == ImportIssueCode.newerVersion)
      .length;
  if (!result.hasImports &&
      newerCount > 0 &&
      newerCount == result.issues.length) {
    return newerCount == 1
        ? NewerVersionImportException.userMessage(l10n)
        : l10n.icaDropAllNewerVersion;
  }

  final summary = _countedImportSummary(l10n, result);
  if (newerCount == 0) return summary;
  return '$summary${l10n.commonSentenceSpace}'
      '${l10n.icaDropSomeNewerVersion(newerCount)}';
}

String _countedImportSummary(AppLocalizations l10n, ImportBatchResult result) {
  final skippedCount = result.issues.length;
  final space = l10n.commonSentenceSpace;
  final extraSegments = <String>[];

  if (result.themeProfilesImported > 0) {
    extraSegments.add(
      l10n.icaDropImportedThemeProfiles(result.themeProfilesImported),
    );
  }
  if (result.globalStateRestored) {
    extraSegments.add(l10n.icaDropRestoredLibrarySettings);
  }

  if (!result.hasImports) {
    final baseMessage = l10n.icaDropNothingImported;
    if (skippedCount == 0) {
      return baseMessage;
    }
    return '$baseMessage$space${l10n.icaDropSkippedFiles(skippedCount)}';
  }

  String message;
  if (result.strategiesImported == 0 &&
      result.foldersCreated == 0 &&
      extraSegments.isNotEmpty) {
    message = extraSegments.join(space);
    extraSegments.clear();
  } else if (result.strategiesImported > 0 && result.foldersCreated > 0) {
    message = l10n.icaDropImportedStrategiesIntoFolders(
      result.strategiesImported,
      result.foldersCreated,
    );
  } else if (result.strategiesImported > 0) {
    message = l10n.icaDropImportedStrategies(result.strategiesImported);
  } else {
    message = l10n.icaDropImportedFolders(result.foldersCreated);
  }

  if (skippedCount == 0) {
    if (extraSegments.isEmpty) {
      return message;
    }
    return '$message$space${extraSegments.join(space)}';
  }

  final extraSuffix =
      extraSegments.isEmpty ? '' : '$space${extraSegments.join(space)}';
  return '$message$extraSuffix$space${l10n.icaDropSkippedFiles(skippedCount)}';
}

/// Tells the user how an import went: what came in, what was skipped, or that
/// nothing did.
void showImportResult(
  AppLocalizations l10n,
  ImportBatchResult result, {
  required String source,
}) {
  if (!result.hasImports && result.issues.isEmpty) return;

  final message = buildImportSummaryMessage(l10n, result);
  if (!result.hasImports) {
    AppErrorReporter.reportError(message, source: source);
    return;
  }

  Settings.showToast(
    message: message,
    backgroundColor: Settings.tacticalVioletTheme.primary,
  );
  if (result.issues.isNotEmpty) {
    AppErrorReporter.reportWarning(message, source: source);
  }
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
        // Replays are taken by ReplayWindowDropTarget, wherever they land.
        final files = [
          for (final file in details.files)
            if (!isReplayPath(file.path)) file,
        ];
        if (files.isEmpty) return;
        // A replay in the same drop switches to the Replays tab, which
        // disposes this widget mid-import; the app's container outlives it.
        final container = ProviderScope.containerOf(context, listen: false);
        final l10n = container.read(l10nProvider);
        try {
          final result = await StrategyImportExportService(container)
              .loadFromFileDrop(files);

          showImportResult(l10n, result, source: 'IcaDropTarget.onDragDone');
        } catch (error, stackTrace) {
          AppErrorReporter.reportError(
            l10n.icaDropImportFailed,
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
            Positioned.fill(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(LucideIcons.download, size: 60),
                    const SizedBox(
                      height: 10,
                    ),
                    Text(
                      context.l10n.icaDropOverlayLabel,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold),
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
