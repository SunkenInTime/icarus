import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile_sections.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  for (final edited in [
    '9 months ago',
    '10 months ago',
    '120 months ago',
  ]) {
    testWidgets(
        'a tile whose edited label reads "$edited" keeps its map name on one '
        'line', (tester) async {
      await tester.pumpWidget(
        ShadApp(
          themeMode: ThemeMode.dark,
          darkTheme: ShadThemeData(
            brightness: Brightness.dark,
            colorScheme: Settings.tacticalVioletTheme,
          ),
          home: Material(
            child: Center(
              child: SizedBox(
                width: 236,
                height: 112,
                child: StrategyTileDetails(
                  data: StrategyTileViewData(
                    name: 'Strategy',
                    mapName: 'Ascent',
                    attackLabel: 'Attack',
                    attackColor: Colors.red,
                    thumbnailAsset: '',
                    lastEditedLabel: edited,
                    agentTypes: const [AgentType.jett],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.text('Ascent')).height,
        tester.getSize(find.text('Attack')).height,
      );
    });
  }
}
