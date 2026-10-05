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
      '4067625fe0aa5297bc46d8843bba5edd28e204cce71706c2735395adadd80403',
  'abyss_svg_height_defense.json.gz':
      'cab42a6c871f0ca4598ad4e43237259c9767b77f48358f038ae46b140ea7e56d',
  'ascent_svg_height_attack.json.gz':
      '33fc747d4ca64359bbb0875eef0eda411212a049a519aefe9fed88a4246d4635',
  'ascent_svg_height_defense.json.gz':
      'c2326900cdea8c8016fb582dbf50e71e84f7ff1d98ecdfcfc0ba6cae6b9e06fc',
  'bind_svg_height_attack.json.gz':
      '1430c1a857778b716c081484bec9e2e2b547cdb607a4e1f1afccd22e58e45374',
  'bind_svg_height_defense.json.gz':
      'edcc77ba5a794e7b0d9247e96ce2fcce862e33389159b1f4ab18159c5944fac7',
  'breeze_svg_height_attack.json.gz':
      'f6e5ac3a58755a26fa9ef70bb4359a39074fb156f0d36ed68edac32f43553ddc',
  'breeze_svg_height_defense.json.gz':
      '16bc3c64063f8e329ad4274e7537fd2b47505f0893862038b619be7df3595bc4',
  'corrode_svg_height_attack.json.gz':
      'ae7500fcba854e993281165d85a7ea3d365366b972b4d5c4d3eb2b3d737f4bbb',
  'corrode_svg_height_defense.json.gz':
      'c0ffa59438296e0eab0d4cabbf3cda0c7461d3986658347e5555e1a7db598c55',
  'fracture_svg_height_attack.json.gz':
      'f1dffd9dc68eb44efc673296b3c7c2cc38e294f199882a4601a4b72ab4f93375',
  'fracture_svg_height_defense.json.gz':
      'd818d9cede6fa6ab5b7f7c45106d0265c514c0ae3f8c4b9293c2fce4fd7b79b4',
  'haven_svg_height_attack.json.gz':
      '8ac4ccfeded74d036b1fec57e2cfbe84edd98dafa468c60d84ccac4db43b8da3',
  'haven_svg_height_defense.json.gz':
      'cfce1305ec03a5b7c93da72033cad9b38de2c4a55859408422695bd1f287125f',
  'icebox_svg_height_attack.json.gz':
      '8abfbb2ea0c625092c62b6863017bab05b30de27e8b17abbf2f71838b3d0f287',
  'icebox_svg_height_defense.json.gz':
      '501fee35a09595e57bb1fae066fd31f4556e69fba11fafb0e992698202a62a3b',
  'lotus_svg_height_attack.json.gz':
      '31b1254c1463fc0faeb79bdb645fb2e144cad73331eb74b89ece50c1e71de33d',
  'lotus_svg_height_defense.json.gz':
      'e9017848476fb6196a221f3669b84470d7658dd8c117d30711729d815e9d8285',
  'pearl_svg_height_attack.json.gz':
      '4749e03cf68e4f969d23b77cf717c8b3c5d295950545ca03c835eab79e3b04b9',
  'pearl_svg_height_defense.json.gz':
      'fbe78b502cdb7f6872e7404e9b84611e45110e492a01daf555398604eb181fdb',
  'split_svg_height_attack.json.gz':
      '6795ebf8b7e25d25456c4c6ab7fa58369e797984d0f24326ef51251a7c7004a4',
  'split_svg_height_defense.json.gz':
      '486c282505f97a82451be3f3f7a670138a5b814334834366287397b8aadb0a43',
  'summit_svg_height_attack.json.gz':
      '804aa1716eaaa37dfe02eab97995256ec8b6780c78f76f8dd4a59dea1756db58',
  'summit_svg_height_defense.json.gz':
      '604ab36989943c0680c583adfc93ca2476f40999a2a6ba334dc196a32fd2d6f0',
  'sunset_svg_height_attack.json.gz':
      '97a89c9297b963cc366dc9cea2ed4c2578b4efbc27b41b4784658115327022f5',
  'sunset_svg_height_defense.json.gz':
      '3171ae0a45ffffc6ec7a05bc20cc1aa41d84ff7a443cd35be010b486d4cd4f80',
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
