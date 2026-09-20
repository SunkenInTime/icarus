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
      'efae5ff3235fea93570b6101d4b05cf0b1c3b49453ccc1dcf05e73b3bb535c17',
  'abyss_svg_height_defense.json.gz':
      '834d4e7eb0519806fb7b113b31367c53603d72ed11aa0b39c05e3968e0d5b31c',
  'ascent_svg_height_attack.json.gz':
      '02fb29f0aa51f86ac4596db9443aad1e3c4679f20fdacf036ed956c44d5753a1',
  'ascent_svg_height_defense.json.gz':
      '0201a07d5ec1fdf101e33ea6b250d6bf430ea33984265708eda2b74229b72fc2',
  'bind_svg_height_attack.json.gz':
      '77f52bf3ac047eb2b84b1b0cb16568864bdcdc435d8bf6e4caf15b59805ab668',
  'bind_svg_height_defense.json.gz':
      '91aea20046a7998f596ae1b38bd8ee930b4ecf871604afb03c9476bd796924c6',
  'breeze_svg_height_attack.json.gz':
      'a8302e514bc4c86aecee75c1e374391aa4cacee0aedcd27114f217cd817a54c4',
  'breeze_svg_height_defense.json.gz':
      'e7c6cb95ae8db3281a418f513434412be096f90fdbb4602ce3c99dc8d1b1ef16',
  'corrode_svg_height_attack.json.gz':
      'b868616bd62feaa009112d3d0910b0e40675f94c6af325e4f1425796c21f8418',
  'corrode_svg_height_defense.json.gz':
      'e6cc0866491c39a4384bccd08604e7b2d0c1a444e0f0539b786f4bf814996233',
  'fracture_svg_height_attack.json.gz':
      'fbf0b3c626f7df5a94a3017405e227c324aee5d3916b1f782ebd9f5c86ee047e',
  'fracture_svg_height_defense.json.gz':
      'e71e906406f61dc5149ceb40a8d9fb2322ab3cea3bc801144d27e6898f515354',
  'haven_svg_height_attack.json.gz':
      '9afd040b67978dc24eb170248ce79e8fa2ddb135673043bc913a2f53d2c25a9c',
  'haven_svg_height_defense.json.gz':
      '0552e538ac487ab9513c1fc569a4fb12b902d824b8f60b2a73a0766d945b592a',
  'icebox_svg_height_attack.json.gz':
      '55637d9c3f63e4d8026965bcfb269d5422a67b09340e2148f7c9e59d0b0f4d67',
  'icebox_svg_height_defense.json.gz':
      'c14c217a50800f85b45f59f45a2940f7becc96612ee05c3dbe1f01f5188013b0',
  'lotus_svg_height_attack.json.gz':
      '6ab074b9ef748a03ffdcc434026c59fba86053ea7c4dbeef41edac1cbb0ddd9a',
  'lotus_svg_height_defense.json.gz':
      '8ade7d992a5a209c6b82079b5f95281ae27f11767e943899f453f9d52d4901cd',
  'pearl_svg_height_attack.json.gz':
      'a8409d077d452a919b8b9242d8ff21fd21be2aa1e2d33c4cedbe29bb6f8e0da5',
  'pearl_svg_height_defense.json.gz':
      '06028e304b8ffe799d7095bee7a5fb939823fda1d3ee8e9c59984be93d5393fe',
  'split_svg_height_attack.json.gz':
      '18f300b48b8a6b20ed6066aef154f9bea6661f297d8be3324158bfb9b26a10fd',
  'split_svg_height_defense.json.gz':
      '4efb5853f85d218a16d96ee8a0f147cd8b8bb90585e1932008ea74b654790b02',
  'summit_svg_height_attack.json.gz':
      '6583a040d047e646d0ef23a545bc7943202008fac0fb6f24d259581a792b10ae',
  'summit_svg_height_defense.json.gz':
      '50a0519df3bc7e4d94df018ad334bae0abddd48f26ce0fe6fbfa3c2628e5cf58',
  'sunset_svg_height_attack.json.gz':
      '6659f36a236903bc0583b8090a016ae0c194920f5f3d3b37f319f7328ee53f4f',
  'sunset_svg_height_defense.json.gz':
      'a17517aa5bdb12b284ac56ced54214ad01c67b778998bdb8c6d3ccf6fb64c922',
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
