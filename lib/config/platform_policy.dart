import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/l10n/l10n.dart';

/// A feature one platform may not offer. [label] names it in user-facing
/// copy, so it reads as the subject of a sentence.
enum PlatformFeature {
  exportFiles,
  importFiles,
  screenshot,
  videoExport,
  fileDrop,
  addImages,
  addLineups,
  replays;

  String label(AppLocalizations l10n) => switch (this) {
        exportFiles => l10n.serviceMsgFeatureExport,
        importFiles => l10n.serviceMsgFeatureImport,
        screenshot => l10n.serviceMsgFeatureScreenshot,
        videoExport => l10n.serviceMsgFeatureVideoExport,
        fileDrop => l10n.serviceMsgFeatureFileDrop,
        addImages => l10n.serviceMsgFeatureAddImages,
        addLineups => l10n.serviceMsgFeatureAddLineups,
        replays => l10n.serviceMsgFeatureReplays,
      };
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
      PlatformFeature.fileDrop,
      // Decoding a replay needs the native decoder and the file on disk.
      PlatformFeature.replays,
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
  String? unavailableMessage(AppLocalizations l10n, PlatformFeature feature) {
    if (desktopOnly.contains(feature)) {
      return l10n.serviceMsgFeatureDesktopOnly(feature.label(l10n));
    }
    if (comingToWebBeta.contains(feature)) {
      return l10n.serviceMsgFeatureComingToWeb(feature.label(l10n));
    }
    return null;
  }
}

/// Override with [PlatformPolicy.webBeta] to exercise the web beta in tests
/// without depending on `kIsWeb`.
final platformPolicyProvider = Provider<PlatformPolicy>(
  (ref) => PlatformPolicy.current,
);
