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

    final strip = tester.getRect(find.byType(AppWindowStrip));
    final mapThumbnail = tester.getRect(find.byType(Image).first);
    final strategyTitle = tester.getRect(find.text('SYNC BOUNDARY PROBE'));
    final captionButtons = tester.getRect(find.byType(WindowCaptionButtons));

    // Title and caption buttons share the strip; the map card sits on the
    // canvas below it, like the real editor.
    expect(strip.height, kWindowStripHeight);
    expect(strategyTitle.center.dy, closeTo(strip.center.dy, 0.5));
    expect(captionButtons.center.dy, closeTo(strip.center.dy, 0.5));
    expect(mapThumbnail.top, greaterThan(strip.bottom));
    expect(tester.takeException(), isNull);
  });
}
