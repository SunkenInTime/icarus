import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/valorant_match_mappings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/valorant/valorant_match_strategy_data.dart';

class MatchRosterCard extends ConsumerWidget {
  const MatchRosterCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strategyId = ref.watch(strategyProvider).id;
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

    return ValueListenableBuilder(
      valueListenable: box.listenable(keys: [strategyId]),
      builder: (context, Box<StrategyData> b, _) {
        final strat = b.get(strategyId);
        final match = strat?.valorantMatch;
        if (match == null) return const SizedBox.shrink();

        final allyTeamId = match.allyTeamId;
        final players = match.players;

        final allies = <ValorantMatchPlayer>[];
        final enemies = <ValorantMatchPlayer>[];
        for (final p in players) {
          if (p.teamId.isNotEmpty && p.teamId == allyTeamId) {
            allies.add(p);
          } else {
            enemies.add(p);
          }
        }

        return ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 260,
            maxWidth: 350,
            maxHeight: 320,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: Settings.tacticalVioletTheme.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Settings.tacticalVioletTheme.border,
                width: 2,
              ),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Players',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _TeamSection(
                          title: 'Allies',
                          players: allies,
                          isAlly: true,
                        ),
                        const SizedBox(height: 10),
                        _TeamSection(
                          title: 'Enemies',
                          players: enemies,
                          isAlly: false,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TeamSection extends StatelessWidget {
  const _TeamSection({
    required this.title,
    required this.players,
    required this.isAlly,
  });

  final String title;
  final List<ValorantMatchPlayer> players;
  final bool isAlly;

  @override
  Widget build(BuildContext context) {
    final headerColor =
        isAlly ? Settings.allyOutlineColor : Settings.enemyOutlineColor;

    if (players.isEmpty) {
      return Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: headerColor,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$title (0)',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: headerColor,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$title (${players.length})',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final p in players) ...[
          _PlayerRow(player: p, isAlly: isAlly),
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow({
    required this.player,
    required this.isAlly,
  });

  final ValorantMatchPlayer player;
  final bool isAlly;

  @override
  Widget build(BuildContext context) {
    final agentType =
        ValorantMatchMappings.agentTypeFromCharacterId(player.characterId);
    final agent = AgentData.agents[agentType];

    final bgColor = isAlly ? Settings.allyBGColor : Settings.enemyBGColor;
    final outlineColor =
        isAlly ? Settings.allyOutlineColor : Settings.enemyOutlineColor;

    final displayName = _displayName(player);

    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: outlineColor, width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.all(1.5),
            child: agent == null
                ? const Icon(Icons.person, size: 18, color: Colors.white)
                : Image.asset(agent.iconPath, fit: BoxFit.contain),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
          ),
        ),
      ],
    );
  }

  static String _displayName(ValorantMatchPlayer p) {
    final base = p.gameName.isNotEmpty ? p.gameName : p.subject;
    if (p.tagLine.isNotEmpty) return '$base#${p.tagLine}';
    return base;
  }
}
