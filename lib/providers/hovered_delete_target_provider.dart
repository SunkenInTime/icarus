import 'package:flutter_riverpod/flutter_riverpod.dart';

enum DeleteTargetType {
  agent,
  ability,
  text,
  image,
  utility,
  lineup,
}

class HoveredDeleteTarget {
  HoveredDeleteTarget({
    required this.type,
    required this.id,
    required this.ownerToken,
  });

  factory HoveredDeleteTarget.agent({
    required String id,
    required Object ownerToken,
  }) {
    return HoveredDeleteTarget(
      type: DeleteTargetType.agent,
      id: id,
      ownerToken: ownerToken,
    );
  }

  factory HoveredDeleteTarget.ability({
    required String id,
    required Object ownerToken,
  }) {
    return HoveredDeleteTarget(
      type: DeleteTargetType.ability,
      id: id,
      ownerToken: ownerToken,
    );
  }

  factory HoveredDeleteTarget.text({
    required String id,
    required Object ownerToken,
  }) {
    return HoveredDeleteTarget(
      type: DeleteTargetType.text,
      id: id,
      ownerToken: ownerToken,
    );
  }

  factory HoveredDeleteTarget.image({
    required String id,
    required Object ownerToken,
  }) {
    return HoveredDeleteTarget(
      type: DeleteTargetType.image,
      id: id,
      ownerToken: ownerToken,
    );
  }

  factory HoveredDeleteTarget.utility({
    required String id,
    required Object ownerToken,
  }) {
    return HoveredDeleteTarget(
      type: DeleteTargetType.utility,
      id: id,
      ownerToken: ownerToken,
    );
  }

  factory HoveredDeleteTarget.lineup({
    required String id,
    required Object ownerToken,
  }) {
    return HoveredDeleteTarget(
      type: DeleteTargetType.lineup,
      id: id,
      ownerToken: ownerToken,
    );
  }

  final DeleteTargetType type;
  final String id;
  final Object ownerToken;

  HoveredDeleteTarget copyWith({
    DeleteTargetType? type,
    String? id,
    Object? ownerToken,
  }) {
    return HoveredDeleteTarget(
      type: type ?? this.type,
      id: id ?? this.id,
      ownerToken: ownerToken ?? this.ownerToken,
    );
  }
}

final hoveredDeleteTargetProvider =
    StateProvider<HoveredDeleteTarget?>((ref) => null);
