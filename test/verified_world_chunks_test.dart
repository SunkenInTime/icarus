import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/verified_world_chunks.dart';

import 'vision_world_chunks_test.dart' show chunks, manifest;

void main() {
  test('verified compressed bytes are owned and immutable', () async {
    final original = chunks();
    final verified = await VerifiedWorldChunks.verify(manifest(), original);
    final name = original.keys.first;
    final before = verified[name]!.first;
    original[name]![0] ^= 1;
    expect(verified[name]!.first, before);
    expect(() => verified[name]![0] ^= 1, throwsUnsupportedError);
    expect(() => verified.clear(), throwsUnsupportedError);
  });

  test(
      'missing hashes or changed compressed payloads cannot enter trusted decoding',
      () async {
    final missing = manifest();
    missing['chunks'][0].remove('sha256');
    await expectLater(
        VerifiedWorldChunks.verify(missing, chunks()), throwsFormatException);
    final changed = chunks();
    changed.values.first[20] ^= 1;
    await expectLater(
        VerifiedWorldChunks.verify(manifest(), changed), throwsFormatException);
    final duplicated = manifest();
    duplicated['chunks'].add(duplicated['chunks'][0]);
    await expectLater(VerifiedWorldChunks.verify(duplicated, chunks()),
        throwsFormatException);
  });
}
