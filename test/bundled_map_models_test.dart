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
      '075c1b3a91926074cb0930a26bed53fea01bdd6b245a3a4c5c09effef995524e',
  'abyss_svg_height_defense.json.gz':
      'cee96ae270d55ef1572515ce21c100f9fa6ecd129fd6c046a2fb4d44c0666080',
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
      'f1eb4c7aea3cf5cebed861b554fb6e2aa46d296af3f498c9ad6cd52d1a31e3f7',
  'corrode_svg_height_defense.json.gz':
      'f11026dbf2668f3bb0821bad3f8e63b662e1614769e3f310cc87d1d4e4742a68',
  'fracture_svg_height_attack.json.gz':
      'e26cd0fda1ab0b27d7734e3dd572dcc1cd23f01b3e32c9e164f82d271cc319ed',
  'fracture_svg_height_defense.json.gz':
      'd818d9cede6fa6ab5b7f7c45106d0265c514c0ae3f8c4b9293c2fce4fd7b79b4',
  'haven_svg_height_attack.json.gz':
      '2d2ec9cbd9eabb266f9201e9d7e10c39f8f6dd2d64f637a80900e9b0cb21ad49',
  'haven_svg_height_defense.json.gz':
      '14998b0dc52f3e563c5dc426e5c061e74d9be2ae826259493caa26fd8dcda0eb',
  'icebox_svg_height_attack.json.gz':
      'b7b3f013d3ccf6d6aced77f061d24f3314b2fcf8ba7f8defa4fb8ff556178c80',
  'icebox_svg_height_defense.json.gz':
      '42cd41d91dde9dc5d0b85f0c917ec1e37dfb9ce4467468b02aa28e7d3987ca68',
  'lotus_svg_height_attack.json.gz':
      '31b1254c1463fc0faeb79bdb645fb2e144cad73331eb74b89ece50c1e71de33d',
  'lotus_svg_height_defense.json.gz':
      'e9017848476fb6196a221f3669b84470d7658dd8c117d30711729d815e9d8285',
  'pearl_svg_height_attack.json.gz':
      'cbe8f7775af4ca0f9024ce741194935ccccaa965ca102e363354eca9f4b0fec1',
  'pearl_svg_height_defense.json.gz':
      '497c9187b3b99e2c003947e6b6cd25ba50d28ac45c0c0eaf9abc753520513f2e',
  'split_svg_height_attack.json.gz':
      '75b0aefdd1503c35febae522a061317729c877434ff8fd355479abd0953d1e68',
  'split_svg_height_defense.json.gz':
      '98b2214d4cb7e99795e168a9c9d681e7ecc590b97a5d6a17bbf031a2fab8d4fd',
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
