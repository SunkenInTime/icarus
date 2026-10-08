import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bundled SVG-height models are Icarus's drawn walls carrying the
/// heights of VALORANT's minimap vision lines (see docs/vision-model.md). The
/// builder (scripts/riot/build_art.py, simplify_walls.py, then
/// standable_region.py) and the
/// vision-line review data live in the icarus-vision-pipeline archive
/// (scripts/riot, tools/vision-lines). Here the models are pinned
/// byte for byte:
/// a change to any of them is a change to what players see and must come
/// with a deliberate update to this table.
const _modelChecksums = <String, String>{
  'abyss_svg_height_attack.json.gz':
      '9c3d48be126c2e21c4fe3ff2bbee9c7df4e2500c9cb14750da0cef97aaf43885',
  'abyss_svg_height_defense.json.gz':
      '3a288df5dc74a5b0eca11c548b8cc8f9120a58845f62c16fce7a43afd20cd527',
  'ascent_svg_height_attack.json.gz':
      '6d775427d0241e8860689dcb92bd690f0a44104523b8d1d11e79c86469e1eeb6',
  'ascent_svg_height_defense.json.gz':
      '12c80b1f9b0ba7a51e63a4bf0fb6bec3d5414902723f98ef360a045ef4857b10',
  'bind_svg_height_attack.json.gz':
      '7616ea72c30349ad9044dcb375271ec8d8296bf909bb9d12b0ff7eacf910f2c6',
  'bind_svg_height_defense.json.gz':
      'e0713e260e090344c16794ce877699b4d88418eb62f037612294a466085cc1fa',
  'breeze_svg_height_attack.json.gz':
      '41121f5d241ba198e4b2ffbc8bab9504633c9d870c87ce827c4923d3c2268fec',
  'breeze_svg_height_defense.json.gz':
      'ee04a377e1082c5080659789ff02596b2eb2796d5acf98be2d3cd6ea788c3628',
  'corrode_svg_height_attack.json.gz':
      'dfad83fc2e4e8b1679436bf78e54e613297b35c60d70611a26428e679c9b8d5c',
  'corrode_svg_height_defense.json.gz':
      '65a2d1767046089ca1f9ed56b0161019baa2c02ac0fc8bc88b581b75f2b4f6a7',
  'fracture_svg_height_attack.json.gz':
      '07927995f777251855c13592d45ff310e72d18d43d540a1f5d123e450aa5009a',
  'fracture_svg_height_defense.json.gz':
      'ebc74449243dc74661825821c7722b6a711b1e61790031a9490cecc8fea9c927',
  'haven_svg_height_attack.json.gz':
      'b42c4d4b84b1907c3ce869e4b9cb9527f3e518369db5c4a3437c4b674eea271b',
  'haven_svg_height_defense.json.gz':
      '4fb1a7e35369bfefedf3872ae61fecb5d6b6ec00d6b02651628af5827df8ada0',
  'icebox_svg_height_attack.json.gz':
      'a1f28a03c6b43db4fdc5b0cf6a36a0fb2b8c8a07ff136cc16aeca9c161a28a80',
  'icebox_svg_height_defense.json.gz':
      'f004a4235c6a745a2295c4451a6336c517f479e424d9772915e81104217cc0c0',
  'lotus_svg_height_attack.json.gz':
      '3ddc1cfe05e6f59acd4dec6be69986486b5027eec0f3a10281601106b2dc24a5',
  'lotus_svg_height_defense.json.gz':
      'f0e50087ee237984ec62943ecd17425c9f84a5d539185baaf784655f722a8154',
  'pearl_svg_height_attack.json.gz':
      '1bef65b9f6934a5efae0de0cb46dd7d9824db729f58799dd7e4dabad7431bebd',
  'pearl_svg_height_defense.json.gz':
      '3a5b255b8e53c02855b99faf8cd996f4d17aea52c5a17e8c98b61298fd52aef2',
  'split_svg_height_attack.json.gz':
      '93af31f7772c1f116087ea2fce95b51bb572889bb560a68be1d6fd39ff0ada4a',
  'split_svg_height_defense.json.gz':
      'f45d2c43583a6fa8b72f1a29e411997523f8b45b79006f9f3fd61efef1c27beb',
  'summit_svg_height_attack.json.gz':
      'd8d0bd9e9180e86cc698b87ebfe6c5ce1360dd7cd1c0d84a9861524dbb02f651',
  'summit_svg_height_defense.json.gz':
      'b011b0702e8071f8eddf0d3f98b7b2afec42642862b2c658eac2676ab0c5a413',
  'sunset_svg_height_attack.json.gz':
      '4b29fbd8c666c6bec7b99f86e1296e82ccd7fee209525710a3f19eebf99de1d3',
  'sunset_svg_height_defense.json.gz':
      '74f84dd477928a91e08dd445b27c89a88ace1ea13a7c03a7a28c212ed7326f87',
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
