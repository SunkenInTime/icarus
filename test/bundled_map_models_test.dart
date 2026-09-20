import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bundled SVG-height models encode every sightline ruling Dara made
/// during the 2026-09 review (see docs/vision-model.md). The per-ruling
/// acceptance tests and the pipeline that produced these files live in the
/// icarus-vision-pipeline archive. Here the models are pinned byte for byte:
/// a change to any of them is a change to what players see and must come
/// with a deliberate update to this table.
const _modelChecksums = <String, String>{
  'abyss_svg_height_attack.json.gz':
      'b2e45e77cf67b2018a1eb13461d5a975ae94a240e51bd35b2d14d609b3f7aca1',
  'abyss_svg_height_defense.json.gz':
      'be52b771b1fe22273042ae61ed48314904ef4729a1153af3881a048439a26e21',
  'ascent_svg_height_attack.json.gz':
      'ce495b8a06a4bf30b32a559824f5fc81567f8ba033e93cbefe022b9ff0c10838',
  'ascent_svg_height_defense.json.gz':
      '66a9012376eeb9f54d7d264c6845b247e8864ffe486bfee07370724ca59c00e8',
  'bind_svg_height_attack.json.gz':
      '9d2ddbcdc3f25e840a3b526f88c0a2b8c6f4d9dc04dea72d28f337f89d0cfbc2',
  'bind_svg_height_defense.json.gz':
      '37a7683f40e1c7e7ba67eae38dd61eb6b04d4ae6372f3816d9264678ff93d162',
  'breeze_svg_height_attack.json.gz':
      'fef3ec33f95ae5c77fc1ab31dc71a7dc0fe9bfc1af4f917cd7cf3fb657c742d1',
  'breeze_svg_height_defense.json.gz':
      '5109a94c5e9cd13cbb69d0b147f736c41a6339729c1584ead09f4e1108fff3ac',
  'corrode_svg_height_attack.json.gz':
      'd200095c98eb9e189c197586732ebba7cb2570ed5f8037b6f02729dfdbe017b0',
  'corrode_svg_height_defense.json.gz':
      '54b27281f869b412dad7700fd58e244e516a959812b3c9b400b911533fd503d4',
  'fracture_svg_height_attack.json.gz':
      '890f034ea27fff6ebc303e84d7402fcda5afbc7cf6683b0354332af479a0644f',
  'fracture_svg_height_defense.json.gz':
      'c383859031437ef325b41b167f77c94304cc7713faf63019d01bbefaff8b715b',
  'haven_svg_height_attack.json.gz':
      '1039117629baaeaa33854d211fccb2f0f954b5dac8142f691ff2085912b2a698',
  'haven_svg_height_defense.json.gz':
      'c4dfcccb8bf8c1bcead2a03b065d86da5fb2b24b950d7d7ce68dea4124716a9e',
  'icebox_svg_height_attack.json.gz':
      '1607fbf36e5b7a6ac4754045ffbc8620db20f8c860682c13ea68e5cef4c67046',
  'icebox_svg_height_defense.json.gz':
      '8ab68f9d1d4440ddf53df03148dd61bc9d7c3a8590f1fb31e8fb913cc20436bc',
  'lotus_svg_height_attack.json.gz':
      'b01c6ab15da8fcecedf266170e939cd0dff69c63f7655f4a324cabe8e69d1df8',
  'lotus_svg_height_defense.json.gz':
      '50b8a0e32ac32b9b3b6be7ae1f0ea8ea30eeaedc324b67cf34bf1b9118877a52',
  'pearl_svg_height_attack.json.gz':
      '7a078449855b2d0cf533faa8f10aa7f321fd429394e55da8c75e09a4905ddeee',
  'pearl_svg_height_defense.json.gz':
      'c8b740a8b24822ef67b6257af3280ed528ec32ca94955a8952c0127c2c1ae8f1',
  'split_svg_height_attack.json.gz':
      'c9ca7a35ede79a6026194f669a40f918031b9f3cf9bae2821859fa382fa841b3',
  'split_svg_height_defense.json.gz':
      '599f2abfab3e0bcbe06cd2142aaebfcc9031e18acb6dd680fe67249317f1d273',
  'summit_svg_height_attack.json.gz':
      '0ecd8736cc30dacec73ba7eb301fbc696b13d85efe3a998727d0d43751d29e6a',
  'summit_svg_height_defense.json.gz':
      '82457a0b7a0e0e2f32a003c04961231082b58b1c5fa22c387155fcce7518198c',
  'sunset_svg_height_attack.json.gz':
      '2846864192601bd89b619c114701c487dbe49a02a0e1d2bcf2b1f70f40fb5872',
  'sunset_svg_height_defense.json.gz':
      'ab0ca460f6dc1ffc91a2c519a25d5ebae925c5602d8dfb24e81f0d0311673a00',
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
        reason: 'A reviewed model changed. Re-run the sightline review in the '
            'icarus-vision-pipeline archive before updating its checksum.');
  });
}
