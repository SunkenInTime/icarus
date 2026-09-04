import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/strategy_quick_switcher.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  late Directory hiveDirectory;

  setUpAll(() async {
    hiveDirectory = await Directory.systemTemp.createTemp(
      'icarus-quick-switcher-layout-',
    );
    Hive.init(hiveDirectory.path);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDirectory.delete(recursive: true);
  });

  testWidgets('editor quick switcher starts on the title-strip center line',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 160));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          strategyProvider.overrideWith(_OpenStrategyProvider.new),
        ],
        child: ShadApp(
          themeMode: ThemeMode.dark,
          darkTheme: ShadThemeData(
            brightness: Brightness.dark,
            colorScheme: Settings.tacticalVioletTheme,
          ),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: StrategyQuickSwitcher(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final control = tester.getRect(
      find.byKey(const ValueKey('strategy-quick-switcher-control')),
    );
    expect(control.top, 0);
    expect(control.height, 40);
    expect(tester.takeException(), isNull);
  });
}

class _OpenStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() {
    return const StrategyState(
      strategyId: 'strategy-1',
      strategyName: 'afeaf',
      source: StrategySource.local,
      isOpen: true,
    );
  }
}
