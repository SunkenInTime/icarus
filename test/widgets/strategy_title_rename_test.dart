import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/strategy_quick_switcher.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

void main() {
  late Directory hiveDirectory;

  setUpAll(() async {
    hiveDirectory = await Directory.systemTemp.createTemp('icarus-title-');
    Hive.init(hiveDirectory.path);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDirectory.delete(recursive: true);
  });

  Future<_OpenCloudStrategy> pumpTitle(
    WidgetTester tester, {
    required String role,
    Object? renameError,
  }) async {
    final strategy = _OpenCloudStrategy(renameError);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        strategyProvider.overrideWith(() => strategy),
        currentStrategyCapabilitiesProvider.overrideWithValue(
          StrategyCapabilities.fromCloudRole(role),
        ),
      ],
      child: ToastificationWrapper(
        child: ShadApp(
          themeMode: ThemeMode.dark,
          darkTheme: ShadThemeData(
            brightness: Brightness.dark,
            colorScheme: Settings.tacticalVioletTheme,
          ),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(height: 40, child: StrategyQuickSwitcher()),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    return strategy;
  }

  Finder toast(String text) => find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == text,
        skipOffstage: false,
      );

  Future<void> drainToasts(WidgetTester tester) async {
    toastification.dismissAll(delayForAnimation: false);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  testWidgets('a viewer cannot put the title into edit mode', (tester) async {
    final strategy = await pumpTitle(tester, role: 'viewer');

    await tester.tap(find.text('Original'));
    await tester.pump();

    expect(find.byType(EditableText), findsNothing);
    expect(strategy.renameCalls, 0);
  });

  testWidgets(
      'a refused rename restores the name, leaves edit mode, says so once, '
      'and is not submitted again', (tester) async {
    final strategy = await pumpTitle(
      tester,
      role: 'editor',
      renameError: const ConvexFunctionException(
        code: ConvexErrorCode.forbidden,
        rawCode: 'FORBIDDEN',
        message: 'Forbidden',
      ),
    );

    await tester.tap(find.text('Original'));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'Renamed');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull, reason: 'handled, not rethrown');
    expect(strategy.renameCalls, 1);
    expect(find.byType(EditableText), findsNothing);
    expect(find.text('Original'), findsOneWidget);
    expect(toast("You can't rename this strategy."), findsOneWidget);

    // Focus moving elsewhere afterwards does not submit it again.
    await tester.tapAt(const Offset(5, 300));
    await tester.pump();
    expect(strategy.renameCalls, 1);
    await drainToasts(tester);
  });

  testWidgets('an editor renames normally', (tester) async {
    final strategy = await pumpTitle(tester, role: 'editor');

    await tester.tap(find.text('Original'));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'Renamed');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(strategy.renameCalls, 1);
    expect(find.text('Renamed'), findsOneWidget);
    expect(find.byType(EditableText), findsNothing);
  });
}

class _OpenCloudStrategy extends StrategyProvider {
  _OpenCloudStrategy(this.renameError);

  final Object? renameError;
  int renameCalls = 0;

  @override
  StrategyState build() => const StrategyState(
        strategyId: 'strategy-1',
        strategyName: 'Original',
        source: StrategySource.cloud,
        isOpen: true,
      );

  @override
  Future<void> renameStrategy(
    String strategyID,
    String newName, {
    StrategySource? source,
  }) async {
    renameCalls += 1;
    final error = renameError;
    if (error != null) throw error;
    state = state.copyWith(strategyName: newName);
  }
}
