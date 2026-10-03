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
      '236c30145b3eb9cca5f8898449c6a0f61bcfbc93a215ae93d57ae7d290826c39',
  'abyss_svg_height_defense.json.gz':
      'bef5058dbb1134c998c132dbf1c15f1a5a3481d44900521a5c57068ca7605e8a',
  'ascent_svg_height_attack.json.gz':
      'e0d8cfd378253497e5baaea41b1b8f5305ad9c9a63ca222d767273e6d4f4ebe7',
  'ascent_svg_height_defense.json.gz':
      '66b75c9c1ad04d373248412be7774121d1c8cd93e3b2e1d3598d18a6b903d70a',
  'bind_svg_height_attack.json.gz':
      'e2d13cbb46a4255763b7f7bef1567d710875a850c033a39d1290b734b80b0f35',
  'bind_svg_height_defense.json.gz':
      '305341252b331f0e6da254f623c3b44a1b8a13255924645c7c4dec063939140a',
  'breeze_svg_height_attack.json.gz':
      '04fff61bb2ea06210e61a609d851272bfb548e09831272fe07dd32337f291303',
  'breeze_svg_height_defense.json.gz':
      '23de2c77640d6b8f4c840697bec21e2e9e9ba53e8d10177cada900c5088a5553',
  'corrode_svg_height_attack.json.gz':
      'c6ddb97c33d2b86b44befe13ff715f9ad16836f27512272b934a5b3c34626f3a',
  'corrode_svg_height_defense.json.gz':
      '1bf1361a275200bea39a571e43688e7cfd9c9981e549647923183476fb3c3e42',
  'fracture_svg_height_attack.json.gz':
      'bf8abc98e214fa50ea5ffa1fc18bc0464035cee4ad720235ebd6186f710bf99b',
  'fracture_svg_height_defense.json.gz':
      'b86cc1b26d46b4223b38ac138531a5bdbda8526c2c7794836a4c8c8d1ce80fe3',
  'haven_svg_height_attack.json.gz':
      '7549040bc2d27389df28014adfbcbe5c4ad4d66d0d6476a816776d6e658e7113',
  'haven_svg_height_defense.json.gz':
      '39ae56beaa1a8db946de5b41b92ecda000ae6f098b2ed78eefa1265e703f0048',
  'icebox_svg_height_attack.json.gz':
      '9efeb73541a90af6a7bdb5d1838d7b83127a25e677cc99bc224c68459e9e1268',
  'icebox_svg_height_defense.json.gz':
      '7d177c7a8e07aed3ca5f41ff962c7f5294755c783900bb9245545a8d8d91598e',
  'lotus_svg_height_attack.json.gz':
      'f2e614dbda6135b6c38c45b0177fa64847ca11119601162f85455247a4f289a1',
  'lotus_svg_height_defense.json.gz':
      '6cff95812ff25e7e7f923c77f4addf0d017a6b216befec77284e10b1c0923b80',
  'pearl_svg_height_attack.json.gz':
      '9f9a37ffd4a00b40c4fc5f217498bb2633cc047955b821b0e15f815033760ad7',
  'pearl_svg_height_defense.json.gz':
      'ce01646cc1337b5756a4d6d884356dcaaf7e739223e0f8ff5d3873a8ab95229f',
  'split_svg_height_attack.json.gz':
      'a7ced0da9dc612ac50ea04f4fa563f7dd078747b79dc9011dbf55533d9939b70',
  'split_svg_height_defense.json.gz':
      '6b4591b9d1adab40a5d0c996a32b131e71e2f97d44f7c1d42826da3f83dcbbd6',
  'summit_svg_height_attack.json.gz':
      'e6db223d1894f408aa8b38642e7108dbe5316f84c50af6523b486dff53636014',
  'summit_svg_height_defense.json.gz':
      '3b18feefe92f419c8f990cba0a84511366265335d806bb73b0a4eaf8a5c59179',
  'sunset_svg_height_attack.json.gz':
      '96815a1d7eee82d1b86dc567242f6a0195760dbbeeab93140f93799d192839b4',
  'sunset_svg_height_defense.json.gz':
      '5d4588d9107c127d94eeb5dc48544305ac6a63520b790cfe63c523962486cf06',
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
