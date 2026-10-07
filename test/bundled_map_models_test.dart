import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bundled SVG-height models are Icarus's drawn walls carrying the
/// heights of VALORANT's minimap vision lines (see docs/vision-model.md). The
/// builder (scripts/riot/build_art.py, then simplify_walls.py) and the
/// vision-line review data live in the icarus-vision-pipeline archive
/// (scripts/riot, tools/vision-lines). Here the models are pinned
/// byte for byte:
/// a change to any of them is a change to what players see and must come
/// with a deliberate update to this table.
const _modelChecksums = <String, String>{
  'abyss_svg_height_attack.json.gz':
      'd2584571cbfa55707b282e001c6d623d55afdbe6bcd4ef49544432db5be9ccbc',
  'abyss_svg_height_defense.json.gz':
      '9a96967a96c7838090ac090dd9abc330a872e17caec252397b49b4e4d1c2f76c',
  'ascent_svg_height_attack.json.gz':
      '00530c60076b564b3ac5020d983de60d1554fdc3e12f97d137b49f9932ba42cb',
  'ascent_svg_height_defense.json.gz':
      'ff1e5cceeb5de9508b7f3d21e4bbd9f52df925293e86a863e6128e51c74d9ed9',
  'bind_svg_height_attack.json.gz':
      '3682c493e305d3ef9d379b42669dedad772dec9297d5cfede79f686281ff0518',
  'bind_svg_height_defense.json.gz':
      'c3190df7b4e5c794b7d7e9724fdf25c7273c19dc5f893d3bbff0638dda48a1c5',
  'breeze_svg_height_attack.json.gz':
      'e8a91f798da33ffae3c70a8f3a684450ad93bab8d77001f5257d0e3f8f645ab6',
  'breeze_svg_height_defense.json.gz':
      '7d2edb1958c90faa72ef49514dd3adbbedc168227ef1c82aafbe6c60838ca862',
  'corrode_svg_height_attack.json.gz':
      '7cb371eda6449d9ae0942352436b37bd6084d2618af00d06567677daa0a7a96c',
  'corrode_svg_height_defense.json.gz':
      '2aa1c1f3e05f9a02e3fd0457cffae200fe39b45a0568132fc9b93ffdfa8630f2',
  'fracture_svg_height_attack.json.gz':
      '187662474f144b49b8c8bfa82ec20a94dc5922f1dcdb100b2860b87787fffcd1',
  'fracture_svg_height_defense.json.gz':
      'd1dea3de3dc3b78f735c6d3d23d5f75cdcae1de02d419d382f74c92b13688c18',
  'haven_svg_height_attack.json.gz':
      '774fa91440c7a17244b7a05abc44298b1637c1b7b37e39cbf0a4d89c5e0c6b4a',
  'haven_svg_height_defense.json.gz':
      'c9805ab93858c83eb65526fa27ca049189fec33348eff56d7d97c98355a4bf25',
  'icebox_svg_height_attack.json.gz':
      '1bb664441d29df5ef6c068dfd3492aab6a86b953645ace1f0be75f7bb57776a6',
  'icebox_svg_height_defense.json.gz':
      'b12626026a08250430a60555875ce1c7217e1fcbac2221c652f509fb3056b6da',
  'lotus_svg_height_attack.json.gz':
      '6794bebee6f8d9f84aa5934b1fb286b5aa8600d0821286428a43ab9d5ada7ad1',
  'lotus_svg_height_defense.json.gz':
      '119c82aa47f99274734382cb6122d97f68bb2221d949174302d289704b7f88d4',
  'pearl_svg_height_attack.json.gz':
      'bc5fc05e3336238ddcd94290389f5eb58fffe70e0f6c5f7ee242f6fb173b27f0',
  'pearl_svg_height_defense.json.gz':
      '0bc5e6e4f3c1bc1dcd0722784e24eb3b8df8ad3b62fdaab061a11f2274429eba',
  'split_svg_height_attack.json.gz':
      '15d8da7276311ea0c3ba090cdb87380000c457888640279988b515db0e1cab28',
  'split_svg_height_defense.json.gz':
      '77b1f0ce8d97dea046666761192a29a3db8b6f78a5b8453436ee7204867c1e3d',
  'summit_svg_height_attack.json.gz':
      '66ede9bacb193ddf99f7ff1c092cbd675bfcca183d3c99b430f5e402d39c88aa',
  'summit_svg_height_defense.json.gz':
      '44ce26d9371526823526ca9bf8c8d94e27b2930574fe3de9681b6e66cd30189c',
  'sunset_svg_height_attack.json.gz':
      '66bfd94fc20b3d0a034dd7791cd45cbf0dad0740a4d6dd7e9467570b96f94d1c',
  'sunset_svg_height_defense.json.gz':
      '733dcb7cdad19541c65b60419f161789ca0c9e5937ebb371a9f804852c9c7ba1',
};

void main() {
  test('the bundled sightline models are the reviewed ones', () {
    final mismatches = <String>[];
    for (final entry in _modelChecksums.entries) {
      final file = File('assets/maps/${entry.key}');
      if (!file.existsSync()) {
        mismatches.add('${entry.key}: missing');
        continue;
      }
      final actual = sha256.convert(file.readAsBytesSync()).toString();
      if (actual != entry.value) mismatches.add('${entry.key}: $actual');
    }
    expect(mismatches, isEmpty,
        reason:
            'A reviewed model changed. Rebuild it with scripts/riot/build_art.py in the '
            'icarus-vision-pipeline archive before updating its checksum.');
  });
}
