import 'dart:async';

import 'package:flutter/material.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/library_store/library_migration_start.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class LeftBehindDialog extends StatelessWidget {
  const LeftBehindDialog({
    super.key,
    required this.record,
    required this.oldLibraryFolder,
  });

  final MigrationFinished record;
  final String oldLibraryFolder;

  static bool leftAnything(MigrationFinished record) =>
      record.strategies.isNotEmpty || record.folders.isNotEmpty;

  static Future<void> show(
    BuildContext context,
    MigrationFinished record,
    String oldLibraryFolder,
  ) =>
      showShadDialog<void>(
        context: context,
        builder: (context) => LeftBehindDialog(
          record: record,
          oldLibraryFolder: oldLibraryFolder,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ShadDialog.alert(
      title: Text(l10n.libraryLeftBehindTitle),
      description: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.libraryLeftBehindBody(oldLibraryFolder)),
          const SizedBox(height: 12),
          for (final left in record.strategies) Text(left.name),
          for (final left in record.folders)
            Text(l10n.libraryLeftBehindFolder(left.name)),
        ],
      ),
      actions: [
        ShadButton(
          key: const ValueKey('left-behind-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}

void showWhatWasLeftBehind(MigrationAtStart? atStart) {
  if (atStart
      case (
        migration: MigrationFinishedNow(:final record),
        :final oldLibraryFolder,
      ) when LeftBehindDialog.leftAnything(record)) {
    unawaited(WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
      final navigator = appNavigatorKey.currentState;
      if (navigator == null || !navigator.mounted) return;
      unawaited(
        LeftBehindDialog.show(navigator.context, record, oldLibraryFolder),
      );
    }));
  }
}
