import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/field_merge.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';

// Pages with many lineups, or cloud groups with many links, must not cost
// time that grows with the square of their size. Each size below takes
// seconds when the work is quadratic and milliseconds when it is linear, so
// the two-second limit leaves room for a slow machine either way.
const _limit = Duration(seconds: 2);

PlacedAgent _agent(String id, [Offset position = const Offset(1, 2)]) =>
    PlacedAgent(
      id: id,
      type: AgentType.sova,
      position: position,
      isAlly: true,
    );

PlacedAbility _ability(String id) => PlacedAbility(
      id: id,
      data: AgentData.agents[AgentType.sova]!.abilities.first,
      position: const Offset(3, 4),
      isAlly: true,
    );

LineUpGraph _origins(int count) => LineUpGraph(
      origins: [
        for (var i = 0; i < count; i++)
          LineUpOrigin(id: 'o$i', agent: _agent('o$i')),
      ],
      landings: [
        for (var i = 0; i < count; i++)
          LineUpLanding(id: 'l$i', ability: _ability('l$i')),
      ],
      links: [
        for (var i = 0; i < count; i++)
          LineUpLink(id: 'k$i', originId: 'o$i', landingId: 'l$i'),
      ],
    );

/// The legacy projection as it was written before it grouped links by
/// origin: what 4.6.3 reads after a rollback must not change.
List<LineUpGroup> _scanningProjection(LineUpGraph graph) {
  final landingsById = {
    for (final landing in graph.landings) landing.id: landing,
  };
  return [
    for (final origin in graph.origins)
      LineUpGroup(
        id: origin.id,
        agent: origin.agent.copyWith(lineUpID: origin.id),
        items: [
          for (final link in graph.links)
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

String _encode(List<LineUpGroup> groups) =>
    jsonEncode([for (final group in groups) group.toJson()]);

Map<String, dynamic> _group(int links, {String notes = ''}) => {
      'kind': 'lineups',
      'payloadVersion': 1,
      'data': {
        'id': 'g',
        'origins': [
          {
            'id': 'o',
            'agent': {'id': 'a'},
          },
        ],
        'landings': [
          for (var i = 0; i < links; i++)
            {
              'id': 'l$i',
              'ability': {'id': 'b$i'},
            },
        ],
        'links': [
          for (var i = 0; i < links; i++)
            {'id': 'k$i', 'originId': 'o', 'landingId': 'l$i', 'notes': notes},
        ],
      },
    };

void main() {
  group('legacy projection', () {
    test('writes what the scanning projection wrote, duplicates included', () {
      // Interleaved origins, a repeated origin id, a repeated landing id, a
      // link whose landing is gone and a link whose origin is gone.
      final graph = LineUpGraph(
        origins: [
          LineUpOrigin(id: 'a', agent: _agent('a', const Offset(10, 10))),
          LineUpOrigin(id: 'b', agent: _agent('b')),
          LineUpOrigin(id: 'a', agent: _agent('a', const Offset(20, 20))),
          LineUpOrigin(id: 'empty', agent: _agent('empty')),
        ],
        landings: [
          LineUpLanding(id: 'x', ability: _ability('x1')),
          LineUpLanding(id: 'y', ability: _ability('y')),
          LineUpLanding(id: 'x', ability: _ability('x2')),
        ],
        links: [
          LineUpLink(id: 'k1', originId: 'a', landingId: 'x', notes: 'one'),
          LineUpLink(
            id: 'k2',
            originId: 'b',
            landingId: 'y',
            youtubeLink: 'https://youtu.be/abc',
            images: [SimpleImageData(id: 'img', fileExtension: '.png')],
          ),
          LineUpLink(id: 'k3', originId: 'a', landingId: 'y', notes: 'three'),
          LineUpLink(id: 'k4', originId: 'a', landingId: 'gone'),
          LineUpLink(id: 'k5', originId: 'gone', landingId: 'x'),
          LineUpLink(id: 'k1', originId: 'b', landingId: 'x', notes: 'again'),
        ],
      );

      expect(
        _encode(graph.toLegacyGroups()),
        _encode(_scanningProjection(graph)),
      );
    });

    test('20,000 lineups project in linear time', () {
      final graph = _origins(20000);
      final watch = Stopwatch()..start();
      final groups = graph.toLegacyGroups();
      watch.stop();

      expect(groups, hasLength(20000));
      expect(groups.last.items.single.id, 'k19999');
      expect(watch.elapsed, lessThan(_limit));
    });
  });

  test('editing the placement of 10,000 lineups from one spot is linear', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final graph = LineUpGraph(
      origins: [LineUpOrigin(id: 'o', agent: _agent('o'))],
      landings: [
        for (var i = 0; i < 10000; i++)
          LineUpLanding(id: 'l$i', ability: _ability('l$i')),
      ],
      links: [
        for (var i = 0; i < 10000; i++)
          LineUpLink(id: 'k$i', originId: 'o', landingId: 'l$i'),
      ],
    );
    final notifier = container.read(lineUpProvider.notifier)..fromHive(graph);

    final watch = Stopwatch()..start();
    notifier.startEdit('k0');
    watch.stop();

    final edit = container.read(lineUpProvider).edit!;
    expect(edit.linkIds, hasLength(10000));
    expect(edit.originIds, {'o'});
    expect(edit.landingIds, hasLength(10000));
    expect(watch.elapsed, lessThan(_limit));
  });

  test('20,000 landings register and unregister their hitboxes in linear time',
      () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final registry =
        container.read(lineUpAbilityHitboxRegistryProvider.notifier);

    final watch = Stopwatch()..start();
    for (var i = 0; i < 20000; i++) {
      registry.register(
        landingId: 'l$i',
        globalRect: Rect.fromLTWH(i.toDouble(), 0, 10, 10),
      );
    }
    final registered = container.read(lineUpAbilityHitboxRegistryProvider);
    expect(registered, hasLength(20000));
    expect(registered['l7']!.globalRect, const Rect.fromLTWH(7, 0, 10, 10));
    for (var i = 0; i < 20000; i += 2) {
      registry.unregister(landingId: 'l$i');
    }
    watch.stop();

    expect(
        container.read(lineUpAbilityHitboxRegistryProvider), hasLength(10000));
    expect(watch.elapsed, lessThan(_limit));
  });

  test('merging a cloud lineup group of 3,000 links is linear', () {
    final base = _group(3000);
    final desired = _group(3000, notes: 'edited');

    final watch = Stopwatch()..start();
    final fields = lineupMergeFields(base, desired)!;
    final baseValues = mergeBaseValues(base, fields, lineup: true);
    final merged =
        mergedPayload(base, desired, FieldMerge(fields: fields), lineup: true)!;
    watch.stop();

    expect(fields, hasLength(3000));
    expect(baseValues['links/k5'], {
      'id': 'k5',
      'originId': 'o',
      'landingId': 'l5',
      'notes': '',
    });
    expect(merged['data'], desired['data']);
    expect(watch.elapsed, lessThan(_limit));
  });
}
