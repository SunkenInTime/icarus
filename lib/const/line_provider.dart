import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'dart:ui';

enum PlacingType { agent, ability }

const _noChange = Object();

class LineUp extends HiveObject {
  final String id;
  final PlacedAgent agent;
  final PlacedAbility ability;
  final String youtubeLink;
  final List<String> imageIDs;

  LineUp({
    required this.id,
    required this.agent,
    required this.ability,
    required this.youtubeLink,
    required this.imageIDs,
  });

  LineUp copyWith({
    String? id,
    PlacedAgent? agent,
    PlacedAbility? ability,
    String? youtubeLink,
    List<String>? imageIDs,
  }) {
    return LineUp(
      id: id ?? this.id,
      agent: agent ?? this.agent,
      ability: ability ?? this.ability,
      youtubeLink: youtubeLink ?? this.youtubeLink,
      imageIDs: imageIDs ?? List<String>.from(this.imageIDs),
    );
  }
}

class LineUpState {
  final List<LineUp> lineUps;
  final PlacedAgent? currentAgent;
  final PlacedAbility? currentAbility;
  final String? currentYoutubeLink;
  final List<String>? currentImageIDs;
  final bool isSelectingPosition;
  final PlacingType? placingType;

  LineUpState({
    this.currentAgent,
    this.currentAbility,
    this.currentYoutubeLink,
    this.currentImageIDs,
    required this.lineUps,
    this.isSelectingPosition = false,
    this.placingType,
  });

  LineUpState copyWith({
    List<LineUp>? lineUps,
    Object? currentAgent = _noChange,
    Object? currentAbility = _noChange,
    Object? currentYoutubeLink = _noChange,
    Object? currentImageIDs = _noChange,
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
      currentYoutubeLink: identical(currentYoutubeLink, _noChange)
          ? this.currentYoutubeLink
          : currentYoutubeLink as String?,
      currentImageIDs: identical(currentImageIDs, _noChange)
          ? (this.currentImageIDs != null
              ? List<String>.from(this.currentImageIDs!)
              : null)
          : (currentImageIDs as List<String>?),
      isSelectingPosition: isSelectingPosition ?? this.isSelectingPosition,
      placingType: placingType ?? this.placingType,
    );
  }
}

class LineUpProvider extends Notifier<LineUpState> {
  AgentType tempAgent = AgentType.brimstone;
  @override
  LineUpState build() {
    return LineUpState(lineUps: []);
  }

  void addLineUp(LineUp lineUp) {
    state = state.copyWith(
      lineUps: [...state.lineUps, lineUp],
    );
  }

  void setAgent(PlacedAgent agent) {
    state = state.copyWith(currentAbility: null);
    state = state.copyWith(currentAgent: agent, currentAbility: null);
  }

  void setAbility(PlacedAbility ability) {
    if (state.currentAgent == null) return;
    state = state.copyWith(currentAbility: ability);
  }

  void setYoutubeLink(String youtubeLink) {
    if (state.currentAgent == null) return;
    state = state.copyWith(currentYoutubeLink: youtubeLink);
  }

  void setImageIDs(List<String> imageIDs) {
    if (state.currentAgent == null) return;
    state = state.copyWith(currentImageIDs: imageIDs);
  }

  void setSelectingPosition(bool isSelecting, {PlacingType? type}) {
    state = state.copyWith(
      isSelectingPosition: isSelecting,
      placingType: type,
    );
  }

  void updatePosition(Offset position) {
    if (state.placingType == PlacingType.agent && state.currentAgent != null) {
      state.currentAgent!.position = position;
      // Force state update to notify listeners
      state = state.copyWith(currentAgent: state.currentAgent);
    } else if (state.placingType == PlacingType.ability &&
        state.currentAbility != null) {
      state.currentAbility!.position = position;
      // Force state update to notify listeners
      state = state.copyWith(currentAbility: state.currentAbility);
    }
    setSelectingPosition(false);
  }

  void removeLineUp(String id) {
    // state = state.where((lineUp) => lineUp.id != id).toList();
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
