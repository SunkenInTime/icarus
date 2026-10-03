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
      '112d37d687add17c43eabab0854c7b08ab92c9f72357213287f62f9f8e82d163',
  'abyss_svg_height_defense.json.gz':
      '8f678b402bf79473c57a46a5a026747a2bcd331286f1d9bc554b0ac866734083',
  'ascent_svg_height_attack.json.gz':
      '138f7f7031c2638237f781e0e7504cace968c532ba513efeb1a1a4264672c225',
  'ascent_svg_height_defense.json.gz':
      '44a87dd7d2efafd12139804ce9cac9df2a3ac54520cbbe305ac7ab513a742186',
  'bind_svg_height_attack.json.gz':
      'b6b7cf4c8ea1ee77a38899f5a8f26968bf9eed5578d34fcb45d04f529cca688e',
  'bind_svg_height_defense.json.gz':
      'b6881dc7a398bce58759e579eda503dadb20c9fc33f052edf8d0f4639f1f5ae7',
  'breeze_svg_height_attack.json.gz':
      '3ce6225d845ac75b120cd8103afe283289cff10c97a3175be12497d5018a7e2b',
  'breeze_svg_height_defense.json.gz':
      'ecf3676a91371fd4a58d416fc8e4850c94269ec4776cb543f50f271a50f90fb5',
  'corrode_svg_height_attack.json.gz':
      '41c3275e35141ce858713a7edcd289a353be9972eaa4449b5992adf23b90c436',
  'corrode_svg_height_defense.json.gz':
      '2149dc703d3a76dc5ed72777404e80e9accacf2c9ed3c7e119eeaa1b2d705711',
  'fracture_svg_height_attack.json.gz':
      'b48581952af15ef323fe8f8dd75f2c87ac348d6aef8db7770ca7e3a2977821b4',
  'fracture_svg_height_defense.json.gz':
      '75e6f980a33b51a649fba4b6618d306d623784e7a27f4f23b2151c359a3bf672',
  'haven_svg_height_attack.json.gz':
      '31bdd67192f8b149f6b1e4d67df6ede95be957a61636785c22b9238dc51a307d',
  'haven_svg_height_defense.json.gz':
      '85ebcec99e0d3510280e8f11ab82b1c634161b725d7012186a3baa823e86c7c1',
  'icebox_svg_height_attack.json.gz':
      'f108625eaa126dc86a9c90372c759bdfd26fb3d4734a7d9b48fa02b540498932',
  'icebox_svg_height_defense.json.gz':
      '301cb7e3afdf487ff9f7d6155f2460b0e3f42c4aaff33ab94dc56ac6722d90bc',
  'lotus_svg_height_attack.json.gz':
      'f12cc531c76c8311b1b5961aaf2c28567a88ebcd08adedf7dafad1fdb49d7e3e',
  'lotus_svg_height_defense.json.gz':
      'a7953900963272fb0dd8b0900e5855b530843401752f13657fd020e74eea239a',
  'pearl_svg_height_attack.json.gz':
      'eb11ce4ef4194efb78060878e08f01b567185b78dcdd9dc316387fe71c73ddf6',
  'pearl_svg_height_defense.json.gz':
      '6a3a44b370d3a516c9283e6162cdcc37427df4876cb53e9e50606f226953d73b',
  'split_svg_height_attack.json.gz':
      '98899888438e907dc71ba357a620be5a0e630680788dbafed199c6a0c8ed7027',
  'split_svg_height_defense.json.gz':
      '4e21c6d7f8382ef591d46a0ef73835ed71595bd681d90305ae1cbbbc803621a1',
  'summit_svg_height_attack.json.gz':
      '6abc3e5b87bb150d513f681ad2a489ee67df469dac979a6a33fb42009ec7136c',
  'summit_svg_height_defense.json.gz':
      'd6048b07d1d0e47283885f95e920f666f94fa627ceec4236b46bc6d2906cde38',
  'sunset_svg_height_attack.json.gz':
      '7e0d31947009c6b8a3fc1554f945c958e59c0091dd3bfda0d43902ab7fd00800',
  'sunset_svg_height_defense.json.gz':
      '335811d5a97be0e32e2118dfe7812e48f3c45c926c570821de7a8fcf9a63fd45',
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
