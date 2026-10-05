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
      '4f7b09791e08b2df1ef3ee5242654e7cdbca1c35f2636c6b58f6a794d949c2d8',
  'abyss_svg_height_defense.json.gz':
      '1a450b6c369eb879d5f785c5637daca8780e122c4609020cd9b95b6ce0912a3e',
  'ascent_svg_height_attack.json.gz':
      'ef96b0367e0b8949c2529b56e0abbfc47e0631e3b6ea832e9b667226a63caf13',
  'ascent_svg_height_defense.json.gz':
      '38c9c8a40ac53bfe246660d3ce605e3d05d96ffe2904343b5973ff8a067cb753',
  'bind_svg_height_attack.json.gz':
      'f2892c1aef0f62c0cc3c8516f13b03275f4679fe7db7b1be0140d918edb09b5a',
  'bind_svg_height_defense.json.gz':
      '236d891cdc37488cc076b9301e509d9a140751f180673ce71a46be62a7f74d6d',
  'breeze_svg_height_attack.json.gz':
      '66e63a0e31ce5083db29be07f5e3cd7bd45b5c53e851c1b5eab297b7db4ec17a',
  'breeze_svg_height_defense.json.gz':
      'd40b25298334eb2c2074d20d1c3acc1ca36fe074dc1bae02d3c2c3f0d7a2adc9',
  'corrode_svg_height_attack.json.gz':
      'e3cc0f04f17c364c38720da2a1c37a69ed905b507867d85b61c1f9004869287d',
  'corrode_svg_height_defense.json.gz':
      '43dbd72bc7e4bc7250b1f6468edee7385b48c5255d9dd33fad286f67016c6fa3',
  'fracture_svg_height_attack.json.gz':
      '17bea88c009b01a619b3a9c0ec73e4042d0bd2b38490eb53e12b9c3fb24915ce',
  'fracture_svg_height_defense.json.gz':
      '77ce5636607ec03393e1a11d6454586781439d5d6bd37ab2193f6e5b7e7e224f',
  'haven_svg_height_attack.json.gz':
      'f3ef26501e6fb9a3c48307e8a8b28583e6a731cf30dc047ab7fef86d1795632a',
  'haven_svg_height_defense.json.gz':
      '54b9f0eafc867940e7556949f2cfbe886d6e446da72b038f6d891112dd5890fd',
  'icebox_svg_height_attack.json.gz':
      '0b3aa659f5223a378f97573582243a0202be8d398fc74fa818994cd09d78e3e4',
  'icebox_svg_height_defense.json.gz':
      'ad5ae3d58600316ebb5bde272444c476d1297e349dbd59e3df696ea958bffcc5',
  'lotus_svg_height_attack.json.gz':
      'f41a05363c9dfcaf577cbcbe470c1436cbc8bd5c22c891ba85625e325a666d1b',
  'lotus_svg_height_defense.json.gz':
      'bad95da0f2ded6ef3a9c8d3ae4ca8b61fedeab1df59eeed40838fe83ec26f593',
  'pearl_svg_height_attack.json.gz':
      '6202255d92c611a2b020089c501136d651f6e4fecf99156509332f514daea6c6',
  'pearl_svg_height_defense.json.gz':
      '91b47d86f95a7a99b866e8a13b1fcff9af47c68c259f47d9be2588255ea0bd1d',
  'split_svg_height_attack.json.gz':
      'd24243709ddd4f9322f70c16c4d449e0557a90cd00dca038d6196f3911a7a2d7',
  'split_svg_height_defense.json.gz':
      'e1975791d570b7d5e570853eda8d00fbc3a3cc33c6ebabbad1ee04247b6f7b76',
  'summit_svg_height_attack.json.gz':
      '24334581de53f9a9a7bcb35ce85425e95f141dbe77f6f576249bdaa23a83d723',
  'summit_svg_height_defense.json.gz':
      'c8462c9dc9d0dc3285363ee4f3b0376f1035dfcb7774dbec18a20fb4f73c0960',
  'sunset_svg_height_attack.json.gz':
      'ae8783c980c648a5c09ffc472378184f8076e69e062552d51958fac39a3915dd',
  'sunset_svg_height_defense.json.gz':
      '41028e8d49f11ae17d980f52897f44b540fab2c62394adf9bee24e2b64adf8ff',
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
