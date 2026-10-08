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
      'dff154814ee5401021c9e004b2ba8f01637d54e42b88d018c007fd0a823e489c',
  'abyss_svg_height_defense.json.gz':
      'ec5a437868f295e3a6d72a7436bd6dcf9f8b4d09f79eca56bba8d444b433a768',
  'ascent_svg_height_attack.json.gz':
      'f842b39b438a19dee2839e9d1b2a9a2c78800d80e901833d81356232685928e1',
  'ascent_svg_height_defense.json.gz':
      'a3279a55df1d92ac81078b4f54714806deda19855681970de50c8859dd4ddf91',
  'bind_svg_height_attack.json.gz':
      '4c48a186c90804027be946d77e4129ddd41e06b938a7a8b13670da1dece45a3a',
  'bind_svg_height_defense.json.gz':
      '4d00c2eb66c462ffc7b4640669f6e914267ad146d8fcc7cfdfc2370616693055',
  'breeze_svg_height_attack.json.gz':
      '4fe90013d02fa6c4477b66c7b358111897edbf25a2c5de25488a83f605f643ea',
  'breeze_svg_height_defense.json.gz':
      '12ec25008693fad55e25306061b3bcdad9674302f009ad37d06a8b1576b12daf',
  'corrode_svg_height_attack.json.gz':
      '9f4e71015c7de0bcee1edd05462a359d4af7a52b17b68c5840b6efc851643eb8',
  'corrode_svg_height_defense.json.gz':
      '5c714f4ae1acb29301cf7050adbfc4408049ecf5229a274adf33bca47f4659c5',
  'fracture_svg_height_attack.json.gz':
      '56fd21f5bc6471ccafb749717ee6e0d42abcef475716d9ee86ec8667ee00eb81',
  'fracture_svg_height_defense.json.gz':
      'a83e642331012022a1945fb9ac845444712f7166924a507ca5cb3fa9e9713603',
  'haven_svg_height_attack.json.gz':
      '38e0d487a5156d2455035d57bd35853caf58783d3340e58d04ca1b302f782c4e',
  'haven_svg_height_defense.json.gz':
      '740a85da620541ed5ea4d81c7fad0ebc0e82d5f00dfd26091933315b2d8ad109',
  'icebox_svg_height_attack.json.gz':
      '14c2f881e8b60580203b13d9a3bb9ed2579ab48ec9454c52d21fc28faf07b1bc',
  'icebox_svg_height_defense.json.gz':
      'ec1ebf2ecc2b3927e989848496c93b634e13fb2bc312e64bacb683faeebbcbe4',
  'lotus_svg_height_attack.json.gz':
      '0527bf2bc6117440cd3f6e71bd4dbcd80904872c4763921ad59005073ecae74f',
  'lotus_svg_height_defense.json.gz':
      'a383b684a5776815812f051cf157f6d8e046799926ec093d15c44b2054637aaa',
  'pearl_svg_height_attack.json.gz':
      'bd791fe2bb66d46bce0bc76f7abcf16e52bdc2b6ac85c1ff78af1365d7d87587',
  'pearl_svg_height_defense.json.gz':
      'e96fa168887a1c740869930fb614c086dd794e60b7de105cea3cfa0c4ac1c6df',
  'split_svg_height_attack.json.gz':
      'd1ea513306060516d0a9ae0cd281ac52a4c657af6ab8f540e3f6640f25137ca1',
  'split_svg_height_defense.json.gz':
      '03032ff9ede8033396c1dae06cacd39ec0b9d73bf67a7b9796071cd6cf388a20',
  'summit_svg_height_attack.json.gz':
      '96804aa7475e9e88c969925714e90e90fcbee1e7e16400d10f9be6e29ddce6ee',
  'summit_svg_height_defense.json.gz':
      'de513661f688b5da16e532e23cd8f4670a8ebfaa9c76aec9bf5a2a0f8b778372',
  'sunset_svg_height_attack.json.gz':
      '7f6f8594c09adcb4fc8ffb57ba95f8bde99ba0e8d5821cf143cae60d75067d66',
  'sunset_svg_height_defense.json.gz':
      '244d50e0709535730b6b9ec82e5987f51d08eeaf5e0b6067df1f299e325648e2',
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
