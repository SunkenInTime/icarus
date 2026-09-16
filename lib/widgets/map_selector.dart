import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/map_tile.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class MapSelector extends ConsumerStatefulWidget {
  const MapSelector({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _MapSelectorState();
}

class _MapSelectorState extends ConsumerState<MapSelector> {
  static const double _cardHeight = 65;
  static const double _outerRadius = 12;
  static const double _innerGap = 4;
  static const double _innerRadius = _outerRadius - _innerGap;
  static const double _borderWidth = 1;
  static const double _sideToggleWidth = 66;
  // Sized from the contents so the gap on the right of the side toggle equals
  // the gap on the left of the map tile.
  static const double _cardWidth = 2 * _borderWidth +
      2 * _innerGap +
      MapTile.width +
      _innerGap +
      _sideToggleWidth;

  final OverlayPortalController _controller = OverlayPortalController();
  final _link = LayerLink();
  double _containerHeight = 0;
  bool _isOpen = false;

  void _closePortal() {
    // For closing, animate to zero first
    setState(() {
      _containerHeight = 0;
      _isOpen = false;
    });

    // Then hide the overlay after animation completes
    Future.delayed(const Duration(milliseconds: 200), () {
      _controller.hide();
    });
  }

  void _openPortal() {
    // First show the overlay with zero size
    _controller.show();

    Future.delayed(const Duration(milliseconds: 100), () {
      setState(() {
        _containerHeight = 500;
        _isOpen = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final MapValue currentMap = ref.watch(mapProvider).currentMap;
    final List<MapValue> availableMaps = Maps.mapNames.keys
        .where((mapValue) => Maps.availableMaps.contains(mapValue))
        .toList()
      ..sort(
        (a, b) => Maps.mapNames[a]!.toLowerCase().compareTo(
              Maps.mapNames[b]!.toLowerCase(),
            ),
      );
    final List<MapValue> outOfRotationMaps = Maps.outofplayMaps.toList()
      ..sort(
        (a, b) => Maps.mapNames[a]!.toLowerCase().compareTo(
              Maps.mapNames[b]!.toLowerCase(),
            ),
      );

    return CompositedTransformTarget(
      link: _link,
      child: Container(
        decoration: BoxDecoration(
          color: Settings.tacticalVioletTheme.card,
          borderRadius: const BorderRadius.all(Radius.circular(_outerRadius)),
          border: Border.all(
            color: Settings.tacticalVioletTheme.border,
            width: _borderWidth,
          ),
        ),
        width: _cardWidth,
        height: _cardHeight,
        child: Padding(
          padding: const EdgeInsets.all(_innerGap),
          child: Row(
            children: [
              OverlayPortal(
                controller: _controller,
                overlayChildBuilder: (context) {
                  return CompositedTransformFollower(
                    link: _link,
                    targetAnchor: Alignment.bottomLeft,
                    child: Align(
                      alignment: AlignmentDirectional.topStart,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          height: _containerHeight,
                          width: 260,
                          decoration: BoxDecoration(
                            color: Settings.tacticalVioletTheme.card,
                            borderRadius: const BorderRadius.all(
                              Radius.circular(10),
                            ),
                            border: Border.all(
                              color: Settings.tacticalVioletTheme.border,
                              width: 2,
                            ),
                          ),
                          child: ClipRRect(
                            clipBehavior: Clip.antiAlias,
                            borderRadius: const BorderRadius.all(
                              Radius.circular(10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: ListView.separated(
                                    padding: const EdgeInsets.all(_innerGap),
                                    itemCount: availableMaps.length +
                                        outOfRotationMaps.length +
                                        1,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: _innerGap),
                                    itemBuilder: (context, index) {
                                      if (index < availableMaps.length) {
                                        final mapValue = availableMaps[index];
                                        final mapName =
                                            Maps.mapNames[mapValue]!;
                                        return MapTile(
                                          name: mapName,
                                          borderRadius: _innerRadius,
                                          onTap: () {
                                            ref
                                                .read(mapProvider.notifier)
                                                .updateMap(mapValue);
                                            ref
                                                .read(strategyProvider.notifier)
                                                .setUnsaved();
                                            _closePortal();
                                          },
                                        );
                                      }

                                      if (index == availableMaps.length) {
                                        return const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 5,
                                          ),
                                          child: Text(
                                            "Out of rotation",
                                            style: TextStyle(
                                              fontWeight: FontWeight.w500,
                                              color: Color.fromARGB(
                                                255,
                                                160,
                                                160,
                                                160,
                                              ),
                                            ),
                                            textAlign: TextAlign.center,
                                          ),
                                        );
                                      }

                                      final mapValue = outOfRotationMaps[
                                          index - availableMaps.length - 1];
                                      final mapName = Maps.mapNames[mapValue]!;
                                      return MapTile(
                                        name: mapName,
                                        borderRadius: _innerRadius,
                                        // isActive: mapValue == currentMap,
                                        onTap: () {
                                          ref
                                              .read(mapProvider.notifier)
                                              .updateMap(mapValue);
                                          ref
                                              .read(strategyProvider.notifier)
                                              .setUnsaved();
                                          _closePortal();
                                        },
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
                child: MapTile(
                  name: Maps.mapNames[currentMap]!,
                  borderRadius: _innerRadius,
                  onTap: () {
                    if (!_isOpen) {
                      _openPortal();
                    } else {
                      _closePortal();
                    }
                  },
                ),
              ),
              const SizedBox(width: _innerGap),
              const SizedBox(
                width: _sideToggleWidth,
                child: _SideToggle(borderRadius: _innerRadius),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Flips the side the map is drawn from. A click applies to every page;
/// Shift+click applies to this page only, which is how a strategy becomes
/// mixed. When it is mixed, a dot warns that a plain click will unify it.
class _SideToggle extends ConsumerWidget {
  const _SideToggle({required this.borderRadius});

  final double borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAttack = ref.watch(mapProvider.select((state) => state.isAttack));
    final strategyId = ref.watch(strategyProvider.select((state) => state.id));
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

    return ValueListenableBuilder(
      valueListenable: box.listenable(keys: [strategyId]),
      builder: (context, Box<StrategyData> b, _) {
        final pages = b.get(strategyId)?.pages ?? const [];
        final mixed =
            pages.any((page) => page.isAttack != pages.first.isAttack);
        final nextSide = isAttack ? 'Defense' : 'Attack';
        final tooltip = mixed
            ? 'Pages are on mixed sides\n'
                'Click: all pages to $nextSide\n'
                'Shift+click: this page only'
            : 'Switch side on all pages\nShift+click: this page only';

        return ShadTooltip(
          builder: (context) => Text(tooltip),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                ref.read(strategyProvider.notifier).switchSide(
                      allPages: !HardwareKeyboard.instance.isShiftPressed,
                    );
              },
              mouseCursor: SystemMouseCursors.click,
              borderRadius: BorderRadius.circular(borderRadius),
              hoverColor: Colors.white.withValues(alpha: 0.08),
              child: Stack(
                // Fill the toggle so the column centres in the box, not in
                // the width of its own label.
                fit: StackFit.expand,
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isAttack ? CustomIcons.sword : LucideIcons.shield,
                        size: 20,
                        color: isAttack ? Colors.redAccent : Colors.blueAccent,
                      ),
                      Text(
                        isAttack ? "Attack" : "Defense",
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  if (mixed)
                    const Positioned(
                      top: 6,
                      right: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.orangeAccent,
                          shape: BoxShape.circle,
                        ),
                        child: SizedBox(width: 6, height: 6),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
