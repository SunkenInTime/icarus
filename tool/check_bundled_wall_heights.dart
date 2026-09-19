import 'dart:convert';
import 'dart:io';

/// Release preflight. Every wall must carry a measured floor and bands:
/// finite bottoms, each band taller than nothing, and an open top (null)
/// only on the last band, which is how the ray derivation records a wall
/// that blocks every probed eye height. A wall still marked unknown, or a
/// band with an unbounded lower edge, has no measurement behind it.
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
        bands is! List) {
      failures.add('$id');
      continue;
    }
    for (var index = 0; index < bands.length; index++) {
      if (!_isMeasuredBand(bands[index], last: index == bands.length - 1)) {
        failures.add('$id');
        break;
      }
    }
  }
  return failures;
}

bool _isMeasuredBand(Object? band, {required bool last}) {
  if (band is! List || band.length != 2) return false;
  final bottom = band[0];
  final top = band[1];
  if (bottom is! num || !bottom.isFinite) return false;
  if (top == null) return last;
  return top is num && top.isFinite && bottom < top;
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
