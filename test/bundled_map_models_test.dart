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
      '4feb7ecc7cf76a9455457bcf560f8a85bdfc2c54899d3a54bbc0328c27519f1e',
  'abyss_svg_height_defense.json.gz':
      '178359fef65611fc1a5772f335c84c4afea3c281b14733cf6a6e4665890c9a30',
  'ascent_svg_height_attack.json.gz':
      'cb45b0d82bf851fd977806d0239d88489686e7c73c8f7034b39d8cfaf5c07b86',
  'ascent_svg_height_defense.json.gz':
      '2722b4effa95dd7c66a84326788db40d807b92b2ff1b65d654c18834a2f59b36',
  'bind_svg_height_attack.json.gz':
      '772f224bded0c830906ad2176767f5eecec00545219fd7c31b3f8e23e60af31c',
  'bind_svg_height_defense.json.gz':
      '60be1f179e48f4306af9a2400db402a6fdf1b2cc3b908d0297f651b59cff1ff9',
  'breeze_svg_height_attack.json.gz':
      'b507cc288e7bfbaea723d9846d1de6edd9d986329401c8f11d2746dcda1e2fd2',
  'breeze_svg_height_defense.json.gz':
      '56e30ce61e76d27a346910e4918c35252a0f12ac44384b5b5d66fd2ad99c343d',
  'corrode_svg_height_attack.json.gz':
      '3c1c253c882bb0c5e811f3ff0f13336aff2dfb5e664481dd61087d7f4d5c724b',
  'corrode_svg_height_defense.json.gz':
      'e0b9d89dd192b83463b84e8fb7fc0b790c4814d82933e975bc1efe76f37c6623',
  'fracture_svg_height_attack.json.gz':
      '3e08c19ea5963d1ed2b496992da7485b2486d536ad875474159cd50032b82fe5',
  'fracture_svg_height_defense.json.gz':
      '382ebbec3296a324f7aa2881c7e7cbde598ba602c612b9da221a034d787a05f5',
  'haven_svg_height_attack.json.gz':
      'b91ed8e0a8a368ba7c35443efac0a17f25d0494d29c749e74463654431e99223',
  'haven_svg_height_defense.json.gz':
      'b5c7c43908f86ef429afcb21d43b22f81d3f81f58e91f2a99559e6202b2d3ebe',
  'icebox_svg_height_attack.json.gz':
      'e3aa1b00349f8742c20ff7f0cf89e4b07eed816b859372a2db1f8abbb2dd512f',
  'icebox_svg_height_defense.json.gz':
      '00231910a9d90f65825d6fa8f420ca521098ce86591ede3c0c4f4b2376b05015',
  'lotus_svg_height_attack.json.gz':
      '51b55912f811198993f5a4ef77fc58a965a77c17281fb5b783e00aa9557acef1',
  'lotus_svg_height_defense.json.gz':
      '15f20d847a4108c2e96d9e495afe9918b9b198ec71f9031e9d606a40b8b40e0a',
  'pearl_svg_height_attack.json.gz':
      '1524fce52c4e1deb45aae601d5a1d0b27946a7ee28fc0319ca8e89bc248effad',
  'pearl_svg_height_defense.json.gz':
      'd90adbbaf1244ea235197f104fbe703033d099d7851740546fb8264b265ff2fe',
  'split_svg_height_attack.json.gz':
      'dd66dc44ec94f1986f31bc1f26bae770776370e0189b6b7f984ff4e8bda9c6a9',
  'split_svg_height_defense.json.gz':
      '4a2c6ed92414f132568f3532bb6e59e3375aebde3dde5cd8cab3dec47d5211b1',
  'summit_svg_height_attack.json.gz':
      '69d2f174bf2005e609a1a747c07c321937cbe56e80653cd25de83c95619a4c86',
  'summit_svg_height_defense.json.gz':
      'b109951ecd6d438d6c445b0faafc7dae5ac357a0243c1a6184f9faee5d4c0fff',
  'sunset_svg_height_attack.json.gz':
      'de3317f223ab9aeacd505bd3a5d9ad69a0d4e5a491f956d7ecbb4fa08c04a736',
  'sunset_svg_height_defense.json.gz':
      '1d0a32131cfdda052bcbbf56c50fcaf0139b9f8420b4b57383befb07be95d4d5',
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
