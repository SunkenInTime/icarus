import 'package:flutter/material.dart';
import 'package:flutter_portal/flutter_portal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_image_source.dart';
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
ProviderContainer createCaptureContainer({
  Map<String, StrategyImageSource> images = const {},
}) =>
    ProviderContainer(
      overrides: [
        authProvider.overrideWith(_CaptureAuth.new),
        captureImageSourcesProvider.overrideWithValue(images),
      ],
    );

class _CaptureAuth extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

/// Keep screenshot coordinates confined to pixel capture. Asset loading and
/// output dialogs must leave the live editor's coordinate conversions intact.
Future<T> withScreenshotCoordinates<T>(Future<T> Function() capture) async {
  final coordinates = CoordinateSystem.instance;
  final previousMode = coordinates.isScreenshot;
  coordinates.setIsScreenshot(true);
  try {
    return await capture();
  } finally {
    coordinates.setIsScreenshot(previousMode);
  }
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
            return Portal(child: ShadAppBuilder(child: child!));
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
