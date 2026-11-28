import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

final _account = Account('face-account');

SyncState _faceOf(Tally tally, {Network network = Network.online}) =>
    syncStateOf(
      OwnedBy(_account),
      tally,
      network: network,
      signedIn: SignedInAs(_account),
    );

Tally _random(Random random, {required bool outstanding}) {
  int some() => random.nextInt(3) == 0 ? 0 : 1 + random.nextInt(4);
  if (!outstanding) {
    return Tally(standing: Standing.good, notYetRead: random.nextInt(30));
  }
  final pick = random.nextInt(8);
  return Tally(
    standing: pick == 7
        ? Standing.values
              .where((s) => s != Standing.good)
              .elementAt(random.nextInt(Standing.values.length - 1))
        : Standing.good,
    waiting: {
      for (final why in Underway.values)
        if (pick == 0 || random.nextInt(4) == 0) why: 1 + random.nextInt(3),
    },
    attention: {
      for (final why in Attention.values)
        if (pick == 1 && random.nextInt(3) == 0) why: 1 + random.nextInt(3),
    },
    unreadable: pick == 2 ? 1 + random.nextInt(3) : 0,
    readsOwed: pick == 3 ? 1 + random.nextInt(3) : 0,
    readsRefused: pick == 4 ? 1 + random.nextInt(3) : 0,
    setAside: pick == 5 ? 1 + random.nextInt(3) : 0,
    notYetRead: some(),
  );
}

bool _anythingOutstanding(Tally tally) =>
    tally.standing != Standing.good ||
    tally.waiting.isNotEmpty ||
    tally.attention.isNotEmpty ||
    tally.unreadable > 0 ||
    tally.readsOwed > 0 ||
    tally.readsRefused > 0 ||
    tally.setAside > 0;

void main() {
  group('pages the store has never read', () {
    test('with nothing of the player\'s outstanding, any number of them is '
        'all saved, online and offline', () {
      final random = Random(7);
      for (var n = 0; n < 2000; n++) {
        final tally = _random(random, outstanding: false);
        for (final network in Network.values) {
          expect(
            _faceOf(tally, network: network),
            const AllSaved(),
            reason: '$tally on $network',
          );
        }
      }
    });

    test('with anything of the player\'s outstanding, the face is never '
        'saved, whatever they add', () {
      final random = Random(11);
      var generated = 0;
      for (var n = 0; n < 5000; n++) {
        final tally = _random(random, outstanding: true);
        if (!_anythingOutstanding(tally)) continue;
        generated++;
        for (final network in Network.values) {
          expect(
            _faceOf(tally, network: network),
            isA<Outstanding>(),
            reason: '$tally on $network',
          );
        }
      }
      expect(generated, greaterThan(4000));
    });

    test('total counts every part of the tally but pages not yet read', () {
      final tally = Tally(
        standing: Standing.good,
        waiting: {for (final why in Underway.values) why: 1},
        attention: {for (final why in Attention.values) why: 1},
        unreadable: 1,
        readsOwed: 1,
        readsRefused: 1,
        setAside: 1,
        notYetRead: 9,
      );
      expect(tally.total, Underway.values.length + Attention.values.length + 4);
    });

    final single = <String, Tally>{
      for (final why in Underway.values)
        'one edit ${why.name}': Tally(
          standing: Standing.good,
          waiting: {why: 1},
        ),
      for (final why in Attention.values)
        'one edit needing the user, ${why.name}': Tally(
          standing: Standing.good,
          attention: {why: 1},
        ),
      'one unreadable entry': Tally(standing: Standing.good, unreadable: 1),
      'one owed read': Tally(standing: Standing.good, readsOwed: 1),
      'one refused read': Tally(standing: Standing.good, readsRefused: 1),
      'one edit set aside': Tally(standing: Standing.good, setAside: 1),
      for (final standing in Standing.values)
        if (standing != Standing.good)
          'standing ${standing.name}': Tally(standing: standing),
    };
    for (final MapEntry(key: name, value: tally) in single.entries) {
      test('$name, beside pages not yet read, is not saved', () {
        final beside = tally.plus(
          Tally(standing: Standing.good, notYetRead: 4),
        );
        expect(_faceOf(beside), isA<Outstanding>());
      });
    }
  });
}
