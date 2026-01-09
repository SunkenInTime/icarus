import 'package:flutter/material.dart';

/// Global navigator key used for showing dialogs/sheets from places that may not
/// have a Navigator in their BuildContext (e.g. `ShadApp.builder`).
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
