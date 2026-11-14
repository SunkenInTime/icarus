import 'package:flutter/material.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/widgets/community/community_map_art.dart';
import 'package:icarus/widgets/press_scale.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const double _ringWidth = 2;
const double _agentIconSize = 27;
const double _agentSpacing = 5;

/// A post in the Community feed. Built from the My Library card's parts
/// (the same ring, radii and agent icons) with the map's picture filling the
/// card, so it reads as the same app and plainly not your own library.
class CommunityPostCard extends StatefulWidget {
  const CommunityPostCard({
    super.key,
    required this.post,
    required this.starred,
    required this.starCount,
    required this.onOpen,
    required this.onStar,
  });

  final CommunityPost post;
  final bool starred;
  final int starCount;
  final VoidCallback onOpen;
  final VoidCallback onStar;

  @override
  State<CommunityPostCard> createState() => _CommunityPostCardState();
}

class _CommunityPostCardState extends State<CommunityPostCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final post = widget.post;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.all(strategyTileGutterOutset),
      child: Semantics(
        button: true,
        label: post.title,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.onOpen,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              curve: Settings.easeOut,
              decoration: BoxDecoration(
                color: theme.border,
                gradient: _hovered ? Settings.raisedPrimaryFill : null,
                borderRadius: BorderRadius.circular(strategyTileOuterRadius),
              ),
              padding: const EdgeInsets.all(_ringWidth),
              child: Container(
                decoration: BoxDecoration(
                  color: theme.card,
                  borderRadius: BorderRadius.circular(
                    strategyTileOuterRadius - _ringWidth,
                  ),
                ),
                padding: const EdgeInsets.all(8 - _ringWidth),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(strategyTileInnerRadius),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CommunityMapArt(map: post.map, seed: post.publicId),
                      // The picture fades into the card under the words, so
                      // they read on the brightest maps.
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: const [0.3, 0.7],
                            colors: [
                              theme.card.withValues(alpha: 0),
                              theme.card.withValues(alpha: 0.96),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Align(
                              alignment: Alignment.topRight,
                              child: CommunityStarButton(
                                starred: widget.starred,
                                count: widget.starCount,
                                onPressed: widget.onStar,
                              ),
                            ),
                            const Spacer(),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _TwoSided(
                                    left: Text(
                                      post.title,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        height: 18 / 14,
                                      ),
                                    ),
                                    right: Text(
                                      communitySideLabel(l10n, post.side),
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        height: 18 / 14,
                                        color: communitySideColor(post.side),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  _TwoSided(
                                    left: Text(
                                      l10n.mapName(post.map),
                                      style: _secondLine,
                                    ),
                                    right: Text(
                                      post.authorName ?? '',
                                      style: _secondLine,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    height: _agentIconSize,
                                    child: _AgentRow(agents: post.agents),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _secondLine = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w500,
  height: 18 / 14,
);

String communitySideLabel(AppLocalizations l10n, CommunitySide side) =>
    switch (side) {
      CommunitySide.attack => l10n.strategyTileSideAttack,
      CommunitySide.defense => l10n.strategyTileSideDefend,
      CommunitySide.mixed => l10n.strategyTileSideMixed,
    };

Color communitySideColor(CommunitySide side) => switch (side) {
      CommunitySide.attack => Settings.attackColor,
      CommunitySide.defense => Settings.defenderColor,
      CommunitySide.mixed => Settings.mixedStrategyColor,
    };

/// A line with [right] against the far end, as wide as it needs up to
/// under half the line, and [left] in the rest, cut short when it runs out.
class _TwoSided extends StatelessWidget {
  const _TwoSided({required this.left, required this.right});

  final Text left;
  final Text right;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Expanded(
            child: DefaultTextStyle.merge(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: left,
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.45),
            child: DefaultTextStyle.merge(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              child: right,
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({required this.agents});

  final List<AgentType> agents;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final slots = ((constraints.maxWidth + _agentSpacing) /
                (_agentIconSize + _agentSpacing))
            .floor();
        if (slots <= 0) return const SizedBox.shrink();
        final shown = agents.length > slots ? slots - 1 : agents.length;
        return Row(
          spacing: _agentSpacing,
          children: [
            for (final agent in agents.take(shown)) _AgentIcon(agent: agent),
            if (agents.length > slots) const _MoreAgents(),
          ],
        );
      },
    );
  }
}

class _AgentIcon extends StatelessWidget {
  const _AgentIcon({required this.agent});

  final AgentType agent;

  @override
  Widget build(BuildContext context) {
    final data = AgentData.agents[agent]!;
    return Tooltip(
      message: context.l10n.gameName(data.name),
      waitDuration: const Duration(milliseconds: 500),
      child: Container(
        height: _agentIconSize,
        width: _agentIconSize,
        decoration: BoxDecoration(
          color: Settings.tacticalVioletTheme.card,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Settings.tacticalVioletTheme.border),
        ),
        child: Image.asset(data.iconPath, cacheWidth: 64),
      ),
    );
  }
}

class _MoreAgents extends StatelessWidget {
  const _MoreAgents();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _agentIconSize,
      width: _agentIconSize,
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: const Icon(
        LucideIcons.ellipsis,
        size: 18,
        color: Color.fromARGB(190, 210, 214, 219),
      ),
    );
  }
}

/// The star and its count. Violet when the viewer starred it, the app's
/// mark for a checked item.
class CommunityStarButton extends StatelessWidget {
  const CommunityStarButton({
    super.key,
    required this.starred,
    required this.count,
    required this.onPressed,
    this.height = 28,
  });

  final bool starred;
  final int count;
  final VoidCallback onPressed;
  final double height;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final l10n = context.l10n;
    return Semantics(
      button: true,
      toggled: starred,
      label: starred ? l10n.communityUnstar : l10n.communityStar,
      child: ShadTooltip(
        builder: (context) =>
            Text(starred ? l10n.communityUnstar : l10n.communityStar),
        child: PressScale(
          child: _HoverFill(
            height: height,
            onPressed: onPressed,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CommunityStarGlyph(
                  filled: starred,
                  color: starred ? Settings.accentInk : theme.foreground,
                ),
                const SizedBox(width: 6),
                Text(
                  _compactCount(count),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HoverFill extends StatefulWidget {
  const _HoverFill({
    required this.height,
    required this.onPressed,
    required this.child,
  });

  final double height;
  final VoidCallback onPressed;
  final Widget child;

  @override
  State<_HoverFill> createState() => _HoverFillState();
}

class _HoverFillState extends State<_HoverFill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Settings.easeOut,
          height: widget.height,
          padding: const EdgeInsets.only(left: 7, right: 9),
          decoration: BoxDecoration(
            color: _hovered ? theme.input : theme.secondary,
            borderRadius: BorderRadius.circular(6),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 1,234 up to ten thousand, then 12.3k.
String _compactCount(int count) {
  if (count < 10000) {
    final text = count.toString();
    return text.length <= 3
        ? text
        : '${text.substring(0, text.length - 3)},${text.substring(text.length - 3)}';
  }
  final thousands = count / 1000;
  return '${thousands.toStringAsFixed(thousands < 100 ? 1 : 0)}k';
}

/// A five-point star, outlined or filled. Lucide has only the outline.
class CommunityStarGlyph extends StatelessWidget {
  const CommunityStarGlyph({
    super.key,
    required this.filled,
    required this.color,
    this.size = 16,
  });

  final bool filled;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _StarPainter(filled: filled, color: color)),
    );
  }
}

class _StarPainter extends CustomPainter {
  const _StarPainter({required this.filled, required this.color});

  final bool filled;
  final Color color;

  // The star on a 24-unit grid, as Lucide draws its icons.
  static const _points = [
    Offset(12, 2),
    Offset(15.09, 8.26),
    Offset(22, 9.27),
    Offset(17, 14.14),
    Offset(18.18, 21.02),
    Offset(12, 17.77),
    Offset(5.82, 21.02),
    Offset(7, 14.14),
    Offset(2, 9.27),
    Offset(8.91, 8.26),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    final path = Path()
      ..addPolygon(
        [for (final point in _points) point * scale],
        true,
      );
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * scale
      ..strokeJoin = StrokeJoin.round;
    if (filled) {
      canvas.drawPath(path, Paint()..color = color);
    }
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(_StarPainter old) =>
      old.filled != filled || old.color != color;
}
