import 'dart:convert';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:json_annotation/json_annotation.dart';

part "line_provider.g.dart";

enum PlacingType { agent, ability }

enum LineUpPlacementMode { newGroup, addItemToGroup }

const _noChange = Object();

@Deprecated('Use LineUpGroup and LineUpItem instead.')
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

  LineUp deepCopy() {
    return LineUp(
      id: id,
      agent: agent.deepCopy<PlacedAgent>(),
      ability: ability.deepCopy<PlacedAbility>(),
      youtubeLink: youtubeLink,
      images: images.map((image) => image.copyWith()).toList(),
      notes: notes,
    );
  }

  void switchSides({
    required double agentSize,
    required double abilitySize,
    required double mapScale,
  }) {
    agent.switchSides(agentSize);
    ability.switchSides(mapScale: mapScale, abilitySize: abilitySize);
  }

  factory LineUp.fromJson(Map<String, dynamic> json) => _$LineUpFromJson(json);

  Map<String, dynamic> toJson() => _$LineUpToJson(this);
}

@JsonSerializable()
class LineUpItem extends HiveObject {
  final String id;
  final PlacedAbility ability;
  final String youtubeLink;
  final String notes;
  final List<SimpleImageData> images;

  LineUpItem({
    required this.id,
    required this.ability,
    this.youtubeLink = '',
    this.notes = '',
    this.images = const [],
  });

  LineUpItem copyWith({
    String? id,
    PlacedAbility? ability,
    String? youtubeLink,
    String? notes,
    List<SimpleImageData>? images,
  }) {
    return LineUpItem(
      id: id ?? this.id,
      ability: ability ?? this.ability,
      youtubeLink: youtubeLink ?? this.youtubeLink,
      notes: notes ?? this.notes,
      images: images ?? List<SimpleImageData>.from(this.images),
    );
  }

  LineUpItem deepCopy() {
    return LineUpItem(
      id: id,
      ability: ability.deepCopy<PlacedAbility>(),
      youtubeLink: youtubeLink,
      notes: notes,
      images: images.map((image) => image.copyWith()).toList(),
    );
  }

  factory LineUpItem.fromJson(Map<String, dynamic> json) =>
      _$LineUpItemFromJson(json);

  Map<String, dynamic> toJson() => _$LineUpItemToJson(this);
}

@JsonSerializable()
class LineUpGroup extends HiveObject {
  final String id;
  final PlacedAgent agent;
  final List<LineUpItem> items;

  LineUpGroup({
    required this.id,
    required this.agent,
    required this.items,
  });

  LineUpGroup copyWith({
    String? id,
    PlacedAgent? agent,
    List<LineUpItem>? items,
  }) {
    return LineUpGroup(
      id: id ?? this.id,
      agent: agent ?? this.agent,
      items: items ?? List<LineUpItem>.from(this.items),
    );
  }

  LineUpGroup deepCopy() {
    return LineUpGroup(
      id: id,
      agent: agent.deepCopy<PlacedAgent>(),
      items: items.map((item) => item.deepCopy()).toList(),
    );
  }

  void switchSides({
    required double agentSize,
    required double abilitySize,
    required double mapScale,
  }) {
    agent.switchSides(agentSize);
    for (final item in items) {
      item.ability.switchSides(mapScale: mapScale, abilitySize: abilitySize);
    }
  }

  factory LineUpGroup.fromJson(Map<String, dynamic> json) =>
      _$LineUpGroupFromJson(json);

  Map<String, dynamic> toJson() => _$LineUpGroupToJson(this);

  static LineUpGroup fromLegacyLineUp(LineUp legacy) {
    final groupId = legacy.id;
    return LineUpGroup(
      id: groupId,
      agent: legacy.agent.copyWith(lineUpID: groupId),
      items: [
        LineUpItem(
          id: legacy.id,
          ability: legacy.ability.copyWith(lineUpID: groupId),
          youtubeLink: legacy.youtubeLink,
          notes: legacy.notes,
          images: legacy.images.map((image) => image.copyWith()).toList(),
        ),
      ],
    );
  }
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
  final List<LineUpGroup> groups;
  final PlacedAgent? currentAgent;
  final String? currentGroupId;
  final PlacedAbility? currentAbility;
  final bool isSelectingPosition;
  final LineUpPlacementMode? placementMode;
  final AgentType? lockedAgentType;

  LineUpState({
    this.currentAgent,
    this.currentGroupId,
    this.currentAbility,
    List<LineUpGroup> groups = const [],
    @Deprecated('Use groups instead') List<LineUp> lineUps = const [],
    this.isSelectingPosition = false,
    this.placementMode,
    this.lockedAgentType,
  }) : groups = groups.isNotEmpty
            ? groups
            : lineUps.map(LineUpGroup.fromLegacyLineUp).toList();

  @Deprecated('Use groups instead.')
  List<LineUp> get lineUps => [
        for (final group in groups)
          for (final item in group.items)
            LineUp(
              id: item.id,
              agent: group.agent.copyWith(lineUpID: group.id),
              ability: item.ability.copyWith(lineUpID: group.id),
              youtubeLink: item.youtubeLink,
              notes: item.notes,
              images: item.images.map((image) => image.copyWith()).toList(),
            ),
      ];

  LineUpState copyWith({
    List<LineUpGroup>? groups,
    Object? currentAgent = _noChange,
    Object? currentGroupId = _noChange,
    Object? currentAbility = _noChange,
    bool? isSelectingPosition,
    Object? placementMode = _noChange,
    Object? lockedAgentType = _noChange,
  }) {
    return LineUpState(
      groups: groups ?? List<LineUpGroup>.from(this.groups),
      currentAgent: identical(currentAgent, _noChange)
          ? this.currentAgent
          : currentAgent as PlacedAgent?,
      currentGroupId: identical(currentGroupId, _noChange)
          ? this.currentGroupId
          : currentGroupId as String?,
      currentAbility: identical(currentAbility, _noChange)
          ? this.currentAbility
          : currentAbility as PlacedAbility?,
      isSelectingPosition: isSelectingPosition ?? this.isSelectingPosition,
      placementMode: identical(placementMode, _noChange)
          ? this.placementMode
          : placementMode as LineUpPlacementMode?,
      lockedAgentType: identical(lockedAgentType, _noChange)
          ? this.lockedAgentType
          : lockedAgentType as AgentType?,
    );
  }
}

class LineUpProviderSnapshot {
  final List<LineUpGroup> groups;
  final List<LineUpGroup> poppedGroups;

  const LineUpProviderSnapshot({
    required this.groups,
    required this.poppedGroups,
  });
}

class LineUpProvider extends Notifier<LineUpState> {
  final List<LineUpGroup> _poppedGroups = [];

  @override
  LineUpState build() {
    return LineUpState(groups: []);
  }

  void addGroup(LineUpGroup group) {
    final action = UserAction(
      type: ActionType.addition,
      id: group.id,
      group: ActionGroup.lineUp,
    );
    ref.read(actionProvider.notifier).addAction(action);
    state = state.copyWith(groups: [...state.groups, group.deepCopy()]);
  }

  void updateGroup(LineUpGroup group) {
    final index = getGroupIndexById(group.id);
    if (index < 0) return;
    final groups = [...state.groups];
    groups[index] = group;
    state = state.copyWith(groups: groups);
  }

  void deleteGroupById(String groupId) {
    final index = getGroupIndexById(groupId);
    if (index < 0) return;

    ref.read(actionProvider.notifier).addAction(
          UserAction(
            type: ActionType.deletion,
            id: groupId,
            group: ActionGroup.lineUp,
          ),
        );

    final groups = [...state.groups];
    _poppedGroups.add(groups.removeAt(index));
    state = state.copyWith(groups: groups);
  }

  LineUpGroup? getGroupById(String groupId) {
    final index = getGroupIndexById(groupId);
    if (index < 0) return null;
    return state.groups[index];
  }

  int getGroupIndexById(String groupId) {
    return state.groups.indexWhere((group) => group.id == groupId);
  }

  void addItemToGroup({
    required String groupId,
    required LineUpItem item,
  }) {
    final group = getGroupById(groupId);
    if (group == null) return;
    updateGroup(group.copyWith(items: [...group.items, item]));
  }

  void updateItem({
    required String groupId,
    required LineUpItem item,
  }) {
    final group = getGroupById(groupId);
    if (group == null) return;
    final items = [...group.items];
    final index = items.indexWhere((entry) => entry.id == item.id);
    if (index < 0) return;
    items[index] = item;
    updateGroup(group.copyWith(items: items));
  }

  void deleteItem({
    required String groupId,
    required String itemId,
  }) {
    final group = getGroupById(groupId);
    if (group == null) return;
    final items = group.items.where((item) => item.id != itemId).toList();
    if (items.isEmpty) {
      deleteGroupById(groupId);
      return;
    }
    updateGroup(group.copyWith(items: items));
  }

  LineUpItem? getItemById({
    required String groupId,
    required String itemId,
  }) {
    final group = getGroupById(groupId);
    if (group == null) return null;
    for (final item in group.items) {
      if (item.id == itemId) {
        return item;
      }
    }
    return null;
  }

  @Deprecated('Use getGroupById/getItemById instead.')
  LineUp? getLineUpById(String id) {
    for (final group in state.groups) {
      for (final item in group.items) {
        if (item.id == id) {
          return LineUp(
            id: item.id,
            agent: group.agent.copyWith(lineUpID: group.id),
            ability: item.ability.copyWith(lineUpID: group.id),
            youtubeLink: item.youtubeLink,
            notes: item.notes,
            images: item.images.map((image) => image.copyWith()).toList(),
          );
        }
      }
    }
    return null;
  }

  void startNewGroup(PlacedAgent agent) {
    state = state.copyWith(
      currentAgent: agent,
      currentGroupId: null,
      currentAbility: null,
      placementMode: LineUpPlacementMode.newGroup,
      lockedAgentType: null,
    );
  }

  @Deprecated('Use startNewGroup instead.')
  void setAgent(PlacedAgent agent) {
    startNewGroup(agent);
  }

  void startNewItemForGroup(String groupId) {
    final group = getGroupById(groupId);
    if (group == null) return;
    state = state.copyWith(
      currentAgent: null,
      currentGroupId: groupId,
      currentAbility: null,
      placementMode: LineUpPlacementMode.addItemToGroup,
      lockedAgentType: group.agent.type,
    );
  }

  AgentType? getActiveAgentType() {
    return state.currentAgent?.type ?? state.lockedAgentType;
  }

  PlacedAgent? getCurrentPreviewAgent() {
    if (state.currentAgent != null) {
      return state.currentAgent;
    }

    final groupId = state.currentGroupId;
    if (groupId == null) return null;
    return getGroupById(groupId)?.agent;
  }

  bool get isLockedAddItemMode =>
      state.placementMode == LineUpPlacementMode.addItemToGroup &&
      state.currentGroupId != null;

  void setCurrentAbility(PlacedAbility ability) {
    final agentType = getActiveAgentType();
    if (agentType == null) {
      Settings.showToast(
        message: "Please select an agent first.",
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }

    if (ability.data.type != agentType) {
      Settings.showToast(
        message: "Ability does not match the selected agent.",
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }

    final groupId = state.currentGroupId;
    state = state.copyWith(
      currentAbility:
          groupId == null ? ability : ability.copyWith(lineUpID: groupId),
    );
  }

  @Deprecated('Use setCurrentAbility instead.')
  void setAbility(PlacedAbility ability) {
    setCurrentAbility(ability);
  }

  void switchSides() {
    final agentSize = ref.read(strategySettingsProvider).agentSize;
    final abilitySize = ref.read(strategySettingsProvider).abilitySize;
    final currentMap = ref.read(mapProvider).currentMap;
    final mapScale = Maps.mapScale[currentMap] ?? 1.0;
    final groups = [...state.groups];

    for (final group in groups) {
      group.switchSides(
        agentSize: agentSize,
        abilitySize: abilitySize,
        mapScale: mapScale,
      );
    }

    for (final group in _poppedGroups) {
      group.switchSides(
        agentSize: agentSize,
        abilitySize: abilitySize,
        mapScale: mapScale,
      );
    }

    final currentAgent = state.currentAgent;
    final currentAbility = state.currentAbility;
    currentAgent?.switchSides(agentSize);
    currentAbility?.switchSides(mapScale: mapScale, abilitySize: abilitySize);

    state = state.copyWith(
      groups: groups,
      currentAgent: currentAgent,
      currentAbility: currentAbility,
    );
  }

  void setSelectingPosition(bool isSelecting, {PlacingType? type}) {
    state = state.copyWith(
      isSelectingPosition: isSelecting,
    );
  }

  void clearCurrentPlacing() {
    state = state.copyWith(
      currentAgent: null,
      currentGroupId: null,
      currentAbility: null,
      isSelectingPosition: false,
      placementMode: null,
      lockedAgentType: null,
    );
  }

  void removeCurrentAbility() {
    state = state.copyWith(currentAbility: null);
  }

  void updateCurrentAgentPosition(Offset position) {
    if (state.currentAgent == null) return;
    final updatedAgent = state.currentAgent!..updatePosition(position);
    state = state.copyWith(currentAgent: updatedAgent);
  }

  @Deprecated('Use updateCurrentAgentPosition instead.')
  void updateAgentPosition(Offset position) {
    updateCurrentAgentPosition(position);
  }

  void updateCurrentAbilityPosition(Offset position) {
    if (state.currentAbility == null) return;
    final updatedAbility = state.currentAbility!..updatePosition(position);
    state = state.copyWith(currentAbility: updatedAbility);
  }

  @Deprecated('Use updateCurrentAbilityPosition instead.')
  void updateAbilityPosition(Offset position) {
    updateCurrentAbilityPosition(position);
  }

  void updateRotation(double rotation, double length) {
    updateCurrentAbilityGeometry(rotation: rotation, length: length);
  }

  void updateCurrentAbilityGeometry({
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
  }) {
    if (state.currentAbility == null) return;
    state = state.copyWith(
      currentAbility: state.currentAbility!.copyWith(
        rotation: rotation,
        length: length,
        armLengthsMeters: armLengthsMeters,
      ),
    );
  }

  @Deprecated('Use updateCurrentAbilityGeometry instead.')
  void updateGeometry({
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
  }) {
    updateCurrentAbilityGeometry(
      rotation: rotation,
      length: length,
      armLengthsMeters: armLengthsMeters,
    );
  }

  void updateArmLengths(List<double> armLengthsMeters) {
    updateCurrentAbilityGeometry(armLengthsMeters: armLengthsMeters);
  }

  void fromHive(covariant List groups) {
    final normalized = <LineUpGroup>[];
    for (final entry in groups) {
      if (entry is LineUpGroup) {
        normalized.add(entry.deepCopy());
      } else if (entry is LineUp) {
        normalized.add(LineUpGroup.fromLegacyLineUp(entry));
      }
    }
    state = state.copyWith(groups: normalized);
  }

  static String objectToJson(List groups) {
    return jsonEncode(
      groups.map((group) {
        if (group is LineUpGroup) {
          return group.toJson();
        }
        if (group is LineUp) {
          return LineUpGroup.fromLegacyLineUp(group).toJson();
        }
        return group;
      }).toList(),
    );
  }

  static List<LineUpGroup> fromJson(String json) {
    return (jsonDecode(json) as List<dynamic>)
        .map((entry) => LineUpGroup.fromJson(entry as Map<String, dynamic>))
        .toList();
  }

  static List<LineUpGroup> fromLegacyJson(String json) {
    return (jsonDecode(json) as List<dynamic>)
        .map((entry) => LineUp.fromJson(entry as Map<String, dynamic>))
        .map(LineUpGroup.fromLegacyLineUp)
        .toList();
  }

  void updateAbilityVisualState(
      String legacyLineUpId, AbilityVisualState visualState) {
    for (final group in state.groups) {
      for (final item in group.items) {
        if (item.id == legacyLineUpId) {
          updateItemAbilityVisualState(
            groupId: group.id,
            itemId: item.id,
            visualState: visualState,
          );
          return;
        }
      }
    }
  }

  void updateItemAbilityVisualState({
    required String groupId,
    required String itemId,
    required AbilityVisualState visualState,
  }) {
    final item = getItemById(groupId: groupId, itemId: itemId);
    if (item == null) return;
    updateItem(
      groupId: groupId,
      item: item.copyWith(
        ability: item.ability.copyWith(visualState: visualState),
      ),
    );
  }

  @Deprecated('Use deleteGroupById instead.')
  void deleteLineUpById(String groupId) {
    deleteGroupById(groupId);
  }

  void undoAction(UserAction action) {
    switch (action.type) {
      case ActionType.addition:
        final groups = [...state.groups];
        final index = groups.indexWhere((group) => group.id == action.id);
        if (index < 0) return;
        _poppedGroups.add(groups.removeAt(index));
        state = state.copyWith(groups: groups);
        return;
      case ActionType.deletion:
        final index =
            _poppedGroups.indexWhere((group) => group.id == action.id);
        if (index < 0) return;
        state = state.copyWith(
          groups: [...state.groups, _poppedGroups.removeAt(index)],
        );
        return;
      case ActionType.edit:
      case ActionType.bulkDeletion:
      case ActionType.transaction:
        return;
    }
  }

  void redoAction(UserAction action) {
    switch (action.type) {
      case ActionType.addition:
        final index =
            _poppedGroups.indexWhere((group) => group.id == action.id);
        if (index < 0) return;
        state = state.copyWith(
          groups: [...state.groups, _poppedGroups.removeAt(index)],
        );
        return;
      case ActionType.deletion:
        final groups = [...state.groups];
        final index = groups.indexWhere((group) => group.id == action.id);
        if (index < 0) return;
        _poppedGroups.add(groups.removeAt(index));
        state = state.copyWith(groups: groups);
        return;
      case ActionType.edit:
      case ActionType.bulkDeletion:
      case ActionType.transaction:
        return;
    }
  }

  void clearAll() {
    _poppedGroups.clear();
    state = state.copyWith(groups: []);
  }

  LineUpProviderSnapshot takeSnapshot() {
    return LineUpProviderSnapshot(
      groups: state.groups.map((group) => group.deepCopy()).toList(),
      poppedGroups: _poppedGroups.map((group) => group.deepCopy()).toList(),
    );
  }

  void restoreSnapshot(LineUpProviderSnapshot snapshot) {
    _poppedGroups
      ..clear()
      ..addAll(snapshot.poppedGroups.map((group) => group.deepCopy()));
    state = state.copyWith(
      groups: snapshot.groups.map((group) => group.deepCopy()).toList(),
    );
  }
}

final lineUpProvider =
    NotifierProvider<LineUpProvider, LineUpState>(LineUpProvider.new);

enum LineUpHoverKind { group, item }

class HoveredLineUpTarget {
  const HoveredLineUpTarget.group({
    required this.groupId,
    required this.ownerToken,
  })  : itemId = null,
        kind = LineUpHoverKind.group;

  const HoveredLineUpTarget.item({
    required this.groupId,
    required this.itemId,
    required this.ownerToken,
  }) : kind = LineUpHoverKind.item;

  final String groupId;
  final String? itemId;
  final LineUpHoverKind kind;
  final Object ownerToken;

  bool matchesAgent(String candidateGroupId) {
    return groupId == candidateGroupId;
  }

  bool matchesAbility(String candidateGroupId, String candidateItemId) {
    if (groupId != candidateGroupId) return false;
    return kind == LineUpHoverKind.group || itemId == candidateItemId;
  }

  bool matchesConnector(String candidateGroupId, String candidateItemId) {
    return matchesAbility(candidateGroupId, candidateItemId);
  }
}

class HoveredLineUpProvider extends Notifier<HoveredLineUpTarget?> {
  @override
  HoveredLineUpTarget? build() {
    return null;
  }

  void setHoveredGroup({
    required String groupId,
    required Object ownerToken,
  }) {
    state = HoveredLineUpTarget.group(
      groupId: groupId,
      ownerToken: ownerToken,
    );
  }

  void setHoveredItem({
    required String groupId,
    required String itemId,
    required Object ownerToken,
  }) {
    state = HoveredLineUpTarget.item(
      groupId: groupId,
      itemId: itemId,
      ownerToken: ownerToken,
    );
  }

  void clearIfOwned(Object ownerToken) {
    if (state?.ownerToken != ownerToken) return;
    state = null;
  }
}

final hoveredLineUpTargetProvider =
    NotifierProvider<HoveredLineUpProvider, HoveredLineUpTarget?>(
  HoveredLineUpProvider.new,
);

class LineUpAbilityHitboxEntry {
  const LineUpAbilityHitboxEntry({
    required this.groupId,
    required this.itemId,
    required this.globalRect,
  });

  final String groupId;
  final String itemId;
  final Rect globalRect;
}

class LineUpAbilityStackCandidate {
  const LineUpAbilityStackCandidate({
    required this.groupId,
    required this.itemId,
    required this.ability,
    required this.globalRect,
    required this.paintOrder,
  });

  final String groupId;
  final String itemId;
  final PlacedAbility ability;
  final Rect globalRect;
  final int paintOrder;
}

String _lineUpAbilityHitboxKey(String groupId, String itemId) {
  return '$groupId::$itemId';
}

class LineUpAbilityHitboxRegistry
    extends Notifier<Map<String, LineUpAbilityHitboxEntry>> {
  @override
  Map<String, LineUpAbilityHitboxEntry> build() {
    return const {};
  }

  void register({
    required String groupId,
    required String itemId,
    required Rect globalRect,
  }) {
    final key = _lineUpAbilityHitboxKey(groupId, itemId);
    final current = state[key];
    if (current != null && current.globalRect == globalRect) {
      return;
    }

    state = {
      ...state,
      key: LineUpAbilityHitboxEntry(
        groupId: groupId,
        itemId: itemId,
        globalRect: globalRect,
      ),
    };
  }

  void unregister({
    required String groupId,
    required String itemId,
  }) {
    final key = _lineUpAbilityHitboxKey(groupId, itemId);
    if (!state.containsKey(key)) {
      return;
    }

    final nextState = {...state}..remove(key);
    state = nextState;
  }
}

final lineUpAbilityHitboxRegistryProvider = NotifierProvider<
    LineUpAbilityHitboxRegistry, Map<String, LineUpAbilityHitboxEntry>>(
  LineUpAbilityHitboxRegistry.new,
);

List<LineUpAbilityStackCandidate> resolveLineUpAbilityStackCandidates({
  required LineUpState lineUpState,
  required Map<String, LineUpAbilityHitboxEntry> hitboxes,
  required Offset globalPosition,
}) {
  final candidates = <LineUpAbilityStackCandidate>[];
  var paintOrder = 0;

  for (final group in lineUpState.groups) {
    for (final item in group.items) {
      final key = _lineUpAbilityHitboxKey(group.id, item.id);
      final hitbox = hitboxes[key];
      if (hitbox != null && hitbox.globalRect.contains(globalPosition)) {
        candidates.add(
          LineUpAbilityStackCandidate(
            groupId: group.id,
            itemId: item.id,
            ability: item.ability,
            globalRect: hitbox.globalRect,
            paintOrder: paintOrder,
          ),
        );
      }
      paintOrder++;
    }
  }

  candidates.sort((a, b) => b.paintOrder.compareTo(a.paintOrder));
  return candidates;
}
