import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bundled SVG-height models are Icarus's drawn walls carrying the
/// heights of VALORANT's minimap vision lines (see docs/vision-model.md). The
/// builder and the vision-line review data live in the icarus-vision-pipeline
/// archive (scripts/riot, tools/vision-lines). Here the models are pinned
/// byte for byte:
/// a change to any of them is a change to what players see and must come
/// with a deliberate update to this table.
const _modelChecksums = <String, String>{
  'abyss_svg_height_attack.json.gz':
      '2efd891c820b49662168203ba084e349ddef6b62b9fb760831948ed5b2a07e75',
  'abyss_svg_height_defense.json.gz':
      '08876116987344607b6ae08a619b8fcf6c424bf8ac53faaaa24c92e06c120c2d',
  'ascent_svg_height_attack.json.gz':
      '39d06bd74bb962630b61dddd63447238b3a22d6235ece95cd60e776e4a3918ac',
  'ascent_svg_height_defense.json.gz':
      '29d1080574d37f31b85efd371c22f67e48cf4acb2662255bffb8bac68b965277',
  'bind_svg_height_attack.json.gz':
      '13e9680c88ae6989ef582b410dcbc1d930d8097774b484d7722cfe1416535315',
  'bind_svg_height_defense.json.gz':
      '7bed0e61750783422aa7b2bf009d3c576568bd02bd5db58e7662e46fa67ed12a',
  'breeze_svg_height_attack.json.gz':
      '1a9287a82ce1eb1f0edb5ceaf97cf3f13b76091f2366ed817e5ffae22c1808ad',
  'breeze_svg_height_defense.json.gz':
      '9822b7d9e3c030b5534df0cfd18e9f0a50dbbc01f852ec53352f9b39299ac006',
  'corrode_svg_height_attack.json.gz':
      '4d65594c98fc61c149a6a137bbd316d7839b8607b9974acc827e92be224d1d94',
  'corrode_svg_height_defense.json.gz':
      'cc4517b64581adc5b6b7b0ed2fcb92e4c26603c91447d3f39f79eef929c63814',
  'fracture_svg_height_attack.json.gz':
      '5daf8f9cc4800489aabfeb88db5c3e5e8b9d03396c0932ff8382f61c8a442ffe',
  'fracture_svg_height_defense.json.gz':
      '7f4ea636fbd686a323aebada34e2050919ff4b663a5c43c959782d804d994b99',
  'haven_svg_height_attack.json.gz':
      'f902425198ac4aa968fa06874a512d60a07edf3823b0b8b0693dc713e90fc4dc',
  'haven_svg_height_defense.json.gz':
      '8887a7791b1d39e12ed0f78ef93bfc2adfe0b1ae102affdaf40064f6695c96b2',
  'icebox_svg_height_attack.json.gz':
      'ed081dc9e6e02a2a6d946fd27d69521ab385cc254e9218ab078e589f83100b82',
  'icebox_svg_height_defense.json.gz':
      'ed5a85ed24fb4d8b3050c857d7137629b07f1f92348e28e31e215a03c1f8ceb0',
  'lotus_svg_height_attack.json.gz':
      'd2d364129082fd35ea55522858bed1b57ee03a02f8b10bc502ab0b9cc71427f3',
  'lotus_svg_height_defense.json.gz':
      '5a53e24274f4193f002ef6349cb6ca634fa14b63d624bdfe0255ee558409b023',
  'pearl_svg_height_attack.json.gz':
      '547d61b0ec3676df80b2896328352adf891a8ea56dc5e6f57da0b314bd3942f5',
  'pearl_svg_height_defense.json.gz':
      '65bb5b30ab76dbb010b797fa33247da2cc32c6436f90cf698a8d6a6600e72e9d',
  'split_svg_height_attack.json.gz':
      'ca8b2ffc6941213f1b93e3b70e1e10b95743974d2b5a8bc3dcf2119cbf5caa1d',
  'split_svg_height_defense.json.gz':
      'd34897a613ead251e40cb5446501caab2a4618b24d4a2c25b9da7d142da628aa',
  'summit_svg_height_attack.json.gz':
      'd06b746c1f11751b7949341b2c565fa474b83c6d1d89a2aaccd7c4188fb461a7',
  'summit_svg_height_defense.json.gz':
      '05ba028108585dc080c260b866fdf6dcbb67da9e1f03a32bc6a80cbd9c4d50fb',
  'sunset_svg_height_attack.json.gz':
      '8389755dc8fb836481c72ab068fa15febc2dab79094e5d79bb4c95e4679553fa',
  'sunset_svg_height_defense.json.gz':
      'f6d40a84e990baf93a0f6aa1947a7ff2c9ee6b3320101ed39b79b8435099e502',
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
