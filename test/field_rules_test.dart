import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus_library/icarus_library.dart';

PlacedAbility _tide() => PlacedAbility(
      id: 'tide',
      data: AgentData.agents[AgentType.harbor]!.abilities[1],
      position: const Offset(30, 40),
    );

Object? _emptyOf(String field) => switch (
        laterElementFields.firstWhere((entry) => entry.field == field).empty) {
      ClearedBy(:final value) => value,
      NeverCleared() => fail('$field is never cleared'),
    };

Map<String, dynamic> _json(PlacedAbility item) =>
    jsonDecode(jsonEncode(item.toJson())) as Map<String, dynamic>;

void main() {
  test('the app clears a caption by writing the table\'s empty value', () {
    final item = _tide()..caption = '';
    expect(_json(item)['caption'], _emptyOf('caption'));
    final read = PlacedAbility.fromJson(
        {..._json(_tide()), 'caption': _emptyOf('caption')});
    expect(read.caption?.isNotEmpty ?? false, isFalse);
  });

  test('the app clears a wall path by writing the table\'s empty value', () {
    final item = _tide()..wallPath = const [];
    expect(_json(item)['wallPath'], _emptyOf('wallPath'));
    final read = PlacedAbility.fromJson(
        {..._json(_tide()), 'wallPath': _emptyOf('wallPath')});
    expect(read.wallPath?.isNotEmpty ?? false, isFalse);
  });

  test('a missing weapon reads as the app\'s no weapon', () {
    final rule = fieldDefaults.whereType<DefaultBeside>().single;
    expect((rule.sibling, rule.field, rule.value),
        ('state', 'weapon', WeaponType.none.name));
  });
}
