import 'dart:convert';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:uuid/uuid.dart';

part "line_provider.g.dart";

enum LineUpPlacementMode { fresh, fromPinnedOrigin, toPinnedLanding }

const _noChange = Object();

@Deprecated('Use LineUpOrigin, LineUpLanding and LineUpLink instead.')
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

  factory LineUp.fromJson(Map<String, dynamic> json) => _$LineUpFromJson(json);

  Map<String, dynamic> toJson() => _$LineUpToJson(this);
}

@Deprecated('Use LineUpLanding and LineUpLink instead.')
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

@Deprecated('Use LineUpOrigin, LineUpLanding and LineUpLink instead.')
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

@JsonSerializable()
class LineUpOrigin extends HiveObject {
  final String id;
  final PlacedAgent agent;

  LineUpOrigin({
    required this.id,
    required this.agent,
  });

  LineUpOrigin copyWith({
    String? id,
    PlacedAgent? agent,
  }) {
    return LineUpOrigin(
      id: id ?? this.id,
      agent: agent ?? this.agent,
    );
  }

  LineUpOrigin deepCopy() {
    return LineUpOrigin(
      id: id,
      agent: agent.deepCopy<PlacedAgent>(),
    );
  }

  factory LineUpOrigin.fromJson(Map<String, dynamic> json) =>
      _$LineUpOriginFromJson(json);

  Map<String, dynamic> toJson() => _$LineUpOriginToJson(this);
}

@JsonSerializable()
class LineUpLanding extends HiveObject {
  final String id;
  final PlacedAbility ability;

  LineUpLanding({
    required this.id,
    required this.ability,
  });

  LineUpLanding copyWith({
    String? id,
    PlacedAbility? ability,
  }) {
    return LineUpLanding(
      id: id ?? this.id,
      ability: ability ?? this.ability,
    );
  }

  LineUpLanding deepCopy() {
    return LineUpLanding(
      id: id,
      ability: ability.deepCopy<PlacedAbility>(),
    );
  }

  factory LineUpLanding.fromJson(Map<String, dynamic> json) =>
      _$LineUpLandingFromJson(json);

  Map<String, dynamic> toJson() => _$LineUpLandingToJson(this);
}

@JsonSerializable()
class LineUpLink extends HiveObject {
  final String id;
  final String originId;
  final String landingId;
  final String name;
  final String youtubeLink;
  final String notes;
  final List<SimpleImageData> images;

  LineUpLink({
    required this.id,
    required this.originId,
    required this.landingId,
    this.name = '',
    this.youtubeLink = '',
    this.notes = '',
    this.images = const [],
  });

  LineUpLink copyWith({
    String? id,
    String? originId,
    String? landingId,
    String? name,
    String? youtubeLink,
    String? notes,
    List<SimpleImageData>? images,
  }) {
    return LineUpLink(
      id: id ?? this.id,
      originId: originId ?? this.originId,
      landingId: landingId ?? this.landingId,
      name: name ?? this.name,
      youtubeLink: youtubeLink ?? this.youtubeLink,
      notes: notes ?? this.notes,
      images: images ?? List<SimpleImageData>.from(this.images),
    );
  }

  LineUpLink deepCopy() {
    return LineUpLink(
      id: id,
      originId: originId,
      landingId: landingId,
      name: name,
      youtubeLink: youtubeLink,
      notes: notes,
      images: images.map((image) => image.copyWith()).toList(),
    );
  }

  factory LineUpLink.fromJson(Map<String, dynamic> json) =>
      _$LineUpLinkFromJson(json);

  Map<String, dynamic> toJson() => _$LineUpLinkToJson(this);
}

/// The persisted shape of a page's lineups: origins, landing spots and the
/// links between them. Owns the conversions to and from the legacy
/// [LineUpGroup] shape so every reader and writer agrees on them.
class LineUpGraph {
  final List<LineUpOrigin> origins;
  final List<LineUpLanding> landings;
  final List<LineUpLink> links;

  const LineUpGraph({
    this.origins = const [],
    this.landings = const [],
    this.links = const [],
  });

  static const empty = LineUpGraph();

  bool get isEmpty => links.isEmpty && origins.isEmpty && landings.isEmpty;

  LineUpGraph deepCopy() {
    return LineUpGraph(
      origins: origins.map((origin) => origin.deepCopy()).toList(),
      landings: landings.map((landing) => landing.deepCopy()).toList(),
      links: links.map((link) => link.deepCopy()).toList(),
    );
  }

  /// Applies a transform to every placed agent and ability while keeping
  /// the links untouched. Used by coordinate and geometry migrations.
  LineUpGraph mapNodes({
    PlacedAgent Function(PlacedAgent agent)? agent,
    PlacedAbility Function(PlacedAbility ability)? ability,
  }) {
    return LineUpGraph(
      origins: [
        for (final origin in origins)
          agent == null ? origin : origin.copyWith(agent: agent(origin.agent)),
      ],
      landings: [
        for (final landing in landings)
          ability == null
              ? landing
              : landing.copyWith(ability: ability(landing.ability)),
      ],
      links: links,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'lineUpOrigins': origins.map((origin) => origin.toJson()).toList(),
      'lineUpLandings': landings.map((landing) => landing.toJson()).toList(),
      'lineUpLinks': links.map((link) => link.toJson()).toList(),
    };
  }

  static bool hasJson(Map<String, dynamic> json) {
    return json['lineUpOrigins'] != null ||
        json['lineUpLandings'] != null ||
        json['lineUpLinks'] != null;
  }

  factory LineUpGraph.fromJson(Map<String, dynamic> json) {
    List<T> decode<T>(String key, T Function(Map<String, dynamic>) decoder) {
      final raw = json[key];
      if (raw is String) {
        return (jsonDecode(raw) as List<dynamic>)
            .map((entry) => decoder(entry as Map<String, dynamic>))
            .toList();
      }
      return ((raw as List<dynamic>?) ?? const [])
          .map((entry) => decoder(entry as Map<String, dynamic>))
          .toList();
    }

    return LineUpGraph(
      origins: decode('lineUpOrigins', LineUpOrigin.fromJson),
      landings: decode('lineUpLandings', LineUpLanding.fromJson),
      links: decode('lineUpLinks', LineUpLink.fromJson),
    );
  }

  /// One origin per group, one landing and one link per item. Landing and
  /// link share the item id on purpose: old readers keyed everything by item
  /// id and this keeps those ids stable. Empty groups are dropped. Landings
  /// are never merged by position; two stacked abilities stay two landings.
  static LineUpGraph fromLegacyGroups(List<LineUpGroup> groups) {
    final origins = <LineUpOrigin>[];
    final landings = <LineUpLanding>[];
    final links = <LineUpLink>[];
    for (final group in groups) {
      if (group.items.isEmpty) continue;
      origins.add(
        LineUpOrigin(
          id: group.id,
          agent: group.agent.copyWith(lineUpID: group.id),
        ),
      );
      for (final item in group.items) {
        landings.add(
          LineUpLanding(
            id: item.id,
            ability: item.ability.copyWith(lineUpID: item.id),
          ),
        );
        links.add(
          LineUpLink(
            id: item.id,
            originId: group.id,
            landingId: item.id,
            youtubeLink: item.youtubeLink,
            notes: item.notes,
            images: item.images.map((image) => image.copyWith()).toList(),
          ),
        );
      }
    }
    return LineUpGraph(origins: origins, landings: landings, links: links);
  }

  static LineUpGraph fromLegacyLineUps(List<LineUp> lineUps) {
    return fromLegacyGroups(lineUps.map(LineUpGroup.fromLegacyLineUp).toList());
  }

  /// Projection for readers that predate the graph: one group per origin,
  /// each link becomes an item carrying a copy of its landing's ability. A
  /// shared landing is copied once per origin.
  List<LineUpGroup> toLegacyGroups() {
    final landingsById = {for (final landing in landings) landing.id: landing};
    return [
      for (final origin in origins)
        LineUpGroup(
          id: origin.id,
          agent: origin.agent.copyWith(lineUpID: origin.id),
          items: [
            for (final link in links)
              if (link.originId == origin.id &&
                  landingsById.containsKey(link.landingId))
                LineUpItem(
                  id: link.id,
                  ability: landingsById[link.landingId]!
                      .ability
                      .copyWith(lineUpID: origin.id),
                  youtubeLink: link.youtubeLink,
                  notes: link.notes,
                  images: link.images.map((image) => image.copyWith()).toList(),
                ),
          ],
        ),
    ];
  }
}

class LineUpPlacement {
  final LineUpPlacementMode mode;
  final String? pinnedOriginId;
  final String? pinnedLandingId;
  final AgentType? pinnedAgentType;
  final PlacedAgent? draftAgent;
  final PlacedAbility? draftAbility;

  const LineUpPlacement({
    required this.mode,
    this.pinnedOriginId,
    this.pinnedLandingId,
    this.pinnedAgentType,
    this.draftAgent,
    this.draftAbility,
  });

  AgentType? get lockedAgentType => pinnedAgentType ?? draftAgent?.type;

  bool get hasOrigin => pinnedOriginId != null || draftAgent != null;

  bool get hasLanding => pinnedLandingId != null || draftAbility != null;

  bool get isComplete => hasOrigin && hasLanding;

  LineUpPlacement copyWith({
    Object? draftAgent = _noChange,
    Object? draftAbility = _noChange,
  }) {
    return LineUpPlacement(
      mode: mode,
      pinnedOriginId: pinnedOriginId,
      pinnedLandingId: pinnedLandingId,
      pinnedAgentType: pinnedAgentType,
      draftAgent: identical(draftAgent, _noChange)
          ? this.draftAgent
          : draftAgent as PlacedAgent?,
      draftAbility: identical(draftAbility, _noChange)
          ? this.draftAbility
          : draftAbility as PlacedAbility?,
    );
  }
}

class LineUpState {
  final List<LineUpOrigin> origins;
  final List<LineUpLanding> landings;
  final List<LineUpLink> links;
  final LineUpPlacement? placement;

  const LineUpState({
    this.origins = const [],
    this.landings = const [],
    this.links = const [],
    this.placement,
  });

  LineUpGraph get graph =>
      LineUpGraph(origins: origins, landings: landings, links: links);

  bool get isEmpty => links.isEmpty;

  LineUpOrigin? originById(String id) {
    for (final origin in origins) {
      if (origin.id == id) return origin;
    }
    return null;
  }

  LineUpLanding? landingById(String id) {
    for (final landing in landings) {
      if (landing.id == id) return landing;
    }
    return null;
  }

  LineUpLink? linkById(String id) {
    for (final link in links) {
      if (link.id == id) return link;
    }
    return null;
  }

  List<LineUpLink> linksFromOrigin(String originId) {
    return links.where((link) => link.originId == originId).toList();
  }

  List<LineUpLink> linksToLanding(String landingId) {
    return links.where((link) => link.landingId == landingId).toList();
  }

  /// Distinct (originId, landingId) pairs in first-seen order. One line is
  /// drawn per pair regardless of how many links share it.
  List<(String, String)> get connectorPairs {
    final seen = <String>{};
    final pairs = <(String, String)>[];
    for (final link in links) {
      if (seen.add('${link.originId}::${link.landingId}')) {
        pairs.add((link.originId, link.landingId));
      }
    }
    return pairs;
  }

  LineUpState copyWith({
    List<LineUpOrigin>? origins,
    List<LineUpLanding>? landings,
    List<LineUpLink>? links,
    Object? placement = _noChange,
  }) {
    return LineUpState(
      origins: origins ?? this.origins,
      landings: landings ?? this.landings,
      links: links ?? this.links,
      placement: identical(placement, _noChange)
          ? this.placement
          : placement as LineUpPlacement?,
    );
  }
}

/// Adding or removing lineups: the origins, landings and links the change
/// put in ([after]) or took out ([before]). Undo and redo apply it to
/// whatever graph is current, so a page rehydrated in between (a cloud ack,
/// a teammate's edit) neither separates the action from its data nor rolls
/// back anyone else's lineups.
class LineUpGraphAction extends UserAction {
  LineUpGraphAction({
    required super.type,
    required super.id,
    this.before = LineUpGraph.empty,
    this.after = LineUpGraph.empty,
  }) : super(group: ActionGroup.lineUp);

  final LineUpGraph before;
  final LineUpGraph after;

  Iterable<String> get entryIds sync* {
    for (final graph in [before, after]) {
      yield* graph.origins.map((origin) => origin.id);
      yield* graph.landings.map((landing) => landing.id);
      yield* graph.links.map((link) => link.id);
    }
  }

  // History stores copies, so the copy must keep the change.
  @override
  LineUpGraphAction copy() {
    return LineUpGraphAction(
      type: type,
      id: id,
      before: before.deepCopy(),
      after: after.deepCopy(),
    );
  }
}

/// The one part of a lineup entry an edit changes.
enum LineUpEditField {
  originPosition,
  landingPosition,
  landingVisibility,
  linkDetails
}

/// The properties of a link one edit changes, as that edit sets them.
/// Properties it left alone are null (or empty for images), so writing the
/// change keeps whatever they are now, including a teammate's edits.
class LineUpLinkChange {
  const LineUpLinkChange({
    this.name,
    this.youtubeLink,
    this.notes,
    this.addedImages = const [],
    this.removedImageIds = const {},
  });

  final String? name;
  final String? youtubeLink;
  final String? notes;

  /// Images this change puts in, in order, each with the ids of the images
  /// that followed it and are not being added themselves. Writing the change
  /// inserts an image before the first of those still present, so undoing a
  /// removal restores the order around any images a teammate added since.
  final List<({SimpleImageData image, List<String> followedBy})> addedImages;
  final Set<String> removedImageIds;

  bool get isEmpty =>
      name == null &&
      youtubeLink == null &&
      notes == null &&
      addedImages.isEmpty &&
      removedImageIds.isEmpty;

  /// The change from [before] to [after], and the change that undoes it.
  static ({LineUpLinkChange forward, LineUpLinkChange backward}) between(
    LineUpLink before,
    LineUpLink after,
  ) {
    String? changed(String a, String b) => a == b ? null : b;

    /// The images of [target] missing from [source], placed by the images
    /// of [target] that follow them and do exist in [source].
    List<({SimpleImageData image, List<String> followedBy})> imagesOnlyIn(
      List<SimpleImageData> target,
      List<SimpleImageData> source,
    ) {
      final sourceIds = source.map((image) => image.id).toSet();
      return [
        for (var i = 0; i < target.length; i++)
          if (!sourceIds.contains(target[i].id))
            (
              image: target[i],
              followedBy: [
                for (final next in target.skip(i + 1))
                  if (sourceIds.contains(next.id)) next.id,
              ],
            ),
      ];
    }

    final added = imagesOnlyIn(after.images, before.images);
    final removed = imagesOnlyIn(before.images, after.images);
    return (
      forward: LineUpLinkChange(
        name: changed(before.name, after.name),
        youtubeLink: changed(before.youtubeLink, after.youtubeLink),
        notes: changed(before.notes, after.notes),
        addedImages: added,
        removedImageIds: {for (final entry in removed) entry.image.id},
      ),
      backward: LineUpLinkChange(
        name: changed(after.name, before.name),
        youtubeLink: changed(after.youtubeLink, before.youtubeLink),
        notes: changed(after.notes, before.notes),
        addedImages: removed,
        removedImageIds: {for (final entry in added) entry.image.id},
      ),
    );
  }

  LineUpLink writeTo(LineUpLink link) {
    final images = [
      for (final image in link.images)
        if (!removedImageIds.contains(image.id)) image.copyWith(),
    ];
    for (final entry in addedImages) {
      if (images.any((image) => image.id == entry.image.id)) continue;
      final at = entry.followedBy
          .map((id) => images.indexWhere((image) => image.id == id))
          .firstWhere((index) => index >= 0, orElse: () => images.length);
      images.insert(at, entry.image.copyWith());
    }
    return link.copyWith(
      name: name ?? link.name,
      youtubeLink: youtubeLink ?? link.youtubeLink,
      notes: notes ?? link.notes,
      images: images,
    );
  }
}

/// The visibility toggles one edit changes, as it sets them; toggles it left
/// alone are null.
class AbilityVisibilityChange {
  const AbilityVisibilityChange({
    this.showRangeOutline,
    this.showRangeFill,
    this.showInnerOutline,
    this.showInnerFill,
    this.showVisionCone,
  });

  final bool? showRangeOutline;
  final bool? showRangeFill;
  final bool? showInnerOutline;
  final bool? showInnerFill;
  final bool? showVisionCone;

  bool get isEmpty =>
      showRangeOutline == null &&
      showRangeFill == null &&
      showInnerOutline == null &&
      showInnerFill == null &&
      showVisionCone == null;

  /// The change from [before] to [after], and the change that undoes it.
  static ({AbilityVisibilityChange forward, AbilityVisibilityChange backward})
      between(AbilityVisualState before, AbilityVisualState after) {
    bool? changed(bool a, bool b) => a == b ? null : b;
    return (
      forward: AbilityVisibilityChange(
        showRangeOutline:
            changed(before.showRangeOutline, after.showRangeOutline),
        showRangeFill: changed(before.showRangeFill, after.showRangeFill),
        showInnerOutline:
            changed(before.showInnerOutline, after.showInnerOutline),
        showInnerFill: changed(before.showInnerFill, after.showInnerFill),
        showVisionCone: changed(before.showVisionCone, after.showVisionCone),
      ),
      backward: AbilityVisibilityChange(
        showRangeOutline:
            changed(after.showRangeOutline, before.showRangeOutline),
        showRangeFill: changed(after.showRangeFill, before.showRangeFill),
        showInnerOutline:
            changed(after.showInnerOutline, before.showInnerOutline),
        showInnerFill: changed(after.showInnerFill, before.showInnerFill),
        showVisionCone: changed(after.showVisionCone, before.showVisionCone),
      ),
    );
  }

  AbilityVisualState writeTo(AbilityVisualState state) => state.copyWith(
        showRangeOutline: showRangeOutline,
        showRangeFill: showRangeFill,
        showInnerOutline: showInnerOutline,
        showInnerFill: showInnerFill,
        showVisionCone: showVisionCone,
      );
}

/// An edit to one field of one lineup entry. Undo and redo write only what
/// the edit changed onto the entry as it is now, so anything else changed
/// since (a teammate's weapon, image or toggle) is kept. The values are an
/// Offset for positions, an AbilityVisibilityChange for visibility and a
/// LineUpLinkChange for link details.
class LineUpEditAction extends UserAction {
  LineUpEditAction({
    required super.id,
    required this.targetId,
    required this.field,
    required this.before,
    required this.after,
  }) : super(type: ActionType.edit, group: ActionGroup.lineUp);

  final String targetId;
  final LineUpEditField field;
  final Object before;
  final Object after;

  @override
  LineUpEditAction copy() {
    return LineUpEditAction(
      id: id,
      targetId: targetId,
      field: field,
      before: before,
      after: after,
    );
  }
}

class LineUpProvider extends Notifier<LineUpState> {
  static const _uuid = Uuid();

  @override
  LineUpState build() {
    return const LineUpState();
  }

  LineUpOrigin? originById(String id) => state.originById(id);
  LineUpLanding? landingById(String id) => state.landingById(id);
  LineUpLink? linkById(String id) => state.linkById(id);
  List<LineUpLink> linksFromOrigin(String originId) =>
      state.linksFromOrigin(originId);
  List<LineUpLink> linksToLanding(String landingId) =>
      state.linksToLanding(landingId);

  // --- Placement -----------------------------------------------------------

  void startFresh() {
    state = state.copyWith(
      placement: const LineUpPlacement(mode: LineUpPlacementMode.fresh),
    );
  }

  void startFromOrigin(String originId) {
    final origin = state.originById(originId);
    if (origin == null) return;
    state = state.copyWith(
      placement: LineUpPlacement(
        mode: LineUpPlacementMode.fromPinnedOrigin,
        pinnedOriginId: originId,
        pinnedAgentType: origin.agent.type,
      ),
    );
  }

  void startToLanding(String landingId) {
    final landing = state.landingById(landingId);
    if (landing == null) return;
    state = state.copyWith(
      placement: LineUpPlacement(
        mode: LineUpPlacementMode.toPinnedLanding,
        pinnedLandingId: landingId,
        pinnedAgentType: landing.ability.data.type,
      ),
    );
  }

  void setDraftAgent(PlacedAgent agent) {
    final placement = state.placement;
    if (placement == null) return;
    if (placement.pinnedOriginId != null) {
      Settings.showToast(
        message: "The origin is pinned. Drag an ability instead.",
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }
    final pinnedType = placement.pinnedAgentType;
    if (pinnedType != null && agent.type != pinnedType) {
      Settings.showToast(
        message: "Drag ${AgentData.agents[pinnedType]?.name ?? 'the agent'} "
            "for this landing spot.",
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }
    final keepsAbility = placement.draftAbility?.data.type == agent.type;
    state = state.copyWith(
      placement: placement.copyWith(
        draftAgent: agent,
        draftAbility: keepsAbility ? placement.draftAbility : null,
      ),
    );
  }

  void setDraftAbility(PlacedAbility ability) {
    final placement = state.placement;
    if (placement == null) return;
    if (placement.pinnedLandingId != null) {
      Settings.showToast(
        message: "The landing spot is pinned. Drag an agent instead.",
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }
    final agentType = placement.lockedAgentType;
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
    state =
        state.copyWith(placement: placement.copyWith(draftAbility: ability));
  }

  void updateDraftAgentPosition(Offset position) {
    final draft = state.placement?.draftAgent;
    if (draft == null) return;
    draft.updatePosition(position);
    state =
        state.copyWith(placement: state.placement!.copyWith(draftAgent: draft));
  }

  void setDraftAgentWeapon(WeaponType weapon) {
    final placement = state.placement;
    final draft = placement?.draftAgent;
    if (placement == null || draft == null || draft.weapon == weapon) return;
    state = state.copyWith(
      placement: placement.copyWith(draftAgent: draft.copyWith(weapon: weapon)),
    );
  }

  void updateDraftAbilityPosition(Offset position) {
    final draft = state.placement?.draftAbility;
    if (draft == null) return;
    draft.updatePosition(position);
    state = state.copyWith(
      placement: state.placement!.copyWith(draftAbility: draft),
    );
  }

  void updateDraftAbilityGeometry({
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
  }) {
    final draft = state.placement?.draftAbility;
    if (draft == null) return;
    state = state.copyWith(
      placement: state.placement!.copyWith(
        draftAbility: draft.copyWith(
          rotation: rotation,
          length: length,
          armLengthsMeters: armLengthsMeters,
        ),
      ),
    );
  }

  void clearDraftAbility() {
    final placement = state.placement;
    if (placement?.draftAbility == null) return;
    state = state.copyWith(placement: placement!.copyWith(draftAbility: null));
  }

  void clearPlacement() {
    if (state.placement == null) return;
    state = state.copyWith(placement: null);
  }

  /// Turns the current placement into a link, creating whichever end was a
  /// draft. Returns the new link, or null when the placement is incomplete.
  LineUpLink? commitPlacement({
    String name = '',
    String youtubeLink = '',
    String notes = '',
    List<SimpleImageData> images = const [],
  }) {
    final placement = state.placement;
    if (placement == null || !placement.isComplete) return null;

    final linkId = _uuid.v4();
    final originId = placement.pinnedOriginId ?? _uuid.v4();
    // A landing made for this link takes the link's id. The cloud projection
    // stores each link as an item keyed by the link id and hydration makes
    // that the landing id, so sharing it keeps the landing's identity across
    // a round trip and every action that names it stays valid.
    final landingId = placement.pinnedLandingId ?? linkId;
    final origins = [...state.origins];
    final landings = [...state.landings];
    if (placement.pinnedOriginId == null) {
      origins.add(
        LineUpOrigin(
          id: originId,
          agent: placement.draftAgent!.copyWith(lineUpID: originId),
        ),
      );
    }
    if (placement.pinnedLandingId == null) {
      landings.add(
        LineUpLanding(
          id: landingId,
          ability: placement.draftAbility!.copyWith(lineUpID: landingId),
        ),
      );
    }
    final link = LineUpLink(
      id: linkId,
      originId: originId,
      landingId: landingId,
      name: name,
      youtubeLink: youtubeLink,
      notes: notes,
      images: images.map((image) => image.copyWith()).toList(),
    );
    // Both endpoints are recorded even when pinned, so redo can recreate
    // one that a cloud rehydrate renamed in between.
    final added = LineUpGraph(
      origins: [origins.firstWhere((origin) => origin.id == originId)],
      landings: [landings.firstWhere((landing) => landing.id == landingId)],
      links: [link],
    );
    state = state.copyWith(
      origins: origins,
      landings: landings,
      links: [...state.links, link],
      placement: null,
    );
    _record(
      LineUpGraphAction(type: ActionType.addition, id: link.id, after: added),
    );
    return link;
  }

  void setOriginWeapon(String originId, WeaponType weapon) {
    final index = state.origins.indexWhere((origin) => origin.id == originId);
    if (index < 0 || state.origins[index].agent.weapon == weapon) return;
    final previous = state.origins[index].agent.weapon;
    _applyOriginWeapon(originId, weapon);
    ref.read(actionProvider.notifier).addAction(WeaponSelectionAction(
          id: originId,
          group: ActionGroup.lineUp,
          before: previous,
          after: weapon,
        ));
  }

  void _applyOriginWeapon(String originId, WeaponType weapon) {
    final index = state.origins.indexWhere((origin) => origin.id == originId);
    if (index < 0) return;
    final origins = [...state.origins];
    final origin = origins[index];
    origins[index] = origin.copyWith(
      agent: origin.agent.copyWith(weapon: weapon),
    );
    state = state.copyWith(origins: origins);
  }

  // --- Edits (each records one undoable change to one field) --------------

  /// Records a change to the link's details: name, video link, notes and
  /// images. Which origin and landing it joins is never edited here.
  void updateLink(LineUpLink link) {
    final current = state.linkById(link.id);
    if (current == null) return;
    final change = LineUpLinkChange.between(current, link);
    if (change.forward.isEmpty) return;
    _recordEdit(
      targetId: link.id,
      field: LineUpEditField.linkDetails,
      before: change.backward,
      after: change.forward,
    );
  }

  void updateOriginAgentPosition(String originId, Offset position) {
    final current = state.originById(originId);
    if (current == null) return;
    _recordEdit(
      targetId: originId,
      field: LineUpEditField.originPosition,
      before: current.agent.position,
      after: position,
    );
  }

  void updateLandingPosition(String landingId, Offset position) {
    final current = state.landingById(landingId);
    if (current == null) return;
    _recordEdit(
      targetId: landingId,
      field: LineUpEditField.landingPosition,
      before: current.ability.position,
      after: position,
    );
  }

  void updateLandingAbilityVisualState({
    required String landingId,
    required AbilityVisualState visualState,
  }) {
    final current = state.landingById(landingId);
    if (current == null) return;
    final change = AbilityVisibilityChange.between(
        current.ability.visualState, visualState);
    if (change.forward.isEmpty) return;
    _recordEdit(
      targetId: landingId,
      field: LineUpEditField.landingVisibility,
      before: change.backward,
      after: change.forward,
    );
  }

  void _recordEdit({
    required String targetId,
    required LineUpEditField field,
    required Object before,
    required Object after,
  }) {
    _writeField(field, targetId, after);
    _record(
      LineUpEditAction(
        id: _uuid.v4(),
        targetId: targetId,
        field: field,
        before: before,
        after: after,
      ),
    );
  }

  /// Writes one field onto the entry as it is now; a missing entry is left
  /// alone.
  void _writeField(LineUpEditField field, String targetId, Object value) {
    switch (field) {
      case LineUpEditField.originPosition:
        state = state.copyWith(origins: [
          for (final origin in state.origins)
            origin.id == targetId
                ? origin.copyWith(
                    agent: origin.agent.copyWith(position: value as Offset)
                      ..isDeleted = origin.agent.isDeleted,
                  )
                : origin,
        ]);
      case LineUpEditField.landingPosition:
      case LineUpEditField.landingVisibility:
        state = state.copyWith(landings: [
          for (final landing in state.landings)
            landing.id == targetId
                ? landing.copyWith(
                    ability: (field == LineUpEditField.landingPosition
                        ? landing.ability.copyWith(position: value as Offset)
                        : landing.ability.copyWith(
                            visualState: (value as AbilityVisibilityChange)
                                .writeTo(landing.ability.visualState),
                          ))
                      ..isDeleted = landing.ability.isDeleted,
                  )
                : landing,
        ]);
      case LineUpEditField.linkDetails:
        state = state.copyWith(links: [
          for (final link in state.links)
            link.id == targetId
                ? (value as LineUpLinkChange).writeTo(link)
                : link,
        ]);
    }
  }

  // --- Deletions -----------------------------------------------------------

  void deleteLink(String linkId) {
    if (state.linkById(linkId) == null) return;
    _recordDeletion(linkId, {linkId});
  }

  void deleteOrigin(String originId) {
    if (state.originById(originId) == null) return;
    _recordDeletion(
      originId,
      state.linksFromOrigin(originId).map((link) => link.id).toSet(),
    );
  }

  void deleteLanding(String landingId) {
    if (state.landingById(landingId) == null) return;
    _recordDeletion(
      landingId,
      state.linksToLanding(landingId).map((link) => link.id).toSet(),
    );
  }

  /// Removes [linkIds] (origins and landings left without a link go with
  /// them) and records the links plus every endpoint they joined, shared ones
  /// included. Undo can then rebuild a lineup whose shared landing a cloud
  /// rehydrate renamed in between, instead of restoring a link to nothing.
  void _recordDeletion(String actionId, Set<String> linkIds) {
    final removedLinks =
        state.links.where((link) => linkIds.contains(link.id)).toList();
    if (removedLinks.isEmpty) return;
    final originIds = removedLinks.map((link) => link.originId).toSet();
    final landingIds = removedLinks.map((link) => link.landingId).toSet();
    final removed = LineUpGraph(
      origins: state.origins
          .where((origin) => originIds.contains(origin.id))
          .toList(),
      landings: state.landings
          .where((landing) => landingIds.contains(landing.id))
          .toList(),
      links: removedLinks,
    );
    _apply(from: removed, to: LineUpGraph.empty);
    _record(
      LineUpGraphAction(
        type: ActionType.deletion,
        id: actionId,
        before: removed,
      ),
    );
  }

  void _record(UserAction action) {
    ref.read(actionProvider.notifier).addAction(action);
  }

  /// Moves the graph from [from] to [to] for the entries they name, leaving
  /// every other origin, landing and link as it currently is. Links only in
  /// [from] are removed. Entries in [to] are put back only where missing: one
  /// that exists now keeps its current state (edits since are kept, and a
  /// restored link joins the surviving shared landing). An origin or landing
  /// exists only while some link uses it, so any node left without a link
  /// is dropped.
  void _apply({required LineUpGraph from, required LineUpGraph to}) {
    List<T> upsert<T>(
      List<T> current,
      List<T> incoming,
      String Function(T) idOf,
    ) {
      final present = current.map(idOf).toSet();
      return [
        ...current,
        for (final entry in incoming)
          if (!present.contains(idOf(entry))) entry,
      ];
    }

    final droppedLinks = from.links.map((link) => link.id).toSet()
      ..removeAll(to.links.map((link) => link.id));
    final links = upsert(
      state.links.where((link) => !droppedLinks.contains(link.id)).toList(),
      to.links,
      (link) => link.id,
    );
    final usedOrigins = links.map((link) => link.originId).toSet();
    final usedLandings = links.map((link) => link.landingId).toSet();

    state = state.copyWith(
      origins: upsert(state.origins, to.origins, (origin) => origin.id)
          .where((origin) => usedOrigins.contains(origin.id))
          .toList(),
      landings: upsert(state.landings, to.landings, (landing) => landing.id)
          .where((landing) => usedLandings.contains(landing.id))
          .toList(),
      links: links,
    );
  }

  /// Every lineup entry [history] could still act on: the current graph plus
  /// anything a retained addition or deletion can bring back.
  Set<String> replayableIds(Iterable<UserAction> history) {
    return {
      ...state.origins.map((origin) => origin.id),
      ...state.landings.map((landing) => landing.id),
      ...state.links.map((link) => link.id),
      for (final action in history)
        if (action is LineUpGraphAction) ...action.entryIds,
    };
  }

  /// Undoes or redoes [action] on the graph as it is now and returns the
  /// action that reverses exactly what this did: the links it took out, as
  /// they were, and the links it put back, as they now are, each with its
  /// endpoints. Links already gone are not taken out and links already there
  /// are left as they are; when that leaves nothing to do, returns null.
  LineUpGraphAction? replayGraphAction(
    LineUpGraphAction action, {
    required bool undo,
  }) {
    final from = undo ? action.after : action.before;
    final to = undo ? action.before : action.after;
    final kept = to.links.map((link) => link.id).toSet();
    final removing = {
      for (final link in from.links)
        if (!kept.contains(link.id) && state.linkById(link.id) != null) link.id,
    };
    final inserting = {
      for (final link in to.links)
        if (state.linkById(link.id) == null) link.id,
    };
    if (removing.isEmpty && inserting.isEmpty) return null;

    final removed = _currentEntries(removing);
    _apply(
      from: removed,
      to: LineUpGraph(
        origins: to.origins,
        landings: to.landings,
        links: [
          for (final link in to.links)
            if (inserting.contains(link.id)) link,
        ],
      ),
    );
    final inserted = _currentEntries(inserting);
    return LineUpGraphAction(
      type: action.type,
      id: action.id,
      before: undo ? inserted : removed,
      after: undo ? removed : inserted,
    );
  }

  /// A copy of the links [linkIds] and the origins and landings they join,
  /// as they are now.
  LineUpGraph _currentEntries(Set<String> linkIds) {
    final links =
        state.links.where((link) => linkIds.contains(link.id)).toList();
    final originIds = links.map((link) => link.originId).toSet();
    final landingIds = links.map((link) => link.landingId).toSet();
    return LineUpGraph(
      origins: state.origins
          .where((origin) => originIds.contains(origin.id))
          .toList(),
      landings: state.landings
          .where((landing) => landingIds.contains(landing.id))
          .toList(),
      links: links,
    ).deepCopy();
  }

  /// Undoes a weapon or field edit. Graph changes (additions, deletions,
  /// clears) replay through [replayGraphAction].
  void undoAction(UserAction action) {
    switch (action) {
      case WeaponSelectionAction():
        _applyOriginWeapon(action.id, action.before);
      case LineUpEditAction():
        _writeField(action.field, action.targetId, action.before);
      default:
        return;
    }
  }

  /// Redoes a weapon or field edit. Graph changes replay through
  /// [replayGraphAction].
  void redoAction(UserAction action) {
    switch (action) {
      case WeaponSelectionAction():
        _applyOriginWeapon(action.id, action.after);
      case LineUpEditAction():
        _writeField(action.field, action.targetId, action.after);
      default:
        return;
    }
  }

  // --- Lifecycle and serialization -----------------------------------------

  void fromHive(LineUpGraph graph) {
    final copy = graph.deepCopy();
    state = state.copyWith(
      origins: copy.origins,
      landings: copy.landings,
      links: copy.links,
    );
  }

  static String objectToJson(LineUpGraph graph) {
    return jsonEncode(graph.toJson());
  }

  static LineUpGraph fromJson(String json) {
    return LineUpGraph.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  static List<LineUpGroup> legacyGroupsFromJson(String json) {
    return (jsonDecode(json) as List<dynamic>)
        .map((entry) => LineUpGroup.fromJson(entry as Map<String, dynamic>))
        .toList();
  }

  static List<LineUpGroup> legacyGroupsFromLineUpJson(String json) {
    return (jsonDecode(json) as List<dynamic>)
        .map((entry) => LineUp.fromJson(entry as Map<String, dynamic>))
        .map(LineUpGroup.fromLegacyLineUp)
        .toList();
  }

  void clearAll() {
    state = state.copyWith(origins: [], landings: [], links: []);
  }
}

final lineUpProvider =
    NotifierProvider<LineUpProvider, LineUpState>(LineUpProvider.new);

enum LineUpHoverKind { origin, landing, connector }

class HoveredLineUpTarget {
  const HoveredLineUpTarget.origin({
    required String id,
    required this.ownerToken,
  })  : originId = id,
        landingId = null,
        kind = LineUpHoverKind.origin;

  const HoveredLineUpTarget.landing({
    required String id,
    required this.ownerToken,
  })  : originId = null,
        landingId = id,
        kind = LineUpHoverKind.landing;

  const HoveredLineUpTarget.connector({
    required String this.originId,
    required String this.landingId,
    required this.ownerToken,
  }) : kind = LineUpHoverKind.connector;

  final String? originId;
  final String? landingId;
  final LineUpHoverKind kind;
  final Object ownerToken;

  bool matchesOrigin(String candidateOriginId) {
    return kind == LineUpHoverKind.origin && originId == candidateOriginId;
  }

  bool matchesLanding(String candidateLandingId) {
    return kind == LineUpHoverKind.landing && landingId == candidateLandingId;
  }

  bool matchesConnector(String candidateOriginId, String candidateLandingId) {
    return switch (kind) {
      LineUpHoverKind.origin => originId == candidateOriginId,
      LineUpHoverKind.landing => landingId == candidateLandingId,
      LineUpHoverKind.connector =>
        originId == candidateOriginId && landingId == candidateLandingId,
    };
  }
}

class HoveredLineUpProvider extends Notifier<HoveredLineUpTarget?> {
  @override
  HoveredLineUpTarget? build() {
    return null;
  }

  void setHoveredOrigin({
    required String originId,
    required Object ownerToken,
  }) {
    state = HoveredLineUpTarget.origin(id: originId, ownerToken: ownerToken);
  }

  void setHoveredLanding({
    required String landingId,
    required Object ownerToken,
  }) {
    state = HoveredLineUpTarget.landing(id: landingId, ownerToken: ownerToken);
  }

  void setHoveredConnector({
    required String originId,
    required String landingId,
    required Object ownerToken,
  }) {
    state = HoveredLineUpTarget.connector(
      originId: originId,
      landingId: landingId,
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
    required this.landingId,
    required this.globalRect,
    this.owner,
  });

  final String landingId;
  final Rect globalRect;

  /// The widget instance that registered this hitbox, so a disposed instance
  /// cannot unregister a successor that took over the same landing.
  final Object? owner;
}

class LineUpAbilityStackCandidate {
  const LineUpAbilityStackCandidate({
    required this.landingId,
    required this.ability,
    required this.globalRect,
    required this.paintOrder,
  });

  final String landingId;
  final PlacedAbility ability;
  final Rect globalRect;
  final int paintOrder;
}

class LineUpAbilityHitboxRegistry
    extends Notifier<Map<String, LineUpAbilityHitboxEntry>> {
  @override
  Map<String, LineUpAbilityHitboxEntry> build() {
    return const {};
  }

  void register({
    required String landingId,
    required Rect globalRect,
    Object? owner,
  }) {
    final current = state[landingId];
    if (current != null &&
        current.globalRect == globalRect &&
        current.owner == owner) {
      return;
    }

    state = {
      ...state,
      landingId: LineUpAbilityHitboxEntry(
        landingId: landingId,
        globalRect: globalRect,
        owner: owner,
      ),
    };
  }

  void unregister({required String landingId, Object? owner}) {
    final current = state[landingId];
    if (current == null || (owner != null && current.owner != owner)) {
      return;
    }

    final nextState = {...state}..remove(landingId);
    state = nextState;
  }
}

final lineUpAbilityHitboxRegistryProvider = NotifierProvider<
    LineUpAbilityHitboxRegistry, Map<String, LineUpAbilityHitboxEntry>>(
  LineUpAbilityHitboxRegistry.new,
);

/// Landings whose icon covers [globalPosition], topmost first. Only landings
/// that genuinely overlap each other end up here; a landing with several
/// links is still one candidate.
List<LineUpAbilityStackCandidate> resolveLineUpAbilityStackCandidates({
  required LineUpState lineUpState,
  required Map<String, LineUpAbilityHitboxEntry> hitboxes,
  required Offset globalPosition,
}) {
  final candidates = <LineUpAbilityStackCandidate>[];
  var paintOrder = 0;

  for (final landing in lineUpState.landings) {
    final hitbox = hitboxes[landing.id];
    if (hitbox != null && hitbox.globalRect.contains(globalPosition)) {
      candidates.add(
        LineUpAbilityStackCandidate(
          landingId: landing.id,
          ability: landing.ability,
          globalRect: hitbox.globalRect,
          paintOrder: paintOrder,
        ),
      );
    }
    paintOrder++;
  }

  candidates.sort((a, b) => b.paintOrder.compareTo(a.paintOrder));
  return candidates;
}
