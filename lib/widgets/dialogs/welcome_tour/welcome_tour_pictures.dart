import 'package:flutter/material.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// The pictures above each welcome tour step: small drawings of the library,
// built from the same map thumbnails and agent icons the real one shows.
// They are illustrations, so nothing in them responds to the pointer.

const double _stageHeight = 196;
const double _tileWidth = 128;

/// Step 1: three strategies, each with the library's local badge.
class WelcomeLibraryPicture extends StatelessWidget {
  const WelcomeLibraryPicture({super.key});

  @override
  Widget build(BuildContext context) {
    return const _Stage(
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MiniTile(
              name: 'A site execute',
              map: MapValue.ascent,
              icon: LucideIcons.monitor,
              meta: 'On this device',
            ),
            SizedBox(width: 10),
            _MiniTile(
              name: 'B retake vs Viper',
              map: MapValue.lotus,
              icon: LucideIcons.monitor,
              meta: 'On this device',
            ),
            SizedBox(width: 10),
            _MiniTile(
              name: 'Pistol defaults',
              map: MapValue.haven,
              icon: LucideIcons.monitor,
              meta: 'On this device',
            ),
          ],
        ),
      ),
    );
  }
}

/// Step 2: one strategy on its way to the cloud from the right-click menu,
/// one already in the account, and the teammates it can be shared with.
class WelcomeCloudPicture extends StatelessWidget {
  const WelcomeCloudPicture({super.key});

  @override
  Widget build(BuildContext context) {
    return const _Stage(
      child: Stack(
        children: [
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Opacity(
                  opacity: 0.45,
                  child: _MiniTile(
                    name: 'A site execute',
                    map: MapValue.ascent,
                    icon: LucideIcons.cloudUpload,
                    meta: 'Moving…',
                  ),
                ),
                SizedBox(width: 10),
                _MiniTile(
                  name: 'Retake drills',
                  map: MapValue.pearl,
                  icon: LucideIcons.cloud,
                  meta: 'In your account',
                ),
              ],
            ),
          ),
          Positioned(left: 150, top: 126, child: _MiniMenu()),
          Positioned(
            right: 26,
            top: 20,
            child: _Teammates(
              agents: [AgentType.jett, AgentType.sova, AgentType.omen],
            ),
          ),
        ],
      ),
    );
  }
}

/// Step 3: a downloaded match with its players, and the Capture command.
class WelcomeReplayPicture extends StatelessWidget {
  const WelcomeReplayPicture({super.key});

  static const _players = [
    AgentType.jett,
    AgentType.omen,
    AgentType.sova,
    AgentType.killjoy,
    AgentType.sage,
    AgentType.raze,
    AgentType.viper,
    AgentType.skye,
    AgentType.cypher,
    AgentType.reyna,
  ];

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final muted = TextStyle(fontSize: 11, color: theme.mutedForeground);
    return _Stage(
      child: Stack(
        children: [
          Center(
            child: _TileFrame(
              width: 210,
              thumbnail: _mapThumbnail(MapValue.lotus, height: 84),
              details: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(child: _TileName('Lotus')),
                      Text('31:11', style: muted),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text('Tue, Oct 13', style: muted),
                  const SizedBox(height: 6),
                  // Ten players spread across the tile, about 3px apart.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (final agent in _players) _AgentIcon(agent),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Positioned(right: 34, bottom: 26, child: _CaptureButton()),
        ],
      ),
    );
  }
}

/// The well each picture sits in: the library's background, dots included.
class _Stage extends StatelessWidget {
  const _Stage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Container(
      height: _stageHeight,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.background,
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        children: [
          const Positioned.fill(child: DotGrid()),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

/// A strategy tile at a quarter of its size: thumbnail, name, and one line
/// saying where it lives.
class _MiniTile extends StatelessWidget {
  const _MiniTile({
    required this.name,
    required this.map,
    required this.icon,
    required this.meta,
  });

  final String name;
  final MapValue map;
  final IconData icon;
  final String meta;

  @override
  Widget build(BuildContext context) {
    final muted = Settings.tacticalVioletTheme.mutedForeground;
    return _TileFrame(
      width: _tileWidth,
      thumbnail: _mapThumbnail(map, height: 62),
      details: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TileName(name),
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(icon, size: 11, color: muted),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: muted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The tile's two layers: a border-colored rim around the card surface.
class _TileFrame extends StatelessWidget {
  const _TileFrame({
    required this.width,
    required this.thumbnail,
    required this.details,
  });

  final double width;
  final Widget thumbnail;
  final Widget details;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Container(
      width: width,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: theme.border,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: theme.card,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            thumbnail,
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
              child: details,
            ),
          ],
        ),
      ),
    );
  }
}

class _TileName extends StatelessWidget {
  const _TileName(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: Settings.tacticalVioletTheme.foreground,
      ),
    );
  }
}

Widget _mapThumbnail(MapValue map, {required double height}) {
  return ClipRRect(
    borderRadius: BorderRadius.circular(7),
    child: Image.asset(
      'assets/maps/thumbnails/${Maps.mapNames[map]}_thumbnail.webp',
      height: height,
      fit: BoxFit.cover,
    ),
  );
}

/// The strategy right-click menu, open on Move to cloud.
class _MiniMenu extends StatelessWidget {
  const _MiniMenu();

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.card,
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [Settings.floatingMenuShadow],
      ),
      // As wide as its longest item, so the highlight spans the menu.
      child: const IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MiniMenuItem(icon: LucideIcons.link, label: 'Share'),
            _MiniMenuItem(
              icon: LucideIcons.cloudUpload,
              label: 'Move to cloud',
              highlighted: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniMenuItem extends StatelessWidget {
  const _MiniMenuItem({
    required this.icon,
    required this.label,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: highlighted ? theme.secondary : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.mutedForeground),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(fontSize: 12, color: theme.foreground)),
        ],
      ),
    );
  }
}

/// Overlapping round avatars, the way a shared strategy shows its people.
class _Teammates extends StatelessWidget {
  const _Teammates({required this.agents});

  static const double _size = 24;
  static const double _step = 17;

  final List<AgentType> agents;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return SizedBox(
      width: _size + _step * (agents.length - 1),
      height: _size,
      child: Stack(
        children: [
          for (var i = 0; i < agents.length; i++)
            Positioned(
              left: _step * i,
              child: Container(
                width: _size,
                height: _size,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: theme.card,
                  shape: BoxShape.circle,
                  border: Border.all(color: theme.background, width: 2),
                ),
                child: Image.asset(
                  AgentData.agents[agents[i]]!.iconPath,
                  fit: BoxFit.cover,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AgentIcon extends StatelessWidget {
  const _AgentIcon(this.agent);

  final AgentType agent;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Container(
      width: 16,
      height: 16,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.card,
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Image.asset(AgentData.agents[agent]!.iconPath, fit: BoxFit.cover),
    );
  }
}

/// A drawing of the replay viewer's Capture command. Raised but neutral:
/// it can't be pressed here, and violet is kept for things that can.
class _CaptureButton extends StatelessWidget {
  const _CaptureButton();

  @override
  Widget build(BuildContext context) {
    final ink = Settings.tacticalVioletTheme.foreground;
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: Settings.raisedSurface(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.camera, size: 13, color: ink),
          const SizedBox(width: 6),
          Text(
            'Capture',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: ink,
            ),
          ),
        ],
      ),
    );
  }
}
