import 'dart:convert';
import 'dart:io';

const int _coordinateScale = 65536;

const Map<String, ({String vision, String spawns, String level, String uiData})>
    _sources = {
  'ascent': (
    vision: 'Content/UI/InGame/Minimap/Maps/Ascent/Ascent.json',
    spawns: 'Content/Maps/Ascent/Ascent_TeamSpawnPoints.json',
    level: 'Content/Maps/Ascent/Ascent.json',
    uiData: 'Content/Maps/Ascent/Ascent_UIData.json',
  ),
  'breeze': (
    vision: 'Content/UI/InGame/Minimap/Maps/FoxTrot/Foxtrot.json',
    spawns: 'Content/Maps/FoxTrot/Foxtrot_TeamSpawnPoints.json',
    level: 'Content/Maps/FoxTrot/FoxTrot.json',
    uiData: 'Content/Maps/FoxTrot/Foxtrot_UIData.json',
  ),
  'lotus': (
    vision: 'Content/UI/InGame/Minimap/Maps/Jam/Jam.json',
    spawns: 'Content/Maps/Jam/Jam_Mode_TeamSpawnPoints.json',
    level: 'Content/Maps/Jam/Jam.json',
    uiData: 'Content/Maps/Jam/Jam_UIData.json',
  ),
  'icebox': (
    vision: 'Content/UI/InGame/Minimap/Maps/Port/Port.json',
    spawns: 'Content/Maps/Port/Port_TeamSpawnPoints.json',
    level: 'Content/Maps/Port/Port.json',
    uiData: 'Content/Maps/Port/Port_UIData.json',
  ),
  'sunset': (
    vision: 'Content/UI/InGame/Minimap/Maps/Juliett/Juliett_VisionCones.json',
    spawns: 'Content/Maps/Juliett/Juliett_TeamSpawnPoints.json',
    level: 'Content/Maps/Juliett/Juliett.json',
    uiData: 'Content/Maps/Juliett/Juliett_UIData.json',
  ),
  'split': (
    vision:
        'Content/UI/InGame/Minimap/Maps/Bonsai/Bonsai_Bonsai_VisionOccluders.json',
    spawns: 'Content/Maps/Bonsai/Bonsai_TeamSpawnPoints.json',
    level: 'Content/Maps/Bonsai/Bonsai.json',
    uiData: 'Content/Maps/Bonsai/Bonsai_UIData.json',
  ),
  'haven': (
    vision: 'Content/UI/InGame/Minimap/Maps/Triad/Triad.json',
    spawns: 'Content/Maps/Triad/Triad_TeamSpawnPoints.json',
    level: 'Content/Maps/Triad/Triad.json',
    uiData: 'Content/Maps/Triad/Triad_UIData.json',
  ),
  'fracture': (
    vision: 'Content/UI/InGame/Minimap/Maps/Canyon/Canyon_VisionCones.json',
    spawns: 'Content/Maps/Canyon/Canyon_TeamSpawnPoints.json',
    level: 'Content/Maps/Canyon/Canyon.json',
    uiData: 'Content/Maps/Canyon/Canyon_UIData.json',
  ),
  'abyss': (
    vision: 'Content/UI/InGame/Minimap/Maps/Infinity/Infinity.json',
    spawns: 'Content/Maps/Infinity/Infinity_TeamSpawnPoints.json',
    level: 'Content/Maps/Infinity/Infinity.json',
    uiData: 'Content/Maps/Infinity/Infinity_UIData.json',
  ),
  'pearl': (
    vision: 'Content/UI/InGame/Minimap/Maps/Pitt/Pitt_VisionCones.json',
    spawns: 'Content/Maps/Pitt/Pitt_TeamSpawnPoints.json',
    level: 'Content/Maps/Pitt/Pitt.json',
    uiData: 'Content/Maps/Pitt/Pitt_UIData.json',
  ),
  'bind': (
    vision: 'Content/UI/InGame/Minimap/Maps/Duality/Duality.json',
    spawns: 'Content/Maps/Duality/Duality_TeamSpawnPoints.json',
    level: 'Content/Maps/Duality/Duality.json',
    uiData: 'Content/Maps/Duality/Duality_UIData.json',
  ),
  'corrode': (
    vision: 'Content/UI/InGame/Minimap/Maps/Rook/Rook_VisionCones.json',
    spawns: 'Content/Maps/Rook/Rook_Gameplay.json',
    level: 'Content/Maps/Rook/Rook.json',
    uiData: 'Content/Maps/Rook/Rook_UIData.json',
  ),
};

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/generate_view_cone_geometry.dart '
      '<FModel ShooterGame export>',
    );
    exitCode = 64;
    return;
  }

  final exportRoot = Directory(arguments.single);
  if (!exportRoot.existsSync()) {
    stderr.writeln('Export directory does not exist: ${exportRoot.path}');
    exitCode = 66;
    return;
  }

  for (final entry in _sources.entries) {
    final visionFile = File(_join(exportRoot.path, entry.value.vision));
    final spawnFile = File(_join(exportRoot.path, entry.value.spawns));
    final levelFile = File(_join(exportRoot.path, entry.value.level));
    final uiDataFile = File(_join(exportRoot.path, entry.value.uiData));
    if (!visionFile.existsSync()) {
      throw StateError('Missing ${entry.key} vision table: ${visionFile.path}');
    }
    if (!spawnFile.existsSync()) {
      throw StateError('Missing ${entry.key} spawn data: ${spawnFile.path}');
    }
    if (!levelFile.existsSync()) {
      throw StateError('Missing ${entry.key} level data: ${levelFile.path}');
    }
    if (!uiDataFile.existsSync()) {
      throw StateError('Missing ${entry.key} UI data: ${uiDataFile.path}');
    }

    final layers = _parseVisionLayers(visionFile);
    final heightData = _parseHeightData(
      levelFile: levelFile,
      uiDataFile: uiDataFile,
    );
    final defaultElevation = _resolveDefaultElevation(
      layers: layers,
      spawnFile: spawnFile,
    );
    final output = <String, Object>{
      'version': 2,
      'map': entry.key,
      'coordinateScale': _coordinateScale,
      'defaultElevation': defaultElevation,
      'observerHeight': heightData.observerHeight,
      'heightSamples': heightData.samples,
      'layers': [
        for (final layer in layers)
          <String, Object>{
            'elevation': layer.elevation,
            'vertices': layer.vertices,
            'edges': layer.edges,
          },
      ],
    };

    final outputFile = File(
      _join(Directory.current.path, 'assets/maps/${entry.key}_vision.json'),
    );
    outputFile.writeAsStringSync(jsonEncode(output));
    stdout.writeln(
      '${entry.key}: ${layers.length} layers, '
      '${heightData.samples.length ~/ 3} height samples, '
      'default $defaultElevation, ${outputFile.lengthSync()} bytes',
    );
  }

  _writeSummitSvgFallback();
}

/// Summit postdates the local ShooterGame export. Its attack-side SVG uses an
/// even-odd fill path whose subpaths describe the visible floor boundaries and
/// internal walls, so it is a deterministic boundary-clipping fallback until
/// Riot's VisionGeometry table is available in a future export.
void _writeSummitSvgFallback() {
  final svgFile = File(
    _join(Directory.current.path, 'assets/maps/summit_map.svg'),
  );
  final source = svgFile.readAsStringSync();
  final match = RegExp(
    r'<path fill-rule="evenodd"[^>]*d="([^"]+)"',
  ).firstMatch(source);
  if (match == null) {
    throw const FormatException('Summit SVG boundary path was not found.');
  }

  final geometry = _parseAbsoluteSvgPath(
    match.group(1)!,
    width: 435,
    height: 473,
  );
  final output = <String, Object>{
    'version': 2,
    'map': 'summit',
    'coordinateScale': _coordinateScale,
    'defaultElevation': 0,
    'observerHeight': 100,
    'heightSamples': const <int>[],
    'layers': [
      <String, Object>{
        'elevation': 0,
        'vertices': geometry.vertices,
        'edges': geometry.edges,
      },
    ],
  };
  final outputFile = File(
    _join(Directory.current.path, 'assets/maps/summit_vision.json'),
  );
  outputFile.writeAsStringSync(jsonEncode(output));
  stdout.writeln(
    'summit: SVG boundary fallback, ${geometry.edges.length ~/ 2} edges, '
    '${outputFile.lengthSync()} bytes',
  );
}

_CompactLayer _parseAbsoluteSvgPath(
  String pathData, {
  required double width,
  required double height,
}) {
  final tokens = RegExp(
    r'[A-Za-z]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?',
  ).allMatches(pathData).map((match) => match.group(0)!).toList();
  final vertices = <int>[];
  final edges = <int>[];
  var index = 0;
  var command = '';
  var currentX = 0.0;
  var currentY = 0.0;
  var subpathStart = -1;
  var previous = -1;

  bool isCommand(String token) => RegExp(r'^[A-Za-z]$').hasMatch(token);
  double number() => double.parse(tokens[index++]);
  int addVertex(double x, double y) {
    vertices
      ..add((x / width * _coordinateScale).round())
      ..add((y / height * _coordinateScale).round());
    return vertices.length ~/ 2 - 1;
  }

  void connect(int next) {
    if (previous >= 0 && previous != next) {
      edges
        ..add(previous)
        ..add(next);
    }
    previous = next;
  }

  while (index < tokens.length) {
    if (isCommand(tokens[index])) command = tokens[index++];
    switch (command) {
      case 'M':
        currentX = number();
        currentY = number();
        previous = addVertex(currentX, currentY);
        subpathStart = previous;
        command = 'L';
        break;
      case 'L':
        currentX = number();
        currentY = number();
        connect(addVertex(currentX, currentY));
        break;
      case 'H':
        currentX = number();
        connect(addVertex(currentX, currentY));
        break;
      case 'V':
        currentY = number();
        connect(addVertex(currentX, currentY));
        break;
      case 'C':
        final startX = currentX;
        final startY = currentY;
        final control1X = number();
        final control1Y = number();
        final control2X = number();
        final control2Y = number();
        final endX = number();
        final endY = number();
        const subdivisions = 16;
        for (var step = 1; step <= subdivisions; step += 1) {
          final t = step / subdivisions;
          final inverse = 1 - t;
          currentX = inverse * inverse * inverse * startX +
              3 * inverse * inverse * t * control1X +
              3 * inverse * t * t * control2X +
              t * t * t * endX;
          currentY = inverse * inverse * inverse * startY +
              3 * inverse * inverse * t * control1Y +
              3 * inverse * t * t * control2Y +
              t * t * t * endY;
          connect(addVertex(currentX, currentY));
        }
        break;
      case 'Z':
        if (subpathStart >= 0) connect(subpathStart);
        previous = -1;
        subpathStart = -1;
        command = '';
        break;
      default:
        throw FormatException('Unsupported Summit SVG command $command.');
    }
  }

  return _CompactLayer(
    elevation: 0,
    vertices: List.unmodifiable(vertices),
    edges: List.unmodifiable(edges),
  );
}

List<_CompactLayer> _parseVisionLayers(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  final tables = decoded is List ? decoded : <Object?>[decoded];
  final table = tables.whereType<Map<String, dynamic>>().firstWhere(
        (candidate) => candidate['Rows'] is Map<String, dynamic>,
        orElse: () => throw FormatException(
            'No DataTable Rows object found in ${file.path}'),
      );
  final rows = (table['Rows'] as Map<String, dynamic>).entries.toList()
    ..sort(
      (left, right) => int.parse(left.key).compareTo(int.parse(right.key)),
    );

  final layers = <_CompactLayer>[];
  _WorkingLayer? current;
  for (final entry in rows) {
    final row = entry.value;
    if (row is! Map<String, dynamic>) {
      throw FormatException('Row ${entry.key} is not an object.');
    }
    final type = row['Type'];
    final x = row['X'];
    final y = row['Y'];
    if (type is! String || x is! num || y is! num) {
      throw FormatException('Row ${entry.key} has an invalid Type/X/Y triple.');
    }

    switch (type) {
      case 'g':
        if (current != null) layers.add(current.finish());
        current = _WorkingLayer(y.toDouble());
        break;
      case 'v':
        if (current == null) {
          throw FormatException('Vertex row ${entry.key} precedes a group.');
        }
        current.vertices
          ..add((x.toDouble() * _coordinateScale).round())
          ..add((y.toDouble() * _coordinateScale).round());
        break;
      case 'l':
        if (current == null) {
          throw FormatException('Edge row ${entry.key} precedes a group.');
        }
        current.edges
          ..add(x.toInt())
          ..add(y.toInt());
        break;
      default:
        throw FormatException('Unsupported row type $type at ${entry.key}.');
    }
  }
  if (current != null) layers.add(current.finish());
  if (layers.isEmpty) {
    throw FormatException('No vision layers found in ${file.path}.');
  }
  return layers;
}

_HeightData _parseHeightData({
  required File levelFile,
  required File uiDataFile,
}) {
  final uiDecoded = jsonDecode(uiDataFile.readAsStringSync());
  final uiObjects = uiDecoded is List ? uiDecoded : <Object?>[uiDecoded];
  final uiProperties = uiObjects
      .whereType<Map<String, dynamic>>()
      .map((value) => value['Properties'])
      .whereType<Map<String, dynamic>>()
      .firstWhere(
        (properties) =>
            properties['XMultiplier'] is num &&
            properties['XScalarToAdd'] is num &&
            properties['YMultiplier'] is num &&
            properties['YScalarToAdd'] is num,
        orElse: () => throw FormatException(
          'Missing world-to-minimap transform in ${uiDataFile.path}',
        ),
      );
  final xMultiplier = (uiProperties['XMultiplier'] as num).toDouble();
  final xScalarToAdd = (uiProperties['XScalarToAdd'] as num).toDouble();
  final yMultiplier = (uiProperties['YMultiplier'] as num).toDouble();
  final yScalarToAdd = (uiProperties['YScalarToAdd'] as num).toDouble();

  final levelDecoded = jsonDecode(levelFile.readAsStringSync());
  final levelObjects = levelDecoded is List
      ? levelDecoded.whereType<Map<String, dynamic>>().toList()
      : <Map<String, dynamic>>[
          if (levelDecoded is Map<String, dynamic>) levelDecoded,
        ];
  final navProperties = levelObjects
      .where((value) => value['Type'] == 'GeneratedNavDropOffLinks')
      .map((value) => value['Properties'])
      .whereType<Map<String, dynamic>>()
      .firstWhere(
        (properties) => properties['PointLinks'] is List,
        orElse: () => throw FormatException(
          'Missing generated navigation samples in ${levelFile.path}',
        ),
      );

  var observerHeight = 100.0;
  for (final value in levelObjects) {
    if (value['Type'] != 'RecastNavMesh') continue;
    final properties = value['Properties'];
    if (properties is! Map<String, dynamic>) continue;
    final configuredHeight = properties['AgentHeight'] ??
        (properties['NavDataConfig'] is Map<String, dynamic>
            ? (properties['NavDataConfig']
                as Map<String, dynamic>)['AgentHeight']
            : null);
    if (configuredHeight is num && configuredHeight > 0) {
      observerHeight = configuredHeight.toDouble() / 2;
      break;
    }
  }

  final samples = <int>[];
  final seen = <String>{};
  final pointLinks = navProperties['PointLinks'] as List;
  for (final value in pointLinks) {
    if (value is! Map<String, dynamic>) continue;
    for (final endpointName in const ['Left', 'Right']) {
      final endpoint = value[endpointName];
      if (endpoint is! Map<String, dynamic>) continue;
      final worldX = endpoint['X'];
      final worldY = endpoint['Y'];
      final worldZ = endpoint['Z'];
      if (worldX is! num || worldY is! num || worldZ is! num) continue;

      // Riot's map UI data converts world coordinates into the same normalized
      // minimap UV frame used by VisionGeometry.
      final uvX = worldY.toDouble() * xMultiplier + xScalarToAdd;
      final uvY = worldX.toDouble() * yMultiplier + yScalarToAdd;
      final encodedX = (uvX * _coordinateScale).round();
      final encodedY = (uvY * _coordinateScale).round();
      final encodedZ = worldZ.toDouble().round();
      final key = '$encodedX,$encodedY,$encodedZ';
      if (!seen.add(key)) continue;
      samples
        ..add(encodedX)
        ..add(encodedY)
        ..add(encodedZ);
    }
  }
  if (samples.isEmpty) {
    throw FormatException('No navigation height samples in ${levelFile.path}');
  }
  return _HeightData(
    observerHeight: observerHeight,
    samples: List.unmodifiable(samples),
  );
}

double _resolveDefaultElevation({
  required List<_CompactLayer> layers,
  required File spawnFile,
}) {
  final decoded = jsonDecode(spawnFile.readAsStringSync());
  if (decoded is! List) return layers.first.elevation;

  final spawnElevations = <double>[];
  for (final value in decoded) {
    if (value is! Map<String, dynamic> || value['Type'] != 'CapsuleComponent') {
      continue;
    }
    final outer = value['Outer'];
    if (outer is! Map<String, dynamic> ||
        !('${outer['ObjectName']}'.contains("ShooterTeamStart'"))) {
      continue;
    }
    final properties = value['Properties'];
    final location = properties is Map<String, dynamic>
        ? properties['RelativeLocation']
        : null;
    final z = location is Map<String, dynamic> ? location['Z'] : null;
    if (z is num) spawnElevations.add(z.toDouble());
  }
  if (spawnElevations.isEmpty) return layers.first.elevation;

  final counts = <double, int>{};
  for (final spawnElevation in spawnElevations) {
    var selected = layers.first.elevation;
    for (final layer in layers) {
      if (layer.elevation <= spawnElevation) {
        selected = layer.elevation;
      }
    }
    counts.update(selected, (count) => count + 1, ifAbsent: () => 1);
  }

  final ordered = counts.entries.toList()
    ..sort((left, right) {
      final countOrder = right.value.compareTo(left.value);
      return countOrder != 0 ? countOrder : left.key.compareTo(right.key);
    });
  return ordered.first.key;
}

String _join(String root, String relative) =>
    '$root${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

class _WorkingLayer {
  _WorkingLayer(this.elevation);

  final double elevation;
  final List<int> vertices = [];
  final List<int> edges = [];

  _CompactLayer finish() {
    if (vertices.length.isOdd || edges.length.isOdd) {
      throw const FormatException('Vision geometry arrays must contain pairs.');
    }
    final vertexCount = vertices.length ~/ 2;
    for (final vertexIndex in edges) {
      if (vertexIndex < 0 || vertexIndex >= vertexCount) {
        throw FormatException(
          'Edge index $vertexIndex is outside $vertexCount vertices.',
        );
      }
    }
    return _CompactLayer(
      elevation: elevation,
      vertices: List.unmodifiable(vertices),
      edges: List.unmodifiable(edges),
    );
  }
}

class _CompactLayer {
  const _CompactLayer({
    required this.elevation,
    required this.vertices,
    required this.edges,
  });

  final double elevation;
  final List<int> vertices;
  final List<int> edges;
}

class _HeightData {
  const _HeightData({
    required this.observerHeight,
    required this.samples,
  });

  final double observerHeight;
  final List<int> samples;
}
