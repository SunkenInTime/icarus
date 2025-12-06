import 'package:flutter/material.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class StrategyTileViewData {
  StrategyTileViewData(this.strategy)
      : name = strategy.name,
        mapName = _mapName(strategy.mapData),
        attackLabel = _attackLabel(strategy.pages),
        attackColor = _attackColor(strategy.pages),
        thumbnailAsset =
            'assets/maps/thumbnails/${Maps.mapNames[strategy.mapData]}_thumbnail.webp',
        lastEditedLabel = _timeAgo(strategy.lastEdited),
        agentTypes = _collectAgentTypes(strategy.pages);

  final StrategyData strategy;
  final String name;
  final String mapName;
  final String attackLabel;
  final Color attackColor;
  final String thumbnailAsset;
  final String lastEditedLabel;
  final List<AgentType> agentTypes;

  static String _mapName(MapValue map) {
    final raw = Maps.mapNames[map];
    if (raw == null || raw.isEmpty) {
      return 'Unknown';
    }
    return raw[0].toUpperCase() + raw.substring(1);
  }

  static String _attackLabel(List<StrategyPage> pages) {
    if (pages.isEmpty) {
      return 'Unknown';
    }
    final first = pages.first.isAttack;
    final mixed = pages.any((page) => page.isAttack != first);
    if (mixed) return 'Mixed';
    return first ? 'Attack' : 'Defend';
  }

  static Color _attackColor(List<StrategyPage> pages) {
    final label = _attackLabel(pages);
    switch (label) {
      case 'Attack':
        return Colors.redAccent;
      case 'Defend':
        return Colors.lightBlueAccent;
      default:
        return Colors.orangeAccent;
    }
  }

  static List<AgentType> _collectAgentTypes(List<StrategyPage> pages) {
    final result = <AgentType>{};
    for (final page in pages) {
      for (final agent in page.agentData) {
        result.add(agent.type);
      }
    }
    return result.toList();
  }

  static String _timeAgo(DateTime date) {
    final difference = DateTime.now().difference(date);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inMinutes < 60) {
      final minutes = difference.inMinutes;
      final plural = minutes == 1 ? '' : 's';
      return '$minutes min$plural ago';
    }
    if (difference.inHours < 24) {
      final hours = difference.inHours;
      final plural = hours == 1 ? '' : 's';
      return '$hours hour$plural ago';
    }
    if (difference.inDays < 30) {
      final days = difference.inDays;
      final plural = days == 1 ? '' : 's';
      return '$days day$plural ago';
    }
    final months = (difference.inDays / 30).floor();
    final plural = months == 1 ? '' : 's';
    return '$months month$plural ago';
  }
}

class StrategyTileThumbnail extends StatelessWidget {
  const StrategyTileThumbnail({
    super.key,
    required this.assetPath,
    this.height,
    this.width,
    this.borderRadius = 16,
  });

  final String assetPath;
  final double? height;
  final double? width;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    Widget image = Image.asset(assetPath, fit: BoxFit.cover);
    if (height != null || width != null) {
      image = SizedBox(height: height, width: width, child: image);
    } else {
      image = SizedBox.expand(child: image);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: image,
    );
  }
}

class StrategyTileDetails extends StatelessWidget {
  const StrategyTileDetails({super.key, required this.data});

  final StrategyTileViewData data;

  static const _maxVisibleAgents = 3;

  @override
  Widget build(BuildContext context) {
    final agents = data.agentTypes;

    return Container(
      decoration: BoxDecoration(
          color: ShadTheme.of(context).colorScheme.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Settings.highlightColor),
          boxShadow: const [Settings.cardForegroundBackdrop]),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 130),
                  child: Text(
                    data.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text(data.mapName),
                const SizedBox(height: 5),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 123),
                  child: Row(
                    spacing: 5,
                    children: [
                      ...agents
                          .take(_maxVisibleAgents)
                          .map((agent) => _AgentIcon(agentType: agent)),
                      if (agents.length > _maxVisibleAgents)
                        const _MoreAgentsIndicator(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                data.attackLabel,
                style: TextStyle(color: data.attackColor),
              ),
              const SizedBox(height: 5),
              Text(data.lastEditedLabel),
            ],
          ),
        ],
      ),
    );
  }
}

class StrategyTileDragPreview extends StatelessWidget {
  const StrategyTileDragPreview({super.key, required this.data});

  final StrategyTileViewData data;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 50,
      width: 220,
      decoration: BoxDecoration(
        color: Settings.sideBarColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.deepPurpleAccent, width: 2),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: StrategyTileThumbnail(
              assetPath: data.thumbnailAsset,
              height: double.infinity,
              borderRadius: 8,
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Text(
              data.name,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentIcon extends StatelessWidget {
  const _AgentIcon({required this.agentType});

  final AgentType agentType;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 27,
      width: 27,
      decoration: BoxDecoration(
        color: Settings.sideBarColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Settings.highlightColor),
      ),
      child: Image.asset(AgentData.agents[agentType]!.iconPath),
    );
  }
}

class _MoreAgentsIndicator extends StatelessWidget {
  const _MoreAgentsIndicator();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 27,
      width: 27,
      decoration: BoxDecoration(
        color: Settings.sideBarColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Settings.highlightColor),
      ),
      child: const Icon(
        Icons.more_horiz,
        color: Color.fromARGB(190, 210, 214, 219),
        size: 18,
      ),
    );
  }
}
