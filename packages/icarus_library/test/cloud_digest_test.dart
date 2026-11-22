import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

final class Knobs {
  Knobs(Random random)
    : page = random.nextBool() ? 'page-a' : 'page-b',
      sortIndex = random.nextInt(2),
      live = random.nextBool(),
      dx = random.nextInt(2),
      cone = Cone.values[random.nextInt(Cone.values.length)],
      nullLabel = random.nextBool(),
      revision = 1 + random.nextInt(3),
      bookkeeping = random.nextInt(3);

  final String page;
  final int sortIndex;
  final bool live;
  final int dx;
  final Cone cone;
  final bool nullLabel;
  final int revision;
  final int bookkeeping;

  List<Object?> get drawn => [page, sortIndex, live, dx, cone.drawn];

  ReadableElementRow get row {
    final payload = ElementPayload(
      kind: ElementKind.agent,
      payloadVersion: 1,
      data: {
        'id': 'e1',
        'elementType': 'agent',
        'position': {'dx': dx, 'dy': 0},
        if (nullLabel) 'label': null,
        ...switch (cone) {
          Cone.hidden => {
            'visualState': {'showVisionCone': false},
          },
          Cone.shownExplicitly => {
            'visualState': {'showVisionCone': true},
          },
          Cone.shownByDefault => {'visualState': <String, Object?>{}},
        },
      },
    );
    final unknown = jsonObject(switch (bookkeeping) {
      0 => const <String, Object?>{},
      1 => {'updatedAt': 1700000000000 + revision},
      _ => {'deletedBy': 'user-$revision', 'updatedAt': 5},
    });
    return live
        ? LiveElement(
            publicId: 'e1',
            pagePublicId: page,
            payload: payload,
            sortIndex: sortIndex,
            revision: revision,
            unknownFields: unknown,
          )
        : DeletedElement(
            publicId: 'e1',
            pagePublicId: page,
            payload: payload,
            sortIndex: sortIndex,
            revision: revision,
            unknownFields: unknown,
          );
  }
}

enum Cone {
  hidden(false),
  shownExplicitly(true),
  shownByDefault(true);

  const Cone(this.drawn);

  final bool drawn;
}

void main() {
  test('two rows have the same digest exactly when they would be drawn the '
      'same', () {
    final random = Random(3);
    var same = 0;
    var different = 0;
    for (var round = 0; round < 3000; round++) {
      final a = Knobs(random);
      final b = Knobs(random);
      final drawnAlike = a.drawn.join('|') == b.drawn.join('|');
      expect(
        rowDigest(a.row) == rowDigest(b.row),
        drawnAlike,
        reason: '${a.row.toJson()} vs ${b.row.toJson()}',
      );
      drawnAlike ? same++ : different++;
    }
    expect(same, greaterThan(20));
    expect(different, greaterThan(20));
  });
}
