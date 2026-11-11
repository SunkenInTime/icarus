import 'package:icarus/const/maps.dart';
import 'package:icarus/l10n/generated/app_localizations.dart';
import 'package:icarus/l10n/official_game_names.dart';

/// Names lib/const spells its own way, by the game's spelling.
const _gameSpelling = {'kayo': 'kay/o'};

/// The game's own names, which Icarus's data (lib/const) holds in English.
extension GameNames on AppLocalizations {
  /// [english], an agent, ability, role or weapon, as Valorant names it in
  /// this language. A name the game doesn't have stays as it is.
  String gameName(String english) {
    final name = english.toLowerCase();
    return officialGameNames[_gameSpelling[name] ?? name]?[localeName] ??
        english;
  }

  /// [map] as Valorant names it in this language.
  String mapName(MapValue map) => mapNameOf(Maps.displayName(map));

  /// The same for a map known only by its English name, in any case.
  String mapNameOf(String english) =>
      officialMapNames[english.toLowerCase()]?[localeName] ?? english;
}
