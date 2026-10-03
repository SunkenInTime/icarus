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
      '92070b65d21a8670d6ec3e5ed1f47d256715af4eb1146877a0d89d76b5326bd4',
  'abyss_svg_height_defense.json.gz':
      '4af0c4e940b32d30cf32ba8882416ed893be07a8a3f8a1222bd2765c47974866',
  'ascent_svg_height_attack.json.gz':
      '1dc1fa567cb68fe822f51c0de77e945192958929281b9afca97411a4525fcd7c',
  'ascent_svg_height_defense.json.gz':
      '215c880206840c3f164799a31b6f41fbdb4e8f4c036acb0410a3795ec6c87f40',
  'bind_svg_height_attack.json.gz':
      '47d4eff309db713f32e4f6f58a8ef6d1ef6e9fcb640203ce24067daed0f1c13d',
  'bind_svg_height_defense.json.gz':
      'c27b9669776f490d2f03a1aa859a311518b1c175f54b52dbb03a5485a732170f',
  'breeze_svg_height_attack.json.gz':
      'ba14ba76b32d149fbae8115b4a940f8dd166276b0a25723908f3ab2e2c117964',
  'breeze_svg_height_defense.json.gz':
      'a5e5ac4fe8a30ae849fedfa6e8a795180dbcb8cf6eabc626f28fc88c2ab841f0',
  'corrode_svg_height_attack.json.gz':
      'b4627fccd99b1d34548d3f308e96b0264c246c2bdc6a5c4c9951090ef66c5067',
  'corrode_svg_height_defense.json.gz':
      '38255c92671399baa1f57bed0fb7fadd7a2475bb2b19fb85fac5db0f3128e7ee',
  'fracture_svg_height_attack.json.gz':
      'c38c94d1077b523f045c3cf62d6f8986ff356b102d9725f8fa2ab5ef96958e5f',
  'fracture_svg_height_defense.json.gz':
      '67fe4146de83b00bb9d3c93e80cd885cfa73a968727eff2f45eaa4aff461b708',
  'haven_svg_height_attack.json.gz':
      '6f5c35ca4a1245baa29fe11dab0acdcf7173eb141d801b2df70dcabb31951bdb',
  'haven_svg_height_defense.json.gz':
      'cad19fe927c3f32ccd0904f1d2c5e75f4511b70fd632c67c0787f558cf995585',
  'icebox_svg_height_attack.json.gz':
      '0621530d21eeaa8ac67f2044b123fa395e0d16d76ba44926e6091d5aafea07d9',
  'icebox_svg_height_defense.json.gz':
      '5abbfdaca0d1c9a73763e7778bdae1cd20a36835d7594c524ce8b1adf903ff13',
  'lotus_svg_height_attack.json.gz':
      'a6e3c888df000bd6a8d8af8fec929b1ab15256324cedc09a7b08cd1c4a57efda',
  'lotus_svg_height_defense.json.gz':
      'b9d67276ac3821dad6c0eaea3b186c76fafedc88e03a3795c7da97c97eb628e5',
  'pearl_svg_height_attack.json.gz':
      '62c64ce87ab50de4a6a4e03410a4db821a2b994e4086b371b039527ae95d0ac7',
  'pearl_svg_height_defense.json.gz':
      '93f46008c2a047d037057e83d3e734f6020f39ecfb24dca80165538768a28a06',
  'split_svg_height_attack.json.gz':
      '8fc96b2e54ea3205791d6f0b2131ef7e180b3fe7f50ff52e409472f620e89c2b',
  'split_svg_height_defense.json.gz':
      '97ac3348628472067f6e6087c22a22540d7d814d3663c0c37c9193f1f665dfac',
  'summit_svg_height_attack.json.gz':
      '8a6cf08279e933c5a1a27f8cdadfd7ee2b12f11908e5ce13db068bc6d08e6175',
  'summit_svg_height_defense.json.gz':
      '4782eb1b7f8993f4355523468b095dda5150071fa6a0b83f05c1143f9a4550c8',
  'sunset_svg_height_attack.json.gz':
      '098343d1f6a7980be24a309b4080695ff8871a96e613314a34e8c5d33bb161fc',
  'sunset_svg_height_defense.json.gz':
      '53c31f7ebe2ee78ca80892a3403547ea1d99169c6ed6b91d762e23eac5fe43ec',
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
