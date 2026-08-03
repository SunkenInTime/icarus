import 'package:flutter/material.dart';
import 'package:flutter_portal/flutter_portal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
