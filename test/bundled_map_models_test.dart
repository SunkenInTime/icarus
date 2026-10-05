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
      'd2584571cbfa55707b282e001c6d623d55afdbe6bcd4ef49544432db5be9ccbc',
  'abyss_svg_height_defense.json.gz':
      '9a96967a96c7838090ac090dd9abc330a872e17caec252397b49b4e4d1c2f76c',
  'ascent_svg_height_attack.json.gz':
      '00530c60076b564b3ac5020d983de60d1554fdc3e12f97d137b49f9932ba42cb',
  'ascent_svg_height_defense.json.gz':
      'e25313890e098d5bef86fa094f512483c82e0fb166074f80d3081dece976a2a7',
  'bind_svg_height_attack.json.gz':
      'ae27a16a23fbdf5b44ca050c16b1f89a03bea4113efad1da1d95e3c5b08111ba',
  'bind_svg_height_defense.json.gz':
      '8c6d2611c88518e900fc59c5bc7ba0f1fea15c1e0491ad0b4618a64286515af3',
  'breeze_svg_height_attack.json.gz':
      'afa3dbbe0a741ad3bb9df699deed3fbdfe07764be5136ab07735f456786b996b',
  'breeze_svg_height_defense.json.gz':
      'c744d6bb946abd1ed233a6cc0bb214dc5ff42317941128f0b6edb4b953d9f6ee',
  'corrode_svg_height_attack.json.gz':
      '467fc710f8912b81ae31403fc144cf94730891e87b9bd57dd07f5f1076b0415d',
  'corrode_svg_height_defense.json.gz':
      '32b41d8de237a8788b65ec655339310b5f14f4baa37c2468c7a82f1cb0acf136',
  'fracture_svg_height_attack.json.gz':
      '181776c0bfc042d3901367f9e1db8276f2c5d8f57b4fd5cc575b3cdb815c7b9b',
  'fracture_svg_height_defense.json.gz':
      '04f40b1d132e21a783106fadb3ec604309318da0491f664121a0d122b6202f52',
  'haven_svg_height_attack.json.gz':
      '43529cc5731df622df66c7d05205fb149bb36ae0d14e7940a1e83af0a1535ecf',
  'haven_svg_height_defense.json.gz':
      'b4fb1b072f0de7c8d78141ea1227befe60c4dfc61234fdb6e6c54585ec0c24ee',
  'icebox_svg_height_attack.json.gz':
      '5755af829f1ef568fa8c8cc49256d431e987b8dc020f227be83d8644dfa9f22d',
  'icebox_svg_height_defense.json.gz':
      'e1feb443b83915f362db96df9644274f3f8abb9636b39b359c4b14e3004373aa',
  'lotus_svg_height_attack.json.gz':
      'e0246d2298948c97cb1b14a7e3a78c37639364781746d85246f3326d88e646e7',
  'lotus_svg_height_defense.json.gz':
      'ba349690b50fa9101bd78534e1ed70e36e0b4e3976276257d167243d6e000d15',
  'pearl_svg_height_attack.json.gz':
      '9b1e1751375c4f350221632a1218a6d82b468dc99cd3a73c4c9e444d46624011',
  'pearl_svg_height_defense.json.gz':
      '64c06641fe30e66cdbee3e4e5cbbeb230ac817a797be1c0c5255f5f6a52d2121',
  'split_svg_height_attack.json.gz':
      'a532f2815c1d570727063c6e07bd776228ea745b015990f1411a437244d49287',
  'split_svg_height_defense.json.gz':
      'd2c33e89e929919a07522b562825cc4d529ebf0a5d82e751df1c99b471e5e0c0',
  'summit_svg_height_attack.json.gz':
      '30e0894932abde8134fa477edb41885cde316637ca548d2bc701fd191e8d70b0',
  'summit_svg_height_defense.json.gz':
      'd9499a88a76fb73f31d818a1c28e200687a662df71827aa133f0bb56b908b876',
  'sunset_svg_height_attack.json.gz':
      '012f38f95f49df79c81896685e899de4408147fb367e178954d34c6c4e3842f4',
  'sunset_svg_height_defense.json.gz':
      '86f9c66c4670ba1dc7859e2a71f0ac7c58929e63d900d68e720cb304747780b6',
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
