import 'package:flutter_riverpod/flutter_riverpod.dart';

/// True when this launch was asked to open something: a file (.ica, .vrf)
/// or a link (a sign-in callback, a share link). Set in main before runApp.
/// That launch belongs to the thing it opens, so the welcome tour waits for
/// the next plain launch.
final launchOpensFileOrLinkProvider = StateProvider<bool>((ref) => false);

/// Whether this run of the app has already decided about the welcome tour.
/// The library screen can be built more than once in a run; the decision is
/// made only the first time.
final welcomeTourLaunchCheckedProvider = StateProvider<bool>((ref) => false);
