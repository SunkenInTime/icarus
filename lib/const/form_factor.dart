import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart';

/// The shortest side a phone's screen stays under, in logical pixels.
const double kPhoneShortestSide = 600;

/// The kind of device the app is on, which is what every phone and tablet
/// layout hangs off.
///
/// It goes by the device, not the window, so a desktop window of any size,
/// in the app or in a browser, is always [desktop]. Icarus ships on phones
/// and tablets only as the web beta, where the browser reports iOS or Android
/// (an iPad too, though it calls itself a Mac).
enum FormFactor {
  desktop,
  tablet,
  phone;

  static FormFactor of(BuildContext context) =>
      forWindow(MediaQuery.sizeOf(context));

  /// [isWeb] is here for tests, whose builds aren't web.
  static FormFactor forWindow(Size window, {bool isWeb = kIsWeb}) {
    if (!isWeb) return desktop;
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.android:
        return window.shortestSide < kPhoneShortestSide ? phone : tablet;
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return desktop;
    }
  }

  /// Fingers, not a mouse: nothing here can hover, and a drag means scroll.
  bool get isTouch => this != desktop;

  /// An upright phone is too narrow to edit on, so the editor waits under a
  /// notice to turn sideways.
  bool coversEditor(Size window) =>
      this == phone && window.height > window.width;
}
