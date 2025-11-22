import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/placed_classes.dart';

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

  LineUpState({
    this.currentAgent,
    this.currentAbility,
    this.currentYoutubeLink,
    this.currentImageIDs,
    required this.lineUps,
  });

  LineUpState copyWith({
    List<LineUp>? lineUps,
    PlacedAgent? currentAgent,
    PlacedAbility? currentAbility,
    String? currentYoutubeLink,
    List<String>? currentImageIDs,
  }) {
    return LineUpState(
      lineUps: lineUps ?? List<LineUp>.from(this.lineUps),
      currentAgent: currentAgent ?? this.currentAgent,
      currentAbility: currentAbility ?? this.currentAbility,
      currentYoutubeLink: currentYoutubeLink ?? this.currentYoutubeLink,
      currentImageIDs: currentImageIDs ??
          (this.currentImageIDs != null
              ? List<String>.from(this.currentImageIDs!)
              : null),
    );
  }
}

class LineUpProvider extends Notifier<LineUpState> {
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
    state = state.copyWith(currentAgent: agent);
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

  void removeLineUp(String id) {
    // state = state.where((lineUp) => lineUp.id != id).toList();
  }
}
