import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'dart:ui';

import 'package:icarus/providers/interaction_state_provider.dart';

enum PlacingType { agent, ability }

const _noChange = Object();

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
}

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
    state = state.copyWith(currentAgent: agent, currentAbility: null);
  }

  void setAbility(PlacedAbility ability) {
    //TODO: Evaluate if this check is  UX friendly
    if (state.currentAgent == null) return;

    if (ability.data.type == state.currentAgent!.type) {
      state = state.copyWith(currentAbility: ability);
    } else {
      throw Exception("Ability type does not match the current agent type");
    }
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

  void clearCurrentPlacing() {
    state = state.copyWith(
      currentAgent: null,
      currentAbility: null,
      currentYoutubeLink: null,
      currentImageIDs: null,
      isSelectingPosition: false,
      placingType: null,
    );
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
    if (state.currentAbility != null) {
      final updatedAbility = state.currentAbility!
        ..updateRotation(rotation, length);
      state = state.copyWith(currentAbility: updatedAbility);
    }
  }
  //Have a hover glow on what agent is selectabel in the sidebar list

  void removeLineUp(String id) {
    // state = state.where((lineUp) => lineUp.id != id).toList();
  }

  int getIndexById(String id) {
    return state.lineUps.indexWhere((lineUp) => lineUp.id == id);
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
