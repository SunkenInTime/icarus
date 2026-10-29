import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/widgets/canvas_coordinates.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';

/// Items on the editor's canvas drawn somewhere other than where their saved
/// positions put them on that canvas, one line each.
///
/// Covers placed agents and both ends of every lineup, the items users saw
/// drift away from their lines in #405. Where an item is drawn is the spot
/// the canvas built it at; where it belongs is worked out from the canvas's
/// own size, not from the shared coordinates the canvas drew with, so a
/// canvas drawing with the wrong coordinates shows up here. Empty when no
/// editor canvas is on screen, or while a page transition moves items.
List<String> misplacedItems(ProviderContainer container) {
  final canvas = CanvasCoordinates.onScreen
      .where((canvas) => canvas.widget is InteractiveMap)
      .firstOrNull;
  final playArea = canvas?.laidOutPlayArea;
  if (canvas == null || playArea == null) return const [];
  if (container.read(transitionProvider).active) return const [];

  final coordinates = CoordinateSystem.forSize(playArea);
  final map = container.read(mapProvider);
  final settings = container.read(strategySettingsProvider);
  final mapScale = Maps.mapScale[map.currentMap] ?? 1.0;
  final lineUps = container.read(lineUpProvider);
  // The same calls the canvas makes for each, keyed by the Positioned the
  // canvas builds the item in.
  final belongs = <Key, (String, Offset)>{
    for (final agent in container.read(agentProvider))
      ValueKey<String>(agent.id): (
        agent.id,
        screenPositionForWidget(
          widget: agent,
          coordinateSystem: coordinates,
          agentSize: settings.agentSize,
          isAttack: map.isAttack,
        ),
      ),
    for (final origin in lineUps.origins)
      ValueKey<String>('lineup-agent-${origin.id}'): (
        origin.id,
        screenPositionForWidget(
          widget: origin.agent,
          coordinateSystem: coordinates,
          agentSize: settings.agentSize,
          isAttack: map.isAttack,
        ),
      ),
    for (final landing in lineUps.landings)
      ValueKey<String>('lineup-ability-${landing.id}'): (
        landing.id,
        screenPositionForWidget(
          widget: landing.ability,
          coordinateSystem: coordinates,
          mapScale: mapScale,
          abilitySize: settings.abilitySize,
          isAttack: map.isAttack,
        ),
      ),
  };

  final misplaced = <String>[];
  void visit(Element element) {
    final widget = element.widget;
    if (widget is Positioned) {
      final entry = belongs[widget.key];
      final left = widget.left;
      final top = widget.top;
      if (entry != null && left != null && top != null) {
        final (id, at) = entry;
        final drawn = Offset(left, top);
        if ((drawn - at).distance > 0.5) {
          misplaced.add(
            '$id drawn at ${_offset(drawn)}, '
            'its saved position puts it at ${_offset(at)}',
          );
        }
      }
    }
    element.visitChildElements(visit);
  }

  // Only the placed items: the page transition overlay builds its own
  // Positioned copies under the same keys.
  void findItems(Element element) {
    if (element.widget is PlacedWidgetBuilder) {
      element.visitChildElements(visit);
      return;
    }
    element.visitChildElements(findItems);
  }

  canvas.context.visitChildElements(findItems);
  return misplaced;
}

String _offset(Offset offset) =>
    '(${offset.dx.toStringAsFixed(1)}, ${offset.dy.toStringAsFixed(1)})';
