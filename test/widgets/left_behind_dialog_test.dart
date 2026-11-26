import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/l10n/generated/app_localizations.dart';
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
}

const sameIdTwiceForTest = 'another one in this library has the same id';
