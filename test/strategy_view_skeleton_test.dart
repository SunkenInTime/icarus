import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/strategy_view_skeleton.dart';
import 'package:icarus/widgets/window_chrome.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('loading skeleton fits the minimum desktop window',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.binding.setSurfaceSize(const Size(800, 630));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ShadApp(
          themeMode: ThemeMode.dark,
          darkTheme: ShadThemeData(
            brightness: Brightness.dark,
            colorScheme: Settings.tacticalVioletTheme,
          ),
          home: const MediaQuery(
            data: MediaQueryData(
              size: Size(800, 630),
              disableAnimations: true,
            ),
            child: StrategyViewSkeleton(
              strategyName: 'SYNC BOUNDARY PROBE',
            ),
          ),
        ),
      );
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }

    final mapThumbnail = tester.getRect(find.byType(Image).first);
    final strategyTitle = tester.getRect(find.text('SYNC BOUNDARY PROBE'));
    final captionButtons = tester.getRect(find.byType(WindowCaptionButtons));

    expect(strategyTitle.center.dy, mapThumbnail.center.dy);
    expect(captionButtons.center.dy, mapThumbnail.center.dy);
    expect(tester.takeException(), isNull);
  });
}
