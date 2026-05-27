import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'dart:ui';

import 'package:json_annotation/json_annotation.dart';

part "line_provider.g.dart";

enum PlacingType { agent, ability }

const _noChange = Object();

@JsonSerializable()
class LineUp extends HiveObject {
  final String id;
  final PlacedAgent agent;
  final PlacedAbility ability;
  final String youtubeLink;
  final String notes;
  final List<SimpleImageData> images;

  LineUp({
    required this.id,
    required this.agent,
    required this.ability,
    required this.youtubeLink,
    required this.images,
    required this.notes,
  });

  LineUp copyWith({
    String? id,
    PlacedAgent? agent,
    PlacedAbility? ability,
    String? youtubeLink,
    List<SimpleImageData>? images,
    String? notes,
  }) {
    return LineUp(
      id: id ?? this.id,
      agent: agent ?? this.agent,
      ability: ability ?? this.ability,
      youtubeLink: youtubeLink ?? this.youtubeLink,
      images: images ?? List<SimpleImageData>.from(this.images),
      notes: notes ?? this.notes,
    );
  }

  void switchSides(
      {required double agentSize,
      required double abilitySize,
      required double mapScale}) {
    agent.switchSides(agentSize);
    ability.switchSides(mapScale: mapScale, abilitySize: abilitySize);
  }

  factory LineUp.fromJson(Map<String, dynamic> json) => _$LineUpFromJson(json);

  Map<String, dynamic> toJson() => _$LineUpToJson(this);
}

@JsonSerializable()
class SimpleImageData extends HiveObject {
  final String id;
  final String fileExtension;

  SimpleImageData({
    required this.id,
    required this.fileExtension,
  });

  SimpleImageData copyWith({
    String? id,
    String? fileExtension,
  }) {
    return SimpleImageData(
      id: id ?? this.id,
      fileExtension: fileExtension ?? this.fileExtension,
    );
  }

  factory SimpleImageData.fromJson(Map<String, dynamic> json) =>
      _$SimpleImageDataFromJson(json);

  Map<String, dynamic> toJson() => _$SimpleImageDataToJson(this);
}

class LineUpState {
  final List<LineUp> lineUps;
  final PlacedAgent? currentAgent;
  final PlacedAbility? currentAbility;
  // final String? currentYoutubeLink;
  final bool isSelectingPosition;

  LineUpState({
    this.currentAgent,
    this.currentAbility,
    // this.currentYoutubeLink,
    required this.lineUps,
    this.isSelectingPosition = false,
  });

  LineUpState copyWith({
    List<LineUp>? lineUps,
    Object? currentAgent = _noChange,
    Object? currentAbility = _noChange,
    Object? currentYoutubeLink = _noChange,
    bool? isSelectingPosition,
    PlacingType? placingType,
  }) {
    return LineUpState(
      lineUps: lineUps ?? List<LineUp>.from(this.lineUps),
      currentAgent: identical(currentAgent, _noChange)
          ? this.currentAgent
          : currentAgent as PlacedAgent?,
      currentAbility: identical(currentAbility, _noChange)
          ? this.currentAbility
          : currentAbility as PlacedAbility?,
      // currentYoutubeLink: identical(currentYoutubeLink, _noChange)
      //     ? this.currentYoutubeLink
      //     : currentYoutubeLink as String?,
      isSelectingPosition: isSelectingPosition ?? this.isSelectingPosition,
    );
  }
}

class LineUpProviderSnapshot {
  final List<LineUp> lineUps;
  final List<LineUp> poppedLineUps;

  const LineUpProviderSnapshot({
    required this.lineUps,
    required this.poppedLineUps,
  });
}

class LineUpProvider extends Notifier<LineUpState> {
  final List<LineUp> _poppedLineUps = [];
  @override
  LineUpState build() {
    return LineUpState(lineUps: []);
  }

  void addLineUp(LineUp lineUp) {
    final action = UserAction(
      type: ActionType.addition,
      id: lineUp.id,
      group: ActionGroup.lineUp,
      objectDelta: ObjectHistoryDelta(
        after: ActionObjectState.lineUp(lineUp),
      ),
    );
    ref.read(actionProvider.notifier).addAction(action);

    state = state.copyWith(
      lineUps: [...state.lineUps, lineUp],
    );
  }

  void setAgent(PlacedAgent agent) {
    state = state.copyWith(currentAgent: agent, currentAbility: null);
  }

  void setAbility(PlacedAbility ability) {
    if (state.currentAgent == null) {
      Settings.showToast(
        message: "Please select an agent first.",
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }

    if (ability.data.type == state.currentAgent!.type) {
      state = state.copyWith(currentAbility: ability);
    } else {
      Settings.showToast(
        message: "Ability does not match the selected agent.",
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    }
  }

  void switchSides() {
    final agentSize = ref.read(strategySettingsProvider).agentSize;
    final abilitySize = ref.read(strategySettingsProvider).abilitySize;
    final currentMap = ref.read(mapProvider).currentMap;
    final mapScale = Maps.mapScale[currentMap] ?? 1.0;
    final newState = [...state.lineUps];
    final currentAgent = state.currentAgent;
    final currentAbility = state.currentAbility;

    for (final lineUp in newState) {
      lineUp.switchSides(
          agentSize: agentSize, abilitySize: abilitySize, mapScale: mapScale);
    }

    for (final lineUp in _poppedLineUps) {
      lineUp.switchSides(
          agentSize: agentSize, abilitySize: abilitySize, mapScale: mapScale);
    }

    currentAgent?.switchSides(agentSize);
    currentAbility?.switchSides(
      mapScale: mapScale,
      abilitySize: abilitySize,
    );

    state = state.copyWith(
      lineUps: newState,
      currentAgent: currentAgent,
      currentAbility: currentAbility,
    );
  }

  void setSelectingPosition(bool isSelecting, {PlacingType? type}) {
    state = state.copyWith(
      isSelectingPosition: isSelecting,
      placingType: type,
    );
  }

  void clearCurrentPlacing() {
    state = state.copyWith(
      currentAgent: null,
      currentAbility: null,
      currentYoutubeLink: null,
      isSelectingPosition: false,
    );
  }

  void removeCurrentAbility() {
    state = state.copyWith(currentAbility: null);
  }

  void updateAgentPosition(Offset position) {
    if (state.currentAgent != null) {
      final updatedAgent = state.currentAgent!..updatePosition(position);
      state = state.copyWith(currentAgent: updatedAgent);
    }
  }

  void updateAbilityPosition(Offset position) {
    if (state.currentAbility != null) {
      final updatedAbility = state.currentAbility!..updatePosition(position);
      state = state.copyWith(currentAbility: updatedAbility);
    }
  }

  void updateRotation(double rotation, double length) {
    updateGeometry(rotation: rotation, length: length);
  }

  void updateGeometry({
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
  }) {
    if (state.currentAbility != null) {
      final updatedAbility = state.currentAbility!.copyWith(
        rotation: rotation,
        length: length,
        armLengthsMeters: armLengthsMeters,
      );

      state = state.copyWith(currentAbility: updatedAbility);
    }
  }

  void updateArmLengths(List<double> armLengthsMeters) {
    updateGeometry(armLengthsMeters: armLengthsMeters);
  }
  //Have a hover glow on what agent is selectabel in the sidebar list

  void fromHive(List<LineUp> lineUps) {
    state = state.copyWith(
      lineUps: lineUps,
    );
  }

  static String objectToJson(List<LineUp> lineUps) {
    return jsonEncode(lineUps.map((lineUp) => lineUp.toJson()).toList());
  }

  static List<LineUp> fromJson(String json) {
    return (jsonDecode(json) as List<dynamic>)
        .map((e) => LineUp.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  void updateLineUp(LineUp lineUp) {
    final index = getIndexById(lineUp.id);
    final newState = [...state.lineUps];

    newState[index] = lineUp;
    state = state.copyWith(
      lineUps: newState,
    );
  }

  void updateAbilityVisualState(
    String lineUpId,
    AbilityVisualState visualState,
  ) {
    final lineUp = getLineUpById(lineUpId);
    if (lineUp == null) {
      return;
    }

    updateLineUp(
      lineUp.copyWith(
        ability: lineUp.ability.copyWith(visualState: visualState),
      ),
    );
  }

  int getIndexById(String id) {
    return state.lineUps.indexWhere((lineUp) => lineUp.id == id);
  }

  LineUp? getLineUpById(String id) {
    return state.lineUps.firstWhere((lineUp) => lineUp.id == id);
  }

  void deleteLineUpById(String id) {
    //Although this is technically not starndard with the way
    //Deletetions are handled by the other providers/widgets
    //This is because the only way to delete a line up is through
    //the right click menu, and not through the delete key.

    final action = UserAction(
      type: ActionType.deletion,
      id: id,
      group: ActionGroup.lineUp,
      objectDelta: ObjectHistoryDelta(
        before: ActionObjectState.lineUp(
          state.lineUps.firstWhere((lineUp) => lineUp.id == id),
        ),
      ),
    );
    ref.read(actionProvider.notifier).addAction(action);
    _poppedLineUps.removeWhere((lineUp) => lineUp.id == id);
    _poppedLineUps.add(
      cloneLineUp(state.lineUps.firstWhere((lineUp) => lineUp.id == id)),
    );

    state = state.copyWith(
      lineUps: state.lineUps.where((lineUp) => lineUp.id != id).toList(),
    );
  }

  void undoAction(UserAction action) {
    final delta = action.objectDelta;
    if (delta == null) {
      switch (action.type) {
        case ActionType.addition:
          deleteLineUpById(action.id);
          return;
        case ActionType.deletion:
          if (_poppedLineUps.isEmpty) return;
          _upsertLineUp(cloneLineUp(_poppedLineUps.removeLast()));
          return;
        case ActionType.edit:
        case ActionType.bulkDeletion:
        case ActionType.transaction:
          return;
      }
    }
    switch (action.type) {
      case ActionType.addition:
        deleteLineUpById(action.id);
        return;
      case ActionType.deletion:
        final before = delta.before?.lineUp;
        if (before == null) return;
        _upsertLineUp(cloneLineUp(before));
        return;
      case ActionType.edit:
      //Do nothing
      case ActionType.bulkDeletion:
      case ActionType.transaction:
        return;
    }
  }

  void redoAction(UserAction action) {
    final delta = action.objectDelta;
    if (delta == null) {
      switch (action.type) {
        case ActionType.addition:
          if (_poppedLineUps.isEmpty) return;
          _upsertLineUp(cloneLineUp(_poppedLineUps.removeLast()));
          return;
        case ActionType.deletion:
          final existing = state.lineUps.where((lineUp) => lineUp.id == action.id);
          if (existing.isEmpty) return;
          _poppedLineUps.removeWhere((lineUp) => lineUp.id == action.id);
          _poppedLineUps.add(cloneLineUp(existing.first));
          state = state.copyWith(
            lineUps:
                state.lineUps.where((lineUp) => lineUp.id != action.id).toList(),
          );
          return;
        case ActionType.edit:
        case ActionType.bulkDeletion:
        case ActionType.transaction:
          return;
      }
    }
    switch (action.type) {
      case ActionType.addition:
        final after = delta.after?.lineUp;
        if (after == null) return;
        _upsertLineUp(cloneLineUp(after));
        return;
      case ActionType.deletion:
        final existing = state.lineUps.where((lineUp) => lineUp.id == action.id);
        if (existing.isEmpty) return;
        _poppedLineUps.removeWhere((lineUp) => lineUp.id == action.id);
        _poppedLineUps.add(cloneLineUp(existing.first));
        state = state.copyWith(
          lineUps:
              state.lineUps.where((lineUp) => lineUp.id != action.id).toList(),
        );
        return;
      case ActionType.edit:
      //Do nothing
      case ActionType.bulkDeletion:
      case ActionType.transaction:
        return;
    }
  }

  void clearAll() {
    _poppedLineUps.clear();
    state = state.copyWith(lineUps: []);
  }

  LineUpProviderSnapshot takeSnapshot() {
    return LineUpProviderSnapshot(
      lineUps: state.lineUps.map((lineUp) => cloneLineUp(lineUp)).toList(),
      poppedLineUps: _poppedLineUps.map((lineUp) => cloneLineUp(lineUp)).toList(),
    );
  }

  void restoreSnapshot(LineUpProviderSnapshot snapshot) {
    _poppedLineUps
      ..clear()
      ..addAll(snapshot.poppedLineUps.map((lineUp) => cloneLineUp(lineUp)));
    state = state.copyWith(
      lineUps: snapshot.lineUps.map((lineUp) => cloneLineUp(lineUp)).toList(),
    );
  }

  void _upsertLineUp(LineUp lineUp) {
    final newState = [...state.lineUps];
    final index = newState.indexWhere((existing) => existing.id == lineUp.id);
    if (index < 0) {
      newState.add(lineUp);
    } else {
      newState[index] = lineUp;
    }
    state = state.copyWith(lineUps: newState);
  }
}

final lineUpProvider =
    NotifierProvider<LineUpProvider, LineUpState>(LineUpProvider.new);

class HoveredLineUpProvider extends Notifier<String?> {
  @override
  String? build() {
    return null;
  }

  void setHoveredLineUpId(String? id) {
    state = id;
  }
}

/// Tracks which LineUp is currently hovered for unified highlight.
final hoveredLineUpIdProvider =
    NotifierProvider<HoveredLineUpProvider, String?>(HoveredLineUpProvider.new);
