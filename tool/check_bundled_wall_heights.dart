import 'dart:convert';
import 'dart:io';

/// Release preflight. A reviewed label never substitutes for a finite height.
List<String> unresolvedWallHeights(Map<String, dynamic> model) {
  final failures = <String>[];
  final walls = model['walls'];
  if (walls is! List || walls.isEmpty) return ['Missing wall records'];
  for (final wall in walls) {
    final id = wall['id'];
    final floor = wall['floorElevationMeters'];
    final bands = wall['bands'];
    if (wall['unknownHeight'] != false ||
        floor is! num ||
        !floor.isFinite ||
        bands is! List ||
        bands.any((band) =>
            band is! List ||
            band.length != 2 ||
            band[0] is! num ||
            band[1] is! num ||
            !(band[0] as num).isFinite ||
            !(band[1] as num).isFinite ||
            band[0] >= band[1])) {
      failures.add('$id');
    }
  }
  return failures;
}

void main(List<String> args) {
  final directory = args.isEmpty ? 'assets/maps' : args.single;
  const maps = [
    'abyss',
    'ascent',
    'bind',
    'breeze',
    'corrode',
    'fracture',
    'haven',
    'icebox',
    'lotus',
    'pearl',
    'split',
    'summit',
    'sunset',
  ];
  var total = 0;
  for (final map in maps) {
    for (final side in ['attack', 'defense']) {
      final file = File('$directory/${map}_svg_height_$side.json.gz');
      try {
        final model =
            jsonDecode(utf8.decode(gzip.decode(file.readAsBytesSync())))
                as Map<String, dynamic>;
        if (model['map'] != map ||
            model['side'] != side ||
            ![2, 3].contains(model['version'])) {
          throw const FormatException('Map, side or schema mismatch');
        }
        final failures = unresolvedWallHeights(model);
        if (failures.isNotEmpty) {
          total += failures.length;
          stderr
              .writeln('$map/$side: ${failures.length} unresolved wall heights '
                  '(${failures.take(4).join(', ')})');
        }
      } catch (error) {
        total++;
        stderr.writeln('$map/$side: $error');
      }
    }
  }
  if (total != 0) {
    stderr.writeln('Release blocked. Resolve wall heights and rerun source '
        'sightline review before bundling. See docs/vision-model.md.');
    exitCode = 1;
  } else {
    stdout.writeln('All 26 map assets have finite, resolved wall heights. '
        'Source and gameplay acceptance remain separate checks.');
  }
}
