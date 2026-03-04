import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/team_provider.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';

class AbiilityBar extends ConsumerWidget {
  const AbiilityBar({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(abilityBarProvider) == null) //
      return const SizedBox.shrink();
    log("Building ability bar");
    final mapScale = Maps.mapScale[ref.watch(mapProvider).currentMap] ?? 1;

    AgentData activeAgent = ref.watch(abilityBarProvider)!;
    return Container(
      width: 90,
      height: (activeAgent.abilities.length * 71),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          stops: const [0.0, 0.75, 1.0],
          colors: [
            Settings.tacticalVioletTheme.card,
            Settings.tacticalVioletTheme.card,
            Color.lerp(Settings.tacticalVioletTheme.card, Colors.black, 0.5)!,
          ],
        ),
        borderRadius: const BorderRadius.horizontal(
          left: Radius.circular(24),
        ),
        border: Border(
          left: BorderSide(
            strokeAlign: BorderSide.strokeAlignOutside,
            color: Settings.tacticalVioletTheme.border,
            width: 1,
          ),
          top: BorderSide(
            strokeAlign: BorderSide.strokeAlignOutside,
            color: Settings.tacticalVioletTheme.border,
            width: 1,
          ),
          bottom: BorderSide(
            strokeAlign: BorderSide.strokeAlignOutside,
            color: Settings.tacticalVioletTheme.border,
            width: 1,
          ),
        ),
        boxShadow: const [
          Settings.cardForegroundBackdrop,
          

        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Agent bar
          ...List.generate(
            activeAgent.abilities.length,
            (index) {
              return Draggable<AbilityInfo>(
                data: activeAgent.abilities[index],
                onDragStarted: () {
                  if (ref.read(interactionStateProvider) ==
                          InteractionState.drawing ||
                      ref.read(interactionStateProvider) ==
                          InteractionState.erasing) {
                    ref
                        .read(interactionStateProvider.notifier)
                        .update(InteractionState.navigation);
                  }
                },
                dragAnchorStrategy: (draggable, context, position) {
                  final info = draggable.data as AbilityInfo;

                  double scaleFactor = CoordinateSystem.instance.scaleFactor *
                      ref.read(screenZoomProvider);

                  double abilitySize =
                      ref.read(strategySettingsProvider).abilitySize;

                  log("info.abilityData: $abilitySize");
                  return info.abilityData!
                      .getAnchorPoint(
                          mapScale: mapScale, abilitySize: abilitySize)
                      .scale(scaleFactor, scaleFactor);
                },
                feedback: Opacity(
                  opacity: Settings.feedbackOpacity,
                  child: ZoomTransform(
                    child:
                        activeAgent.abilities[index].abilityData!.createWidget(
                      id: null,
                      isAlly: ref.watch(teamProvider),
                      mapScale: mapScale,
                    ),
                  ),
                ),

                // dragAnchorStrategy: centerDragStrategy,
                child: InkWell(
                  mouseCursor: SystemMouseCursors.click,
                  onTap: () {},
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: SizedBox(
                      height: 55,
                      width: 55,
                      child: Image.asset(activeAgent.abilities[index].iconPath),
                    ),
                  ),
                ),
                onDraggableCanceled: (velocity, offset) {
                  // log("I oops");
                },
              );
            },
          )
        ],
      ),
    );
  }
}
