import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/onboarding/ignite_splash.dart';
import 'package:icarus/onboarding/sunrise.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _MemoryPreferences extends AppPreferencesNotifier {
  @override
  AppPreferences build() => AppPreferences(
        defaultThemeProfileIdForNewStrategies:
            MapThemeProfilesProvider.immutableDefaultProfileId,
      );
}

Future<void> _show(WidgetTester tester, Widget direction) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appPreferencesProvider.overrideWith(_MemoryPreferences.new)],
      child: ShadApp(
        themeMode: ThemeMode.dark,
        darkTheme: ShadThemeData(
          brightness: Brightness.dark,
          colorScheme: Settings.tacticalVioletTheme,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: direction),
      ),
    ),
  );
}

Future<void> _play(WidgetTester tester, Duration length) async {
  const frame = Duration(milliseconds: 16);
  for (var shown = Duration.zero; shown < length; shown += frame) {
    await tester.pump(frame);
  }
}

void main() {
  testWidgets('the splash plays to its end and hands over', (tester) async {
    var done = 0;
    await _show(
      tester,
      IgniteSplash(
        findHome: () => const Rect.fromLTWH(10, 13, 69.4, 14),
        onDone: () => done++,
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    await _play(tester, const Duration(milliseconds: 1500));
    expect(done, 0);
    await _play(tester, const Duration(milliseconds: 1900));
    expect(done, 1);
  });

  testWidgets('after the web loader the splash starts with the mark lit',
      (tester) async {
    var done = 0;
    await _show(
      tester,
      IgniteSplash(
        findHome: () => null,
        onDone: () => done++,
        afterLoader: true,
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    await _play(tester, const Duration(milliseconds: 1200));
    expect(done, 0);
    await _play(tester, const Duration(milliseconds: 1900));
    expect(done, 1);
  });

  testWidgets('a click takes the splash straight to its hand over',
      (tester) async {
    var done = 0;
    await _show(
      tester,
      IgniteSplash(findHome: () => null, onDone: () => done++),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await _play(tester, const Duration(milliseconds: 100));

    await tester.tapAt(const Offset(800, 450));
    await _play(tester, const Duration(milliseconds: 500));

    expect(done, 1);
  });

  testWidgets('the sunrise says its line and offers a start', (tester) async {
    var started = 0;
    await _show(
      tester,
      Sunrise(onStart: () => started++, onSkip: () {}),
    );
    await _play(tester, const Duration(milliseconds: 3200));

    expect(find.text('touch'), findsOneWidget);
    expect(find.text('sun?'), findsOneWidget);
    expect(find.bySemanticsLabel('Ready to touch the sun?'), findsOneWidget);
    expect(find.text('Pick a map'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboarding-start')));
    await _play(tester, const Duration(milliseconds: 400));
    expect(started, 0);
    await _play(tester, const Duration(milliseconds: 400));
    expect(started, 1);
  });

  testWidgets('Enter starts before the button has come in', (tester) async {
    var started = 0;
    await _show(
      tester,
      Sunrise(onStart: () => started++, onSkip: () {}),
    );
    await _play(tester, const Duration(milliseconds: 300));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _play(tester, const Duration(milliseconds: 800));

    expect(started, 1);
  });

  testWidgets('a held sunrise waits and takes no keys', (tester) async {
    var skipped = 0;
    var started = 0;
    await _show(
      tester,
      Sunrise(
        held: true,
        onStart: () => started++,
        onSkip: () => skipped++,
      ),
    );
    await _play(tester, const Duration(milliseconds: 3000));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _play(tester, const Duration(milliseconds: 900));

    expect(skipped, 0);
    expect(started, 0);
  });

  testWidgets('the sunrise leaves by Skip and Escape', (tester) async {
    var skipped = 0;
    await _show(
      tester,
      Sunrise(onStart: () {}, onSkip: () => skipped++),
    );

    await tester.tap(find.byKey(const ValueKey('onboarding-skip')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _play(tester, const Duration(milliseconds: 100));

    expect(skipped, 2);
  });

  testWidgets('a visitor who must log in is offered that instead of a start',
      (tester) async {
    var asked = 0;
    await _show(
      tester,
      Sunrise(onStart: () {}, onSkip: () {}, onLogIn: () => asked++),
    );
    await _play(tester, const Duration(milliseconds: 3200));

    expect(find.byKey(const ValueKey('onboarding-start')), findsNothing);
    expect(find.textContaining('Log in to pick a map'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('onboarding-log-in')));
    await _play(tester, const Duration(milliseconds: 800));

    expect(asked, 1);
  });

  test('the scattered pieces keep to the sides, clear of the words', () {
    const windows = [
      (Size(1600, 900), 810.0),
      (Size(1560, 1190), 815.0),
      (Size(1280, 800), 660.0),
      (Size(1024, 700), 530.0),
    ];

    for (final (window, copyWidth) in windows) {
      final fit = Scatter.fit(window, copyWidth);
      expect(fit, isNotNull, reason: '$window');
      final copyLeft = (window.width - copyWidth) / 2;
      for (final piece in Scatter.pieces) {
        final center = Scatter.center(piece, window, fit!.spread);
        final half = piece.size / 2 * fit.size;
        expect(
          center.dx + half < copyLeft ||
              center.dx - half > window.width - copyLeft,
          isTrue,
          reason: '${piece.kind} at $center in $window',
        );
        expect(center.dy - half, greaterThan(40));
      }
    }
    expect(Scatter.fit(const Size(800, 600), 480), isNull);
  });

  test('the sun is fully up and quiet when the intro ends', () {
    expect(SunriseTimeline.rise(SunriseTimeline.length), 1);
    expect(SunriseTimeline.pulseAt(SunriseTimeline.length), lessThan(0.01));
    expect(SunriseTimeline.rise(0), 0);
  });
}
