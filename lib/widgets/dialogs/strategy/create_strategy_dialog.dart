import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const double _tileWidth = 220;
const double _tileHeight = 110;
const double _tileGap = 8;
const int _columns = 4;
const double _gridWidth = _columns * _tileWidth + (_columns - 1) * _tileGap;

/// Creating a strategy is picking its map. One tap on a tile creates the
/// strategy, auto-named after the map, and pops with its id.
class CreateStrategyDialog extends ConsumerStatefulWidget {
  const CreateStrategyDialog({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _CreateStrategyDialogState();
}

class _CreateStrategyDialogState extends ConsumerState<CreateStrategyDialog> {
  bool _isSubmitting = false;
  bool _showOutOfRotation = false;
  MapValue? _hoveredMap;

  static List<MapValue> _sorted(List<MapValue> maps) => maps.toList()
    ..sort((a, b) => Maps.displayName(a).compareTo(Maps.displayName(b)));

  Future<void> _create(MapValue map) async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);
    try {
      final strategyID =
          await ref.read(strategyProvider.notifier).createNewStrategy(map: map);
      if (!mounted) return;
      Navigator.of(context).pop(strategyID);
    } catch (_) {
      if (mounted) setState(() => _isSubmitting = false);
      Settings.showToast(
        message: "Couldn't create strategy right now.",
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    }
  }

  Widget _grid(List<MapValue> maps) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: _tileGap,
      runSpacing: _tileGap,
      children: [
        for (final map in maps)
          _MapCard(
            key: ValueKey('create-strategy-map-${Maps.mapNames[map]}'),
            map: map,
            hovered: _hoveredMap == map,
            quiet: _hoveredMap != null && _hoveredMap != map,
            onHover: (over) => setState(
              () => _hoveredMap =
                  over ? map : (_hoveredMap == map ? null : _hoveredMap),
            ),
            onTap: () => _create(map),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ShadDialog(
      title: const Text('Pick a map'),
      // Shad caps dialogs at 512; the grid plus padding needs more.
      constraints: const BoxConstraints(maxWidth: _gridWidth + 48),
      child: Material(
        color: Colors.transparent,
        child: IgnorePointer(
          ignoring: _isSubmitting,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: _isSubmitting ? 0.6 : 1,
            child: SizedBox(
              width: _gridWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  _grid(_sorted(Maps.availableMaps)),
                  const SizedBox(height: 12),
                  ShadButton.ghost(
                    key: const ValueKey('create-strategy-out-of-rotation'),
                    size: ShadButtonSize.sm,
                    padding: EdgeInsets.zero,
                    onPressed: () => setState(
                      () => _showOutOfRotation = !_showOutOfRotation,
                    ),
                    trailing: AnimatedRotation(
                      duration: const Duration(milliseconds: 120),
                      turns: _showOutOfRotation ? 0.5 : 0,
                      child: const Icon(LucideIcons.chevronDown, size: 14),
                    ),
                    child: Text(
                      'Out of rotation',
                      style: theme.textTheme.small
                          .copyWith(color: theme.colorScheme.mutedForeground),
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: _showOutOfRotation
                        ? Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: _grid(_sorted(Maps.outofplayMaps)),
                          )
                        : const SizedBox(width: _gridWidth),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A map to pick: its art with the name centred over it. Hovering one map
/// lifts it, rings it, and quiets every other card so the choice stands alone.
class _MapCard extends StatelessWidget {
  const _MapCard({
    super.key,
    required this.map,
    required this.hovered,
    required this.quiet,
    required this.onHover,
    required this.onTap,
  });

  final MapValue map;
  final bool hovered;
  final bool quiet;
  final ValueChanged<bool> onHover;
  final VoidCallback onTap;

  static const _duration = Duration(milliseconds: 90);

  @override
  Widget build(BuildContext context) {
    // 0 is quiet, 1 is rest, 2 is hovered; one tween carries all three.
    final target = hovered ? 2.0 : (quiet ? 0.0 : 1.0);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: _tileWidth,
          height: _tileHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: TweenAnimationBuilder<double>(
                  duration: _duration,
                  curve: Curves.easeOut,
                  tween: Tween(end: target),
                  builder: (context, t, child) {
                    final lift = (t - 1).clamp(0.0, 1.0);
                    final hush = (1 - t).clamp(0.0, 1.0);
                    return ColorFiltered(
                      colorFilter: _tint(
                        saturation: lerpDouble(1, .35, hush)!,
                        brightness:
                            lerpDouble(lerpDouble(.85, 1, lift)!, .55, hush)!,
                      ),
                      child: Transform.scale(
                        scale: lerpDouble(1, 1.04, lift)!,
                        child: child,
                      ),
                    );
                  },
                  child: Image.asset(
                    'assets/maps/thumbnails/${Maps.mapNames[map]}_thumbnail.webp',
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              AnimatedOpacity(
                duration: _duration,
                opacity: quiet ? .5 : 1,
                child: Center(
                  child: Text(
                    Maps.displayName(map).toUpperCase(),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.white,
                      shadows: [
                        Shadow(
                          color: Colors.black,
                          blurRadius: 2,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AnimatedContainer(
                duration: _duration,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    width: hovered ? 2 : 1,
                    color: hovered
                        ? Settings.accentInk
                        : Colors.white.withValues(alpha: .10),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A colour matrix that scales saturation and brightness, 1 being untouched.
ColorFilter _tint({required double saturation, required double brightness}) {
  const r = 0.2126, g = 0.7152, b = 0.0722;
  final s = saturation, v = brightness;
  return ColorFilter.matrix([
    (r + (1 - r) * s) * v,
    (g - g * s) * v,
    (b - b * s) * v,
    0,
    0,
    (r - r * s) * v,
    (g + (1 - g) * s) * v,
    (b - b * s) * v,
    0,
    0,
    (r - r * s) * v,
    (g - g * s) * v,
    (b + (1 - b) * s) * v,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);
}
