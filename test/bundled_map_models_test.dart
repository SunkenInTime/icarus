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
      'f488edb3b0562bcbaa3e25ea0348e378e9d8ec312d120066609fb039813ee899',
  'abyss_svg_height_defense.json.gz':
      '212ca6f27acb1c198bfca941fabb6a076fcd9caecbea2269d3293953dfbce382',
  'ascent_svg_height_attack.json.gz':
      '3ec96bde5bc29d274701e298895e1725e5ed8d0c76223583e33051876d32af94',
  'ascent_svg_height_defense.json.gz':
      '6b7a3f69625af2708062ae5143c131ffb6eee7d4bcb0b47f81e522311dd91902',
  'bind_svg_height_attack.json.gz':
      '2a4f41443499dec9da8c3cf54d16feac814976af29941ff469a2dca09fe808da',
  'bind_svg_height_defense.json.gz':
      '14c0aa0427a7166e7e07e3da112cc8e030d66534ac53eedcd4a1daf91a7a7ccc',
  'breeze_svg_height_attack.json.gz':
      '73d11277a5476782b5b7f5536512a5b67a61ba7b7b7f032d15c42f881d9e672f',
  'breeze_svg_height_defense.json.gz':
      '4ff12a78af46b1529cf640b3c089aa3961fd8b30e5e3f06502d7e582a9b0f144',
  'corrode_svg_height_attack.json.gz':
      'd268dfc17861383caf10ca827a22d16129e46004edf3fc2b8f3cc3e90f629304',
  'corrode_svg_height_defense.json.gz':
      '3e048957fe3db454140677044c9df92348727e6ace4ed1924b450adb2778b365',
  'fracture_svg_height_attack.json.gz':
      '6553b992776d065253dd97d15d344c0cd5225ab521700cd78f9e502710aa9963',
  'fracture_svg_height_defense.json.gz':
      'af406978957cfa2981268ad531f0befd3235d5940968e8a3fc21cf8a89aa2c5c',
  'haven_svg_height_attack.json.gz':
      '5750cdc88c1e1983e457d7eb2c9977416baa04ddc7b6a8d8cb394212112d8149',
  'haven_svg_height_defense.json.gz':
      '6d3bc64a00f75dd6d2b573391c16c1c764147fc85b3ea1dae4c4ca3116df7c00',
  'icebox_svg_height_attack.json.gz':
      '02acc7ce0530983adecd6d36319c58ae453510cb31b57b2a016be2c87990c333',
  'icebox_svg_height_defense.json.gz':
      'f98f015e8802a5199c29f025f37bf60d45f68eb421e9dab0d2d08f0ea1db8860',
  'lotus_svg_height_attack.json.gz':
      'eec5016a426d4d2c54e4e735a961e2d4d828151a60d8252b503c7e1b5137225b',
  'lotus_svg_height_defense.json.gz':
      'e0e38274bff817b93ed3f98cb2c81ef45c57480cc918df0a07ee4a5b3eb094e1',
  'pearl_svg_height_attack.json.gz':
      'fda2516790ad682278e1b64cf8e119654b2b53f962516ce7ea9bea04b030ac91',
  'pearl_svg_height_defense.json.gz':
      '86b8b0d02c47ca4c99c599dad8a366cfe6b068195f97a77589b08d689da4cab3',
  'split_svg_height_attack.json.gz':
      'ec28f7f347b9dc5733351595bb0f31518b8d1c613c1cc94325a3377f964755b1',
  'split_svg_height_defense.json.gz':
      'e6bba732a0c248332d5bf944f352ed69bc955856e8f66599e6a1aaa92153da29',
  'summit_svg_height_attack.json.gz':
      '5946b5f33985e752c1bb548eda42a1e5d681835d5d1b82b708a9217ebfc8bfb3',
  'summit_svg_height_defense.json.gz':
      '0019501b9227d64f3d256fa56311b33da470abb4deb7bb362722a2361e9bb398',
  'sunset_svg_height_attack.json.gz':
      'f2e7e22b6838adf3d6d93c7f0ca154dbb2d2f17012971a706e4fbcfca37f278a',
  'sunset_svg_height_defense.json.gz':
      'bf1fb358ea41de9b78ddb9fce7a8d3f8340c8bf5103698f2c0b10a7854012917',
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
