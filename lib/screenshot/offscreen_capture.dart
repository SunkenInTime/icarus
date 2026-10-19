import 'package:flutter/material.dart';
import 'package:flutter_portal/flutter_portal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The provider container one offscreen capture renders in, cut off from the
/// editor's, with [images] as what its images paint.
///
/// A capture's providers are built fresh here, and a real auth provider
/// among them would reach the one Convex client the app syncs through:
/// building it sets or clears that client's auth, and disposing it tears
/// the auth down, signing the editor out of sync. The strategy provider
/// listens to auth, so auth here is an inert signed-out state; nothing a
/// capture paints needs more.
///
/// The strategy provider is inert too. The real one treats every change to
/// the page's agents, drawings and the rest as an edit, and a capture
/// changes them each time it loads another page: a local strategy would be
/// marked unsaved and autosaved, writing the rendered page over the page
/// open in the editor.
ProviderContainer createCaptureContainer({
  Map<String, StrategyImageSource> images = const {},
}) =>
    ProviderContainer(
      overrides: [
        authProvider.overrideWith(_CaptureAuth.new),
        strategyProvider.overrideWith(_CaptureStrategy.new),
        captureImageSourcesProvider.overrideWithValue(images),
      ],
    );

class _CaptureAuth extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

/// Holds the strategy a capture renders, without the real provider's edit
/// tracking (its build registers the listeners that mark the strategy
/// unsaved), so nothing in a capture can save or sync.
class _CaptureStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: null,
        strategyName: null,
        source: null,
        storageDirectory: null,
        isOpen: false,
      );
}

/// Wraps a widget in the fresh app shell (ProviderScope, theme, portal) that
/// `ScreenshotController.captureFromWidget` needs to render it offscreen at
/// [CoordinateSystem.screenShotSize]. Shared by the PNG screenshot flow and
/// the video exporter.
Widget wrapForOffscreenCapture(
  Widget child, {
  ProviderContainer? container,
}) {
  final app = MediaQuery(
    data: const MediaQueryData(size: CoordinateSystem.screenShotSize),
    child: ShadApp.custom(
      themeMode: ThemeMode.dark,
      darkTheme: ShadThemeData(
        brightness: Brightness.dark,
        colorScheme: Settings.tacticalVioletTheme,
        breadcrumbTheme: const ShadBreadcrumbTheme(separatorSize: 18),
      ),
      appBuilder: (context) {
        return MaterialApp(
          theme: Theme.of(context),
          debugShowCheckedModeBanner: false,
          home: child,
          builder: (context, child) {
            // The captured view paints its own backdrop, or none for a
            // transparent screenshot, so the shell paints nothing under it.
            return Portal(
              child: ShadAppBuilder(
                backgroundColor: Colors.transparent,
                child: child!,
              ),
            );
          },
        );
      },
    ),
  );
  if (container != null) {
    return UncontrolledProviderScope(container: container, child: app);
  }
  return ProviderScope(child: app);
}
