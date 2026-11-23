import 'dart:convert';
import 'dart:math';

import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/strategy_page.dart';

import '../library_rows/generated_strategies.dart';

List<ActionObjectState> objectsOf(StrategyPage page) => [
      for (final agent in page.agentData) ActionObjectState.agent(agent),
      for (final ability in page.abilityData)
        ActionObjectState.ability(ability),
      for (final drawing in page.drawingData)
        ActionObjectState.drawing(drawing),
      for (final text in page.textData) ActionObjectState.text(text),
      for (final image in page.imageData) ActionObjectState.image(image),
      for (final utility in page.utilityData)
        ActionObjectState.utility(utility),
    ];

Map<String, Object?> _json(ActionObjectState object) =>
    jsonDecode(jsonEncode(object.toJson())) as Map<String, Object?>;

String _same(Object? value) => jsonEncode(value);

final List<ActionObjectState> _donors = [
  for (final optionals in Optionals.values)
    for (final isAttack in [true, false])
      ...objectsOf(generatedPage(
        id: 'donor-${optionals.name}-$isAttack',
        sortIndex: 0,
        optionals: optionals,
        isAttack: isAttack,
      ).copyWith()),
];

Map<ActionObjectKind, Set<String>> variableFields() {
  final values = <ActionObjectKind, Map<String, Set<String>>>{};
  for (final donor in _donors) {
    for (final MapEntry(:key, :value) in _json(donor).entries) {
      if (key == 'id') continue;
      ((values[donor.kind] ??= {})[key] ??= {}).add(_same(value));
    }
  }
  return {
    for (final MapEntry(key: kind, value: fields) in values.entries)
      kind: {
        for (final MapEntry(:key, :value) in fields.entries)
          if (value.length > 1) key,
      },
  };
}

({ActionObjectState object, Set<String> fields})? variedObject(
  ActionObjectState object,
  Random random,
) {
  final donors = [
    for (final donor in _donors)
      if (donor.kind == object.kind) donor,
  ]..shuffle(random);
  for (final donor in donors) {
    var json = _json(object);
    final fields = <String>{};
    final donorJson = _json(donor);
    final keys = [
      for (final key in donorJson.keys)
        if (key != 'id' && _same(json[key]) != _same(donorJson[key])) key,
    ]..shuffle(random);
    for (final key in keys.take(1 + random.nextInt(keys.length + 1))) {
      final candidate = {...json, key: donorJson[key]};
      try {
        final made = ActionObjectState.fromJson(object.kind, candidate);
        if (_same(_json(made)[key]) != _same(donorJson[key])) continue;
        json = _json(made);
        fields.add(key);
      } on Object {
        continue;
      }
    }
    if (fields.isEmpty) continue;
    return (
      object: ActionObjectState.fromJson(object.kind, json),
      fields: fields,
    );
  }
  return null;
}
