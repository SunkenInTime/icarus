import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/l10n/generated/app_localizations.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

export 'package:icarus/l10n/game_names.dart';
export 'package:icarus/l10n/generated/app_localizations.dart';

// Every word Icarus shows comes from lib/l10n/app_en.arb and its translations.
// A widget reads them with `context.l10n`; code with no widget in reach (a
// provider raising a toast, a service naming a file) reads `l10nProvider`.
// Text that is saved, sent to the server or compared in code is not shown
// text and stays out of the .arb files: it is turned into words where it is
// drawn.

/// English, for a widget drawn with no app above it, as tests pump them.
final _english = lookupAppLocalizations(const Locale('en'));

extension L10nContext on BuildContext {
  /// The app's words in the language it is showing.
  AppLocalizations get l10n =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ?? _english;
}

/// The language Icarus is showing: the one picked in settings, otherwise the
/// first of the system's languages Icarus has, otherwise English. The
/// system's languages are read once: changing them takes a restart.
final appLocaleProvider = Provider<Locale>((ref) {
  final picked = ref.watch(
    appPreferencesProvider.select((preferences) => preferences.languageCode),
  );
  return resolveAppLocale(
    picked: picked,
    system: PlatformDispatcher.instance.locales,
  );
});

/// The app's words for code that has no BuildContext.
final l10nProvider = Provider<AppLocalizations>(
  (ref) => lookupAppLocalizations(ref.watch(appLocaleProvider)),
);

Locale resolveAppLocale({
  required String? picked,
  required List<Locale> system,
}) {
  const supported = AppLocalizations.supportedLocales;
  for (final wanted in [if (picked != null) Locale(picked), ...system]) {
    for (final locale in supported) {
      if (locale.languageCode == wanted.languageCode) return locale;
    }
  }
  return const Locale('en');
}
