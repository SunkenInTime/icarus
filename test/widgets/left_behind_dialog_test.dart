import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/l10n/generated/app_localizations.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/widgets/dialogs/left_behind_dialog.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets(
      'names every strategy and folder left behind, and where the old library '
      'is kept', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final record = MigrationFinished(
      startedAt: DateTime.utc(2026, 11, 26),
      finishedAt: DateTime.utc(2026, 11, 26),
      strategies: const [
        LeftBehind('s-1', 'Split B retake', 'it could not be converted'),
        LeftBehind('s-2', 'Haven A', sameIdTwiceForTest),
      ],
      folders: const [LeftBehind('f-1', 'Retakes', 'the store refused it')],
    );
    await tester.pumpWidget(ShadApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: LeftBehindDialog(
          record: record,
          oldLibraryFolder: '/home/me/icarus',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Some strategies stayed in your old library'),
        findsOneWidget);
    expect(find.textContaining('/home/me/icarus'), findsOneWidget);
    expect(find.text('Split B retake'), findsOneWidget);
    expect(find.text('Haven A'), findsOneWidget);
    expect(find.text('Folder: Retakes'), findsOneWidget);
    expect(LeftBehindDialog.leftAnything(record), isTrue);
    expect(
      LeftBehindDialog.leftAnything(MigrationFinished(
        startedAt: DateTime.utc(2026),
        finishedAt: DateTime.utc(2026),
        strategies: const [],
        folders: const [],
      )),
      isFalse,
    );
  });

  group('at start', () {
    MigrationFinished finished({bool closed = false}) => MigrationFinished(
          startedAt: DateTime.utc(2026, 11, 26),
          finishedAt: DateTime.utc(2026, 11, 26),
          strategies: const [
            LeftBehind('s-1', 'Split B retake', 'it could not be converted'),
          ],
          folders: const [],
          leftBehindClosed: closed,
        );

    Future<List<MigrationFinished>> start(
      WidgetTester tester,
      LibraryMigration migration,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final closed = <MigrationFinished>[];
      await tester.pumpWidget(ShadApp(
        navigatorKey: appNavigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(),
      ));
      showWhatWasLeftBehind(
        (migration: migration, oldLibraryFolder: '/home/me/icarus'),
        firstFrame: Future.value(),
        closed: (record) async => closed.add(record),
      );
      await tester.pumpAndSettle();
      return closed;
    }

    for (final (label, migration) in [
      ('the start that moved the library', MigrationFinishedNow(finished())),
      ('a later start', MigrationWasFinished(finished())),
    ]) {
      testWidgets(
          'on $label the dialog shows until it is closed, and closing it is '
          'recorded', (tester) async {
        final closed = await start(tester, migration);

        expect(find.text('Split B retake'), findsOneWidget);
        expect(closed, isEmpty);
        await tester.tap(find.byKey(const ValueKey('left-behind-close')));
        await tester.pumpAndSettle();
        expect(find.text('Split B retake'), findsNothing);
        expect(closed.single.publicIds, ['s-1']);
      });
    }

    testWidgets('once closed it never shows again', (tester) async {
      final closed =
          await start(tester, MigrationWasFinished(finished(closed: true)));

      expect(find.text('Split B retake'), findsNothing);
      expect(closed, isEmpty);
    });
  });
}

extension on MigrationFinished {
  List<String> get publicIds => [for (final left in strategies) left.publicId];
}

const sameIdTwiceForTest = 'another one in this library has the same id';
