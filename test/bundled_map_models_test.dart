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
      '9a76dc2a32eea99d9d64c017986263f413950719398fa30705de5f90949b6de0',
  'abyss_svg_height_defense.json.gz':
      'd24d6d3b4a836042a916a31bec6d5939c94eb412728d4753cb5477106b516482',
  'ascent_svg_height_attack.json.gz':
      '2517ceba7225d96d767e8107a990e176a3435ea085f1e0633f412e02a841e7ad',
  'ascent_svg_height_defense.json.gz':
      '7476f049b484037f56c3dd96979cefd9d521f0fbc73344bae61cff5b8801e31d',
  'bind_svg_height_attack.json.gz':
      '5f8aa5daae01f0e3b9aa2edad264f0e6f63d9480931556f0256fda2cf6c63389',
  'bind_svg_height_defense.json.gz':
      '068ec488e0c8a31f4074b6acfe527d6b066cc326afa83dd5c23e0ad9f9ec056d',
  'breeze_svg_height_attack.json.gz':
      '751001e3bd813a77171782e3b78b8e3649db96683c3e9f293301bfcd8a6b61fb',
  'breeze_svg_height_defense.json.gz':
      '96522c95bf766dbefe9e6d2740577610d6ba3947f61319406abf36030781642c',
  'corrode_svg_height_attack.json.gz':
      '674374f4130c571afa11e826a0371fbebc55156e6a555ad6d383e9e3e4d34b69',
  'corrode_svg_height_defense.json.gz':
      '7bd9a7dbfefe8029ce807e5b49ca1f0b4f5577584882458bdd80a7eef9dd4583',
  'fracture_svg_height_attack.json.gz':
      '49122140add3dc22081b1a3d9e87abbc817b05d30cb7b4918814ba9f5801d961',
  'fracture_svg_height_defense.json.gz':
      'd3d2809d8f958f376308f3319980bc8579fc8a477267cd77966891d348f9ad5b',
  'haven_svg_height_attack.json.gz':
      '4e2f4f1e70867b57144976a6a1997ed45097ecd70b1e21e9a0cdf9e7813c4e80',
  'haven_svg_height_defense.json.gz':
      '757b9aa2314fac63a38afa03d7eaf4a72f973ff3fbf946bdab6dbeb2d44acb96',
  'icebox_svg_height_attack.json.gz':
      'bab33c0eb5d3dff14c36e271984dead4a2e4827b24a46532fb5c78ab77ea2cd1',
  'icebox_svg_height_defense.json.gz':
      '66fdc3e2376dd47ebc17d0b394b97499a6734df24b9b226dc062c9ccba95f20f',
  'lotus_svg_height_attack.json.gz':
      'b37dc096a332b6e8f2d4d66f8db3d785043d90fb1124b568f729e030b5f13f22',
  'lotus_svg_height_defense.json.gz':
      'ef6ef5225b23c94a28ee72d4e11a4449043cdb7d5fbda0826fdd6c0d9bc4f1c5',
  'pearl_svg_height_attack.json.gz':
      'c9b879e427d5fed9d2d31bf15370ab1480c45bd253971007110089a0ca752349',
  'pearl_svg_height_defense.json.gz':
      '1ced5df72344201f592cae62e75ee925bebb5f48f3961be87b7e9ec389ab34de',
  'split_svg_height_attack.json.gz':
      '8f15e4cca4d8dea76792f0131db2f1078fc95bf8107d7b5743c3205546861659',
  'split_svg_height_defense.json.gz':
      'bc50f5ea5ff41f986f87c95167f902c9950b67ebc3cc664dd428f80c42863d6e',
  'summit_svg_height_attack.json.gz':
      '41c5236500984c3a3bdbef82967e5b3ffa7cdad1067b434e9b2f0a1d36c1aa08',
  'summit_svg_height_defense.json.gz':
      '9039b9bf7fb672d8d662f716a44908ea947282160717092fd2943cf916d47598',
  'sunset_svg_height_attack.json.gz':
      '42eb85d608a85b83718057e2a2ce1ff2726aeb60241770db8f026b4666363a7a',
  'sunset_svg_height_defense.json.gz':
      '75df5257f04af547baf300e90ba4d2e690a91fe36a596537ba0d5a8e7cbb47e0',
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
