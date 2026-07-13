import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/replay_provider.dart';
import 'package:icarus/replay/replay_ability_audit.dart';
import 'package:icarus/replay/replay_track.dart';

void main() {
  test('ability audit entries preserve parser context and corrected position',
      () {
    const entry = ReplayAbilityAuditEntry(
      id: 'audit-1',
      issue: ReplayAbilityAuditIssue.wrongPosition,
      timeMs: 42000,
      castId: 'cast-7',
      targetType: ReplayAbilityAuditTargetType.abilityCast,
      targetId: 'cast-7',
      parsedLabel: 'Viper Toxic Screen',
      icarusPosition: Offset(0.35, 0.64),
      note: 'The wall should begin closer to A Main.',
    );

    expect(entry.toJson(), {
      'id': 'audit-1',
      'issue': 'wrongPosition',
      'timeMs': 42000,
      'castId': 'cast-7',
      'targetType': 'abilityCast',
      'targetId': 'cast-7',
      'parsedLabel': 'Viper Toxic Screen',
      'note': 'The wall should begin closer to A Main.',
      'icarusPosition': {'x': 0.35, 'y': 0.64},
    });
  });

  test('only missing and wrong-position issues request a map point', () {
    expect(ReplayAbilityAuditIssue.missing.needsMapPoint, isTrue);
    expect(ReplayAbilityAuditIssue.wrongPosition.needsMapPoint, isTrue);
    expect(ReplayAbilityAuditIssue.endsLater.needsMapPoint, isFalse);
  });

  test('audit targets distinguish spatial actors from cast signals', () {
    const target = ReplayAbilityAuditTarget(
      type: ReplayAbilityAuditTargetType.utilityActor,
      id: 'actor-5272',
      label: 'Vyse Arc Rose',
    );

    expect(
      target.matches(
        ReplayAbilityAuditTargetType.utilityActor,
        'actor-5272',
      ),
      isTrue,
    );
    expect(
      target.matches(ReplayAbilityAuditTargetType.abilityCast, 'actor-5272'),
      isFalse,
    );
  });

  test('utility actor annotations snapshot durable parser evidence', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(replayProvider.notifier);
    notifier.setTrack(
      const ReplayTrack(
        map: MapValue.ascent,
        players: [],
        recordedDurationMs: 160000,
        utilityActors: [
          ReplayUtilityActor(
            id: 'actor-5272',
            actorNetGuid: 5272,
            chIndex: 186,
            timeMs: 127598,
            closedAtMs: 152339,
            lifetimeMs: 2000,
            observedLifetimeMs: 24741,
            observedStartMs: 127598,
            observedEndMs: 152339,
            fallbackLifetimeMs: 2000,
            fallbackEndMs: 129598,
            effectiveEndMs: 152339,
            closeReason: 0,
            dormant: false,
            endReason: 'round-end',
            lifecycleEvidence: 'observed',
            fallbackDurationSource: 'flash-or-blind-fallback',
            className: 'GameObject_Nox_StealthingTrap_Flash_2',
            archetypePath: '/Game/Abilities/Nox/ArcRose',
            agent: 'Vyse',
            abilityName: 'Arc Rose',
            abilitySlot: 'E',
            phase: 'placed',
            sourceCastId: null,
            confidence: 'static-asset-match',
            durationSource: 'flash-or-blind-fallback',
            evidenceRoles: ['placed-object'],
            position: ReplayActorPosition(x: 100, y: 200, z: 12),
          ),
        ],
      ),
      sourcePath: 'match.vrf',
    );
    notifier.setAbilityAuditEnabled(true);
    notifier.seek(130000);
    notifier.selectUtilityActor('actor-5272');
    notifier.addCustomAbilityAuditNote(
      'Placed here and remained inactive until round end.',
    );

    final entry = container.read(replayProvider).abilityAuditEntries.single;
    final json = entry.toJson();
    final evidence = json['targetEvidence'] as Map<String, dynamic>;

    expect(json['targetType'], 'utilityActor');
    expect(json['targetId'], 'actor-5272');
    expect(json['castId'], isNull);
    expect(evidence, containsPair('stableId', 'actor-5272'));
    expect(evidence, containsPair('actorNetGuid', 5272));
    expect(evidence, containsPair('chIndex', 186));
    expect(
      evidence,
      containsPair('className', 'GameObject_Nox_StealthingTrap_Flash_2'),
    );
    expect(evidence, containsPair('openTimeMs', 127598));
    expect(evidence, containsPair('closeTimeMs', 152339));
    expect(evidence, containsPair('abilityName', 'Arc Rose'));
    expect(evidence, containsPair('agent', 'Vyse'));
    expect(evidence, containsPair('abilitySlot', 'E'));
    expect(evidence, containsPair('phase', 'placed'));
    expect(evidence, containsPair('sourceCastId', null));
    expect(evidence, containsPair('observedLifetimeMs', 24741));
    expect(evidence, containsPair('lifetimeMs', 2000));
    expect(evidence, containsPair('observedStartMs', 127598));
    expect(evidence, containsPair('observedEndMs', 152339));
    expect(evidence, containsPair('fallbackEndMs', 129598));
    expect(evidence, containsPair('effectiveEndMs', 152339));
    expect(evidence, containsPair('closeReason', 0));
    expect(evidence, containsPair('dormant', false));
    expect(evidence, containsPair('endReason', 'round-end'));
    expect(evidence, containsPair('lifecycleEvidence', 'observed'));
    expect(
      evidence,
      containsPair('durationSource', 'flash-or-blind-fallback'),
    );
    expect(
      evidence,
      containsPair('fallbackDurationSource', 'flash-or-blind-fallback'),
    );
    expect(evidence['evidenceRoles'], ['placed-object']);
    expect(evidence['selectedPosition'], {'x': 100.0, 'y': 200.0, 'z': 12.0});
  });

  test('cast annotations retain linked actors and cast evidence', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(replayProvider.notifier);
    notifier.setTrack(
      const ReplayTrack(
        map: MapValue.ascent,
        players: [],
        recordedDurationMs: 60000,
        abilityCasts: [
          ReplayAbilityCast(
            id: 'cast-7',
            timeMs: 42000,
            agent: 'Viper',
            abilityName: 'Toxic Screen',
            abilitySlot: 'E',
            sourceAbilityClass: '/Game/Abilities/Viper/ToxicScreen_C',
            linkedUtilityActorIds: ['actor-10', 'actor-11'],
            confidence: 'observed-stat-update',
            evidenceRoles: ['cast-signal', 'placement-source'],
          ),
        ],
      ),
    );
    notifier.setAbilityAuditEnabled(true);
    notifier.seek(42000);
    notifier.selectAbilityCast('cast-7');
    notifier.addAbilityAuditEntry(ReplayAbilityAuditIssue.correct);

    final json =
        container.read(replayProvider).abilityAuditEntries.single.toJson();
    final evidence = json['targetEvidence'] as Map<String, dynamic>;

    expect(json['castId'], 'cast-7');
    expect(evidence, containsPair('castId', 'cast-7'));
    expect(evidence, containsPair('timeMs', 42000));
    expect(evidence, containsPair('agent', 'Viper'));
    expect(evidence, containsPair('abilityName', 'Toxic Screen'));
    expect(evidence, containsPair('abilitySlot', 'E'));
    expect(
      evidence,
      containsPair(
        'sourceAbilityClass',
        '/Game/Abilities/Viper/ToxicScreen_C',
      ),
    );
    expect(evidence['linkedUtilityActorIds'], ['actor-10', 'actor-11']);
    expect(evidence['evidenceRoles'], ['cast-signal', 'placement-source']);
    expect(evidence, containsPair('confidence', 'observed-stat-update'));
  });

  test('custom notes without a selected target remain supported', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(replayProvider.notifier);
    notifier.setTrack(
      const ReplayTrack(
        map: MapValue.ascent,
        players: [],
        recordedDurationMs: 1000,
      ),
    );
    notifier.setAbilityAuditEnabled(true);
    notifier.addCustomAbilityAuditNote('  General replay note.  ');

    expect(
      container.read(replayProvider).abilityAuditEntries.single.toJson(),
      containsPair('note', 'General replay note.'),
    );
    expect(
      container.read(replayProvider).abilityAuditEntries.single.toJson(),
      isNot(contains('targetEvidence')),
    );
  });
}
