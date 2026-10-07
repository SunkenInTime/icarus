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
      '210088fd675a1ac305be3a089e732a01c410b8c9ade47059cfe188e68bcdfe3b',
  'abyss_svg_height_defense.json.gz':
      'e3dc93b3742be9f91b1142a4ea5acca7073ddf9eb1eafa8b92e71ce10a532a90',
  'ascent_svg_height_attack.json.gz':
      'f28116cb2d8e63d1df4df0b472f9e2e55b26e729e1e27046748709a165e6aabb',
  'ascent_svg_height_defense.json.gz':
      '7d21384c77aaf1a2a71ecf54a8c121d201a390064073e310f6769feafe777299',
  'bind_svg_height_attack.json.gz':
      '7e472e71cff00d682cf8104e6ad0f56542a9db832e1495629dab0983d73d8734',
  'bind_svg_height_defense.json.gz':
      '02330c4a68e3cfdc9fb36040ad1b4df399a1e7db25840924980e8fecf90905d5',
  'breeze_svg_height_attack.json.gz':
      'b075f5e9de265136f20a633dc9cf9a7fb080a2f8f89816780d05ef7c2c38dd4c',
  'breeze_svg_height_defense.json.gz':
      'e76a80e913d353de4c62e88824b9fa3d3382938a4e7fbb0dd7b41e5a4e09166a',
  'corrode_svg_height_attack.json.gz':
      '650ce8932d9423528d29c94a0d503864bbb975129d811040c9011e1190378c60',
  'corrode_svg_height_defense.json.gz':
      '8160364c8d4a23d85ae7fc5f984aaf97c64856ff395cc2fcc3a818bb425e347c',
  'fracture_svg_height_attack.json.gz':
      '8db010a0b1b194c5943b3908e54917f80f075600e37956906319473ed8522d13',
  'fracture_svg_height_defense.json.gz':
      '639195d1003f6b486e1f58c260196a4cf073f8992b7500d095c3b3d877a2fc8a',
  'haven_svg_height_attack.json.gz':
      '1ebf833c6995fbfce16b7cd7583a189b8cb0a4181c273f5776ccce4013cd93d5',
  'haven_svg_height_defense.json.gz':
      '79000efe49b2ac02eb6ca21528b5c8e80b8b9604b3886196e7fbdc9656f94881',
  'icebox_svg_height_attack.json.gz':
      '4d3a7fe225a3830f2ce3d7b6340f83c15aec1494b16a923cc62bdb4595fc10fb',
  'icebox_svg_height_defense.json.gz':
      'ae05fafffee009b74c95e2a2371a25d33bbe3ead432447f677509618c0638361',
  'lotus_svg_height_attack.json.gz':
      'eb73cffe58ba33b26f7a7ad5eb1f4bfe90db228a40f55197545c5f7f73c22ec1',
  'lotus_svg_height_defense.json.gz':
      '949e8b730e50a18cbc7e94b33151e3c7f857dab7c71755190ee8b3796438c2df',
  'pearl_svg_height_attack.json.gz':
      '72c960cc5300435b486a6b6e573f5011c0ba7a420b480e64c9917a648be11f2c',
  'pearl_svg_height_defense.json.gz':
      'aa85aa8230ca9d7bd9d6ff4da780a96833905765cf8eca9d1a5c63b1c13211fc',
  'split_svg_height_attack.json.gz':
      '4757e0a607b40de520c69ebd62f7a48aeb9ec7886c7bebbeadb93e20c686f402',
  'split_svg_height_defense.json.gz':
      'e4371fa3317581d4fc63ce829bdb80dae75173caea1a930eefbe579f27d08daa',
  'summit_svg_height_attack.json.gz':
      '252efd1bfa34e6eeb8d3757bce5f77330022ebcb627d2740d3ead14c58d7f38f',
  'summit_svg_height_defense.json.gz':
      'ff90666de04c1885713d6586a9e099e181944b2d17f76b70f916502025469368',
  'sunset_svg_height_attack.json.gz':
      '779e6bda61ad4960c322bdff9fe6a0d3415d04b78c6cb5da0850023bb7b55bb4',
  'sunset_svg_height_defense.json.gz':
      'e3c1dbf599c1063090efe4bb1f09e78363956019cee3a8af4b9f0478962903c9',
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
