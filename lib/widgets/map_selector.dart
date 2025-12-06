import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/widgets/map_tile.dart';

class MapSelector extends ConsumerStatefulWidget {
  const MapSelector({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _MapSelectorState();
}

class _MapSelectorState extends ConsumerState<MapSelector> {
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

    return CompositedTransformTarget(
      link: _link,
      child: Container(
        decoration: BoxDecoration(
          color: Settings.tacticalVioletTheme.card,
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          border: Border.all(
            color: Settings.tacticalVioletTheme.border,
            width: 2,
          ),
        ),
        width: 262,
        height: 65,
        child: Padding(
          padding: const EdgeInsets.all(4.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                            color: Settings.sideBarColor,
                            borderRadius:
                                const BorderRadius.all(Radius.circular(10)),
                            border: Border.all(
                              color: Settings.highlightColor,
                              width: 2,
                            ),
                          ),
                          child: ClipRRect(
                            clipBehavior: Clip.antiAlias,
                            borderRadius:
                                const BorderRadius.all(Radius.circular(10)),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: ListView(
                                    children: [
                                      // Available maps section
                                      // const Padding(
                                      //   padding: EdgeInsets.all(8.0),
                                      //   child: Text(
                                      //     "Current Rotation",
                                      //     style: TextStyle(
                                      //       fontWeight: FontWeight.bold,
                                      //       color: Colors.white,
                                      //     ),
                                      //     textAlign: TextAlign.center,
                                      //   ),
                                      // ),
                                      ...Maps.mapNames.keys
                                          .where((mapValue) => Maps
                                              .availableMaps
                                              .contains(mapValue))
                                          .map((mapValue) {
                                        String mapName =
                                            Maps.mapNames[mapValue]!;
                                        return Padding(
                                          padding: const EdgeInsets.all(4),
                                          child: MapTile(
                                            name: mapName,
                                            onTap: () {
                                              ref
                                                  .read(mapProvider.notifier)
                                                  .updateMap(mapValue);
                                              _closePortal();
                                            },
                                          ),
                                        );
                                      }),

                                      // const Divider(
                                      //   color: Colors.grey,
                                      //   thickness: 1,
                                      //   height: 24,
                                      // ),

                                      // Out of play maps section
                                      const Padding(
                                        padding: EdgeInsets.all(8.0),
                                        child: Text(
                                          "Out of rotation",
                                          style: TextStyle(
                                            fontWeight: FontWeight.w500,
                                            color: Color.fromARGB(
                                                255, 160, 160, 160),
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                      ...Maps.outofplayMaps.map((mapValue) {
                                        String mapName =
                                            Maps.mapNames[mapValue]!;
                                        return Padding(
                                          padding: const EdgeInsets.all(4),
                                          child: MapTile(
                                            name: mapName,
                                            onTap: () {
                                              ref
                                                  .read(mapProvider.notifier)
                                                  .updateMap(mapValue);
                                              _closePortal();
                                            },
                                          ),
                                        );
                                      }),
                                    ],
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
                    onTap: () {
                      if (!_isOpen) {
                        _openPortal();
                      } else {
                        _closePortal();
                      }
                    }),
              ),
              // const SizedBox(
              //   width: 10,
              // ),
              Expanded(
                child: IconButton(
                    onPressed: () {
                      ref.read(mapProvider.notifier).switchSide();
                    },
                    icon: Column(
                      children: [
                        Icon(
                          (ref.watch(mapProvider).isAttack)
                              ? CustomIcons.sword
                              : Icons.shield,
                          size: 20,
                          color: (ref.watch(mapProvider).isAttack)
                              ? Colors.redAccent
                              : Colors.blueAccent,
                        ),
                        Text(
                          (ref.watch(mapProvider).isAttack)
                              ? "Attack"
                              : "Defense",
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                        )
                      ],
                    )),
              )
            ],
          ),
        ),
      ),
    );
  }
}
