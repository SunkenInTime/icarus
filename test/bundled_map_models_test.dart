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
      'e3d4f249573fc484e2b29b8ddd91970185f4f3012e1f242150fd5b36a2ad6e7d',
  'abyss_svg_height_defense.json.gz':
      '708acf92a98c7bed7d496cc10664cc72f7bf3e0b6fe595bfcd79c38a1acc0cbf',
  'ascent_svg_height_attack.json.gz':
      'bde3c534e335f71d5030983c8f997da240af41d7f0b74efaf425b56fdfa6a237',
  'ascent_svg_height_defense.json.gz':
      'f387c75019301673c46b9ae1965577e2256a25d43935baf43f5cdc729b0f0021',
  'bind_svg_height_attack.json.gz':
      '2d7775b11f750c1d935d638f78fae572327af9a4f06b0d9a5f8ac5062c379ad3',
  'bind_svg_height_defense.json.gz':
      '13eebcacc84772ea3c6eafa2c945d69f516c0894a1d79193ac245a13d5fc804d',
  'breeze_svg_height_attack.json.gz':
      '8d525b9e2e1b244d95688bfcf0355aff3d73e57971e5d1726fb4e87191ca0525',
  'breeze_svg_height_defense.json.gz':
      'e680531a0aba894149e731f3eca5008734208d36f5f16096d52ded326ae27e8f',
  'corrode_svg_height_attack.json.gz':
      '7eacbb81259cde48ceee7e0d4f76bc94d8c7c0b26e72637b2acbd9819da0be35',
  'corrode_svg_height_defense.json.gz':
      '209a88669ac6f17580d6fe4ac8a5b02bfeac4807fc287acd7030e70fc4d8213a',
  'fracture_svg_height_attack.json.gz':
      '5b41837f7fb3735d51735ae7f64f1be9a39a2040d1b31b508343b0c37bc06a17',
  'fracture_svg_height_defense.json.gz':
      '6a45426dbf7f5748d30a5be71d0cfdebbd265794166e35905e0202211f3bf3f2',
  'haven_svg_height_attack.json.gz':
      'b9feabbc5184f2101e1eff99ba279e17ab96e1d16ef950f7a3d487d267647bdd',
  'haven_svg_height_defense.json.gz':
      '1fe0a72d6cd92c486e4cd33e80fd29f2a884333011511c6ff2e7b84e4fbe3d39',
  'icebox_svg_height_attack.json.gz':
      'd362859f9c6c64c68c1f01321a8d89c0d239477c6051eb41ca4e6c7f570107dd',
  'icebox_svg_height_defense.json.gz':
      'e740f4887a081a6906381e820e8cd5aed7c6b63df2b71513f24465a0eba257b8',
  'lotus_svg_height_attack.json.gz':
      '44dbd06996413b6b17b87dd3c197f36579695a1838e563ea53c017ba2d130517',
  'lotus_svg_height_defense.json.gz':
      'f6f1785edc0750a660d837b4f6c1b43c50b79abec0bd2e16ac35df06134513bf',
  'pearl_svg_height_attack.json.gz':
      'c1baaff3cd13da666d1e26c2d93c21d8b00da4b63b38c56889d856f4794e352a',
  'pearl_svg_height_defense.json.gz':
      'c4fca12041f4ca5318817a9eb14e5c6c38c319fc980e11491ad3196e931572c5',
  'split_svg_height_attack.json.gz':
      'c4b2b42cfcae85016f1bddda51da5ccc3b6a01691aa1fb633b2d8d3240ae60b1',
  'split_svg_height_defense.json.gz':
      '1b11eef4d660eae6b513326c98721eec8bf1b8ad38cf4fb99e1ab0d0c675e3cd',
  'summit_svg_height_attack.json.gz':
      '187045ca08de1e49e2111ff01b4ce99a64de6706a72f94339455bac77ae19471',
  'summit_svg_height_defense.json.gz':
      'f94d06be518622708f48d1db338b2bfb7b34860a04354d23786785136a4f1f5c',
  'sunset_svg_height_attack.json.gz':
      '443699e17d11facfacfbef4d51057f1b562c17d15d19f8e0ad214c395635e309',
  'sunset_svg_height_defense.json.gz':
      '1d36500246d7c4aa55f7675a1701e9ea4fc0c94b8e732286327dd529f0f106ed',
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
