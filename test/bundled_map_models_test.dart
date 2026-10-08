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
      'b7c13fd6d68624064cf1f9e0fadf51c19000e09ab35f11823a7a2f686faea862',
  'abyss_svg_height_defense.json.gz':
      'af0d0b35ce7bc9db88dc529e906ccefc67165d6d5ffbd9432cde90330abb3c34',
  'ascent_svg_height_attack.json.gz':
      '95fb707c43553a705c90b41bad2c5518220e9d0bd2b87c4cafda62e4865828f3',
  'ascent_svg_height_defense.json.gz':
      '2b7461fcf297b9df6101820e007ebf3e525bfe63835f6cafb856aafe888eae01',
  'bind_svg_height_attack.json.gz':
      '5eae19732fb5ad639a022ea1d02a7451175bd7cb7e13af13fa1df5f54a4ad816',
  'bind_svg_height_defense.json.gz':
      '69204e123fb708a79bab7346203b824de8b24f5b02919e3d2c0e17292c932df7',
  'breeze_svg_height_attack.json.gz':
      '18f72a85b7943f51f664fd253715a4af0a0b0215f8d9b0a63a8dff0c3397eca5',
  'breeze_svg_height_defense.json.gz':
      '6a668f6e16bbbc632ddec82ec7b5eb8da611f0d7592df378a714b5cf52cda4a8',
  'corrode_svg_height_attack.json.gz':
      'a7d06b6b59c11a385088ea92d28214989c2c7c1687c04c901eccd2cd0dade148',
  'corrode_svg_height_defense.json.gz':
      'dcd037abb3c8b7f9b0306d306b5e625c537c668501beb82b4b300c17517d9103',
  'fracture_svg_height_attack.json.gz':
      '3b992293de7a97c53a59c0fe982916d4e7a5a774f482c18a8c67698741f82c19',
  'fracture_svg_height_defense.json.gz':
      '52e03b1a73f18b5ec99eb576b4a0ea214ae40e5595d3dbf0ae69562a8c56f4c8',
  'haven_svg_height_attack.json.gz':
      'a4e1e892e57f35a06e41071cea1b51c549564e96be397fc72dc49a4e90657632',
  'haven_svg_height_defense.json.gz':
      'f5674dc5c73ace1737c24d00458e0be5169659f229a26d11150bd7d1db6e5339',
  'icebox_svg_height_attack.json.gz':
      '7679d2aca4bd718df48599fa232b202814dbaf8f155ac6a4f68895e7f886fa70',
  'icebox_svg_height_defense.json.gz':
      '7abd48cae461d6315c4d8dd9caaad72234a0fe78b89a54ad837eb66dcf783c6a',
  'lotus_svg_height_attack.json.gz':
      '099fc3888f96209839e596573769434fa32f36abe62dfdb129c2c6b627b4d7b8',
  'lotus_svg_height_defense.json.gz':
      'f4bb421ddda4875bf61f50e7b8ed7a83c04f166a2880ca76dbaf3e7ef10c1bca',
  'pearl_svg_height_attack.json.gz':
      '106679ddb8dea47d9e468d585b9b9b35b9e5d99540216b6d7b59a3b122bfc7b6',
  'pearl_svg_height_defense.json.gz':
      'ceaad9adf0264a418e211b454602e4237d390b75c352cc3375822e93fb7c420d',
  'split_svg_height_attack.json.gz':
      '6eadb9b126df66b1e499cff963263cc56a4e2cd3b88fbf8d74fcc342595347ea',
  'split_svg_height_defense.json.gz':
      '1b34fa384c144e28061ea437c23d3331c868d581f07eb5795a4c5de76fbc23ea',
  'summit_svg_height_attack.json.gz':
      'da4c41f91a3b753be6c96d21357dd37c2a1d93bfb1ad1a66daa818556327e398',
  'summit_svg_height_defense.json.gz':
      'b63cd7f5b5db551bb53ece1f8dd95a33fe884ab1da13fb7a7baf3a8d81e16070',
  'sunset_svg_height_attack.json.gz':
      'ae7ee124beefedc364e04092a81f40c50b5b4167f92586c4b80cd97db42ed17d',
  'sunset_svg_height_defense.json.gz':
      '712bb23dc9148215d78bdd1d3b95de2ec82bf49ac919c90365a1835176b2e6b2',
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
