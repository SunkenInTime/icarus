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
      '7cb57b0ded7c77c4a36c85767b0cf6c79a383210443f36f77f3f85ec434dec68',
  'abyss_svg_height_defense.json.gz':
      'db9b2509e5423847ba67ce8a15c6f81e36eb023d39bf7ff7764060f29c4b1cfa',
  'ascent_svg_height_attack.json.gz':
      'f7a57948fa1eb5572b469d40097abb00f97a931dd47471812146ed244915df56',
  'ascent_svg_height_defense.json.gz':
      '9dec013a05665c7e44b16a304670c68f160dd0625add95298d3ef5e5a8c29339',
  'bind_svg_height_attack.json.gz':
      '25894f62cf1d617dad6677e161180a4daae7245afa7aec5fd519d8e1dc89189b',
  'bind_svg_height_defense.json.gz':
      '0e3e6c20d868522ed5993f28610e2ffbe2e751afe4b8ff56395ae665d285c7cd',
  'breeze_svg_height_attack.json.gz':
      '78ae1460e6cebde9ee9bcc687435ce9fd4bd0eeb840ea6e2ec81a5186d12c185',
  'breeze_svg_height_defense.json.gz':
      '227ed0e7f367e0a8f35a85d8cd2df6abdebf96f32191f839e5599cbd5a60f9fa',
  'corrode_svg_height_attack.json.gz':
      'f60d738618e7a3af475f1a489f7d22f6c78c4d212cdeedfcbea4a808b49ce91f',
  'corrode_svg_height_defense.json.gz':
      'f9b50d3bf259a1570e68d1353885e4a82fac34dd212523a90f9008837765a906',
  'fracture_svg_height_attack.json.gz':
      '5f9393fb60a03b6a77d9de31d3f52903e586940bf05a9dfbecd0daf2a7093125',
  'fracture_svg_height_defense.json.gz':
      'a3a2318def51a5be333cd7fd5fbead7aec961987dc296e8a2382db3fd7072c1a',
  'haven_svg_height_attack.json.gz':
      '77773a754b88f7b4d76c099da80644fa3e6bf9e386e2a0d66921a5ffc6b1ba2b',
  'haven_svg_height_defense.json.gz':
      '7903a7b37686fc2688fee073babe51502b10a26ffca9267c1d1e0471d3b799b2',
  'icebox_svg_height_attack.json.gz':
      'd4e4ed8cee08b3146f072cab02484e3da78b639ebca5d1617b4db72e257ba271',
  'icebox_svg_height_defense.json.gz':
      'e8478e1110707de353cd15eda2d394efe4f09f4bc3a74686dd2fc739bab894c6',
  'lotus_svg_height_attack.json.gz':
      'e278eb34b0842382299537adc84c362edf3d2694f3cfff612c3295684c34c3c4',
  'lotus_svg_height_defense.json.gz':
      'c5753e62e903ab84cae4a0bd3dc9d9c5eed992c511cc8ea614b35fd651929c22',
  'pearl_svg_height_attack.json.gz':
      '18e00369f1c21818e6c489402be7bddb1d531ca3b8d0576619112c4b14ce844e',
  'pearl_svg_height_defense.json.gz':
      '2a6f85987f50a67626c75bc5007165fbb7afe308e55b6070d18f9775dd5b9795',
  'split_svg_height_attack.json.gz':
      'c666df45ff09d76481a2267414f8a113f1b1bb44d2c78df5de55d735d5dc60ab',
  'split_svg_height_defense.json.gz':
      'a12cff02b1653b13e2bb26e19fe9e0c25a57932a99068783d5298d1c1e6dbf08',
  'summit_svg_height_attack.json.gz':
      '46333bd87325e7bf7cac09ab2ce48f949416bfd0be648f0eb3995a69d690615d',
  'summit_svg_height_defense.json.gz':
      'b39746c18d50bd6502603bed7ec94c9f6334c020afce8175591eba9b5c0e1f57',
  'sunset_svg_height_attack.json.gz':
      '54fc002ce956e334e308f5de9caf16d22965131d8dc2d7ce802ac545f5b6f7c8',
  'sunset_svg_height_defense.json.gz':
      'b8f727769f81b1614bc29e35fd58301a2175ed97e2c0497217677177a5e1d60d',
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
