import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A feature one platform may not offer. [label] names it in user-facing
/// copy, so it reads as the subject of a sentence.
enum PlatformFeature {
  exportFiles('Export'),
  importFiles('Import'),
  screenshot('Screenshot'),
  videoExport('Video export'),
  fileDrop('Drag and drop'),
  addImages('Adding images'),
  addLineups('Adding lineups');

  const PlatformFeature(this.label);

  final String label;
}

/// What this build of Icarus offers. The web beta is one value of this
/// class, so bringing a feature (or the local library) to the web is an edit
/// to [webBeta], not a hunt for scattered platform checks.
class PlatformPolicy {
  const PlatformPolicy({
    required this.isWebBeta,
    required this.allowsLocalLibrary,
    required this.requiresSignIn,
    required this.desktopOnly,
    required this.comingToWebBeta,
  });

  /// The desktop app: everything, local and cloud.
  static const desktop = PlatformPolicy(
    isWebBeta: false,
    allowsLocalLibrary: true,
    requiresSignIn: false,
    desktopOnly: {},
    comingToWebBeta: {},
  );

  /// The web beta: signed in, cloud only. Strategies already saved in the
  /// browser stay in its storage; they are hidden, not deleted.
  static const webBeta = PlatformPolicy(
    isWebBeta: true,
    allowsLocalLibrary: false,
    requiresSignIn: true,
    desktopOnly: {
      PlatformFeature.exportFiles,
      PlatformFeature.importFiles,
      PlatformFeature.screenshot,
      PlatformFeature.videoExport,
      PlatformFeature.fileDrop,
    },
    // Empty for now; the Beta dialog hides its "Coming" list when it is.
    comingToWebBeta: {},
  );

  static const PlatformPolicy current = kIsWeb ? webBeta : desktop;

  /// Shows the Beta tag and its dialog.
  final bool isWebBeta;

  /// Lists, creates, and imports strategies in the on-device library.
  final bool allowsLocalLibrary;

  /// My Library opens only once the user is signed in to the cloud.
  final bool requiresSignIn;

  /// Features that stay in the desktop app for now.
  final Set<PlatformFeature> desktopOnly;

  /// Features the web beta will gain; not here yet.
  final Set<PlatformFeature> comingToWebBeta;

  bool supports(PlatformFeature feature) =>
      !desktopOnly.contains(feature) && !comingToWebBeta.contains(feature);

  /// Why [feature] is not here, in one short sentence, or null when it is.
  String? unavailableMessage(PlatformFeature feature) {
    if (desktopOnly.contains(feature)) {
      return '${feature.label} is desktop-only for now.';
    }
    if (comingToWebBeta.contains(feature)) {
      return '${feature.label} is coming to the web beta.';
    }
    return null;
  }
}

/// Override with [PlatformPolicy.webBeta] to exercise the web beta in tests
/// without depending on `kIsWeb`.
final platformPolicyProvider = Provider<PlatformPolicy>(
  (ref) => PlatformPolicy.current,
);
