import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/discord_presence_service.dart';

void main() {
  group('DiscordPresenceData', () {
    test('uses a generic library presence when no strategy is open', () {
      final presence = DiscordPresenceData.fromAppState(
        strategy: StrategyState(
          isSaved: true,
          stratName: null,
          id: 'testID',
          storageDirectory: null,
        ),
        map: MapState(currentMap: MapValue.ascent, isAttack: true),
      );

      expect(presence.details, 'Browsing the strategy library');
      expect(presence.state, 'Valorant strategy planner');
      expect(presence.largeImageKey, 'icarus_logo');
    });

    test('shares map and side without sharing the strategy name', () {
      final presence = DiscordPresenceData.fromAppState(
        strategy: StrategyState(
          isSaved: false,
          stratName: 'Secret tournament execute',
          id: 'strategy-id',
          storageDirectory: null,
        ),
        map: MapState(currentMap: MapValue.lotus, isAttack: false),
      );

      expect(presence.details, 'Planning a defense on Lotus');
      expect(presence.state, 'Starting from an empty board');
      expect(presence.largeImageKey, 'lotus_thumbnail');
      expect(presence.largeImageText, 'Lotus');
      expect(presence.smallImageKey, 'icarus_logo');
      expect(presence.smallImageText, 'Icarus');
      expect(presence.details, isNot(contains('Secret')));
      expect(presence.state, isNot(contains('Secret')));
    });

    test('summarizes what is on the board', () {
      DiscordPresenceData build({int agents = 0, int abilities = 0}) =>
          DiscordPresenceData.fromAppState(
            strategy: StrategyState(
              isSaved: false,
              stratName: 'A-site rush',
              id: 'strategy-id',
              storageDirectory: null,
            ),
            map: MapState(currentMap: MapValue.ascent, isAttack: true),
            agentCount: agents,
            abilityCount: abilities,
          );

      expect(build().details, 'Planning an attack on Ascent');
      expect(build().state, 'Starting from an empty board');
      expect(build(agents: 1).state, '1 agent on the board');
      expect(build(agents: 5).state, '5 agents on the board');
      expect(build(abilities: 1).state, '1 ability on the board');
      expect(
        build(agents: 5, abilities: 12).state,
        '5 agents · 12 abilities on the board',
      );
    });
  });
}
