import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/cloud_library_action.dart';
import 'package:icarus/services/cloud_strategy_export.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/dialogs/delete_folder_alert_dialog.dart';
import 'package:icarus/widgets/dialogs/strategy/delete_strategy_alert_dialog.dart';
import 'package:icarus/widgets/folder_edit_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('folder edit failure stays open, is safe, and can retry',
      (tester) async {
    final firstAttempt = Completer<CloudLibraryActionResult>();
    final folderProvider = _ControlledFolderProvider()
      ..editResults.add(firstAttempt.future)
      ..editResults.add(Future.value(CloudLibraryActionResult.succeeded));
    await _pumpDialogLauncher(
      tester,
      overrides: [
        _folderProviderOverride(folderProvider),
      ],
      dialog: FolderEditDialog(folder: _folder()),
    );

    await tester.tap(find.byKey(const ValueKey('folder-edit-submit')));
    await tester.tap(find.byKey(const ValueKey('folder-edit-submit')));
    await tester.pump();
    expect(folderProvider.editCalls, 1);
    expect(find.text('Saving...'), findsOneWidget);

    firstAttempt.complete(
      CloudLibraryActionResult.failed(
        "Couldn't update this cloud folder. Try again.",
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FolderEditDialog), findsOneWidget);
    expect(
      find.text("Couldn't update this cloud folder. Try again."),
      findsOneWidget,
    );
    expect(find.text(_secret), findsNothing);

    await tester.tap(find.byKey(const ValueKey('folder-edit-submit')));
    await tester.pumpAndSettle();
    expect(folderProvider.editCalls, 2);
    expect(find.byType(FolderEditDialog), findsNothing);
  });

  testWidgets('folder delete failure stays open, is safe, and can retry',
      (tester) async {
    final firstAttempt = Completer<CloudLibraryActionResult>();
    final folderProvider = _ControlledFolderProvider()
      ..deleteResults.add(firstAttempt.future)
      ..deleteResults.add(Future.value(CloudLibraryActionResult.succeeded));
    await _pumpDialogLauncher(
      tester,
      overrides: [_folderProviderOverride(folderProvider)],
      dialog: DeleteFolderAlertDialog(
        folder: _folder(),
        workspace: LibraryWorkspace.cloud,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('delete-folder-confirm')));
    await tester.tap(find.byKey(const ValueKey('delete-folder-confirm')));
    await tester.pump();
    expect(folderProvider.deleteCalls, 1);
    expect(find.text('Deleting...'), findsOneWidget);

    firstAttempt.complete(
      CloudLibraryActionResult.failed(
        "Couldn't delete this cloud folder. Try again.",
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DeleteFolderAlertDialog), findsOneWidget);
    expect(
      find.text("Couldn't delete this cloud folder. Try again."),
      findsOneWidget,
    );
    expect(find.text(_secret), findsNothing);

    await tester.tap(find.byKey(const ValueKey('delete-folder-confirm')));
    await tester.pumpAndSettle();
    expect(folderProvider.deleteCalls, 2);
    expect(find.byType(DeleteFolderAlertDialog), findsNothing);
  });

  testWidgets('strategy delete failure stays open, is safe, and can retry',
      (tester) async {
    final firstAttempt = Completer<CloudLibraryActionResult>();
    final strategyProvider = _ControlledStrategyProvider()
      ..deleteResults.add(firstAttempt.future)
      ..deleteResults.add(Future.value(CloudLibraryActionResult.succeeded));
    await _pumpDialogLauncher(
      tester,
      overrides: [_strategyProviderOverride(strategyProvider)],
      dialog: const DeleteStrategyAlertDialog(
        strategyID: 'strategy-1',
        name: 'A Split',
        source: StrategySource.cloud,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('delete-strategy-confirm')));
    await tester.tap(find.byKey(const ValueKey('delete-strategy-confirm')));
    await tester.pump();
    expect(strategyProvider.deleteCalls, 1);
    expect(find.text('Deleting...'), findsOneWidget);

    firstAttempt.complete(
      CloudLibraryActionResult.failed(
        "Couldn't delete this cloud strategy. Try again.",
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DeleteStrategyAlertDialog), findsOneWidget);
    expect(
      find.text("Couldn't delete this cloud strategy. Try again."),
      findsOneWidget,
    );
    expect(find.text(_secret), findsNothing);

    await tester.tap(find.byKey(const ValueKey('delete-strategy-confirm')));
    await tester.pumpAndSettle();
    expect(strategyProvider.deleteCalls, 2);
    expect(find.byType(DeleteStrategyAlertDialog), findsNothing);
  });

  testWidgets('thrown strategy delete resets the dialog and can retry',
      (tester) async {
    final firstAttempt = Completer<CloudLibraryActionResult>();
    final strategyProvider = _ControlledStrategyProvider()
      ..deleteResults.add(firstAttempt.future)
      ..deleteResults.add(Future.value(CloudLibraryActionResult.succeeded));
    await _pumpDialogLauncher(
      tester,
      overrides: [_strategyProviderOverride(strategyProvider)],
      dialog: const DeleteStrategyAlertDialog(
        strategyID: 'strategy-1',
        name: 'A Split',
        source: StrategySource.local,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('delete-strategy-confirm')));
    firstAttempt.completeError(StateError(_secret));
    await tester.pumpAndSettle();

    expect(
        find.text("Couldn't delete this strategy. Try again."), findsOneWidget);
    expect(find.text(_secret), findsNothing);
    await tester.tap(find.byKey(const ValueKey('delete-strategy-confirm')));
    await tester.pumpAndSettle();
    expect(strategyProvider.deleteCalls, 2);
    expect(find.byType(DeleteStrategyAlertDialog), findsNothing);
  });

  testWidgets('cloud export failure reports one generic message',
      (tester) async {
    final messages = <String>[];
    var exportCalls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cloudStrategyExporterProvider.overrideWithValue((_) async {
            exportCalls += 1;
            throw StateError(_secret);
          }),
          cloudLibraryActionReporterProvider.overrideWithValue(
            CloudLibraryActionReporter(
              showMessage: messages.add,
              reportTechnicalFailure: ({
                required source,
                required error,
                required stackTrace,
              }) {},
            ),
          ),
          authProvider.overrideWith(_ReadyAuthProvider.new),
        ],
        child: const ShadApp(
          home: Scaffold(body: _CloudExportInvoker()),
        ),
      ),
    );

    await tester.tap(find.text('Export cloud strategy'));
    await tester.pumpAndSettle();

    expect(exportCalls, 1);
    expect(messages, ["Couldn't export this cloud strategy. Try again."]);
    expect(messages.single, isNot(contains(_secret)));
  });

  testWidgets('cancelled cloud export stays silent', (tester) async {
    final messages = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cloudStrategyExporterProvider.overrideWithValue((_) async => false),
          cloudLibraryActionReporterProvider.overrideWithValue(
            CloudLibraryActionReporter(
              showMessage: messages.add,
              reportTechnicalFailure: ({
                required source,
                required error,
                required stackTrace,
              }) {},
            ),
          ),
          authProvider.overrideWith(_ReadyAuthProvider.new),
        ],
        child: const ShadApp(
          home: Scaffold(body: _CloudExportInvoker()),
        ),
      ),
    );

    await tester.tap(find.text('Export cloud strategy'));
    await tester.pumpAndSettle();

    expect(messages, isEmpty);
  });

  test('auth failures use the incident path without a generic message',
      () async {
    final messages = <String>[];
    var authReports = 0;
    final reporter = CloudLibraryActionReporter(
      showMessage: messages.add,
      reportTechnicalFailure: ({
        required source,
        required error,
        required stackTrace,
      }) {},
    );

    final result = await reporter.run(
      action: () async => throw const ConvexClientFunctionError(
        rawCode: 'UNAUTHENTICATED',
        message: 'Authentication required',
        data: null,
      ),
      source: 'test:auth',
      failureMessage: 'This must not be shown.',
      showFailureMessage: true,
      reportAuthenticationFailure: (_, __) async => authReports += 1,
    );

    expect(result.status, CloudLibraryActionStatus.authenticationRequired);
    expect(result.userMessage, 'Reconnect to Icarus Cloud, then try again.');
    expect(authReports, 1);
    expect(messages, isEmpty);
  });
}

const _secret = 'Bearer super-secret-backend-detail';

Override _folderProviderOverride(_ControlledFolderProvider notifier) =>
    folderProvider.overrideWith(() => notifier);

Override _strategyProviderOverride(_ControlledStrategyProvider notifier) =>
    strategyProvider.overrideWith(() => notifier);

Future<void> _pumpDialogLauncher(
  WidgetTester tester, {
  required List<Override> overrides,
  required Widget dialog,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: ShadApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ShadButton(
              onPressed: () => showShadDialog<void>(
                context: context,
                builder: (_) => dialog,
              ),
              child: const Text('Open dialog'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open dialog'));
  await tester.pumpAndSettle();
}

class _ControlledFolderProvider extends FolderProvider {
  final Queue<Future<CloudLibraryActionResult>> editResults = Queue();
  final Queue<Future<CloudLibraryActionResult>> deleteResults = Queue();
  int editCalls = 0;
  int deleteCalls = 0;

  @override
  String? build() => null;

  @override
  Future<CloudLibraryActionResult> editFolder({
    required Folder folder,
    required String newName,
    required int newIconId,
    required FolderColor newColor,
    required Color? newCustomColor,
    LibraryWorkspace? workspace,
  }) {
    editCalls += 1;
    return editResults.removeFirst();
  }

  @override
  Future<CloudLibraryActionResult> deleteFolder(
    String folderID, {
    LibraryWorkspace? workspace,
  }) {
    deleteCalls += 1;
    return deleteResults.removeFirst();
  }
}

class _ControlledStrategyProvider extends StrategyProvider {
  final Queue<Future<CloudLibraryActionResult>> deleteResults = Queue();
  int deleteCalls = 0;

  @override
  StrategyState build() => const StrategyState(
        strategyId: null,
        strategyName: null,
        source: null,
        storageDirectory: null,
        isOpen: false,
      );

  @override
  Future<CloudLibraryActionResult> deleteStrategy(
    String strategyID, {
    StrategySource? source,
  }) {
    deleteCalls += 1;
    return deleteResults.removeFirst();
  }
}

class _CloudExportInvoker extends ConsumerWidget {
  const _CloudExportInvoker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ShadButton(
      onPressed: () => runCloudStrategyExport(ref, 'strategy-1'),
      child: const Text('Export cloud strategy'),
    );
  }
}

class _ReadyAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: null,
      );
}

Folder _folder() => Folder(
      id: 'folder-1',
      name: 'Defaults',
      iconId: 0,
      dateCreated: DateTime.utc(2026),
      color: FolderColor.generic,
    );
