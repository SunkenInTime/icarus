import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/strategy_quick_switcher.dart';
import 'package:icarus/widgets/window_chrome.dart';
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

  testWidgets('editor controls share the map card center line', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
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
                child: EditorWindowHeader(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      SizedBox(
                        key: ValueKey('map-card-reference'),
                        width: 262,
                        height: 65,
                      ),
                      StrategyQuickSwitcher(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }

    final control = tester.getRect(
      find.byKey(const ValueKey('strategy-quick-switcher-control')),
    );
    final mapCard = tester.getRect(
      find.byKey(const ValueKey('map-card-reference')),
    );
    final captionButtons = tester.getRect(find.byType(WindowCaptionButtons));
    final header = tester.getRect(find.byType(EditorWindowHeader));

    expect(control.center.dy, mapCard.center.dy);
    expect(captionButtons.center.dy, mapCard.center.dy);
    expect(mapCard.top - header.top, header.bottom - mapCard.bottom);
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
