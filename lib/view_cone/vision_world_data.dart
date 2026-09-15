import 'dart:typed_data';
import 'dart:ui';

import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/vision_collision.dart';
import 'package:icarus/view_cone/vision_world_binary.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';
import 'package:icarus/view_cone/vision_world_segments.dart';
import 'package:icarus/view_cone/vision_world_gzip.dart';
import 'package:icarus/view_cone/verified_world_chunks.dart';

const _profileChunkDecoding =
    bool.fromEnvironment('ICARUS_PROFILE_WORLD_DECODING');

/// Offline-baked horizontal slices. Shared edges keep vertical walls stored once.
class VisionWorldData {
  VisionWorldData._({
    required this.observerHeightCm,
    required this.defaultFloorElevationCm,
    required this.elevations,
    required this.menuElevations,
    required this.planarized,
    required this.spatiallyOrdered,
    required this.projection,
    required this.maxDistanceMeters,
    required this.globalOrigins,
    required Int32List vertices,
    required double coordinateScale,
    required Offset? uvUnitsPerMeter,
    required Offset Function(Offset) projectUv,
    required Int32List edges,
    required List<Int32List> layerEdges,
    _WorldChunkSource? chunkSource,
  })  : _vertices = vertices,
        _edges = edges,
        _layerEdges = layerEdges,
        _coordinateScale = coordinateScale,
        _uvUnitsPerMeter = uvUnitsPerMeter,
        _projectUv = projectUv,
        _chunkSource = chunkSource,
        _globalLayerIds = [
          for (var i = 0; i < globalOrigins.length; i++)
            if (globalOrigins[i]) i
        ];

  factory VisionWorldData.fromJson(
    MapValue map,
    Map<String, dynamic> json, {
    required Offset Function(Offset) projectUv,
    bool allowLocalSlices = false,
  }) {
    if (json['version'] != 1 || json['map'] != map.name) {
      throw const FormatException('Invalid world geometry version or map.');
    }
    double finite(dynamic value, String name, {bool positive = false}) {
      if (value is! num || !value.isFinite || (positive && value <= 0)) {
        throw FormatException('Invalid world geometry $name.');
      }
      return value.toDouble();
    }

    final scale = finite(json['coordinateScale'], 'scale', positive: true);
    final height =
        finite(json['observerHeightCm'], 'eye height', positive: true);
    final floor = finite(json['defaultFloorElevationCm'], 'default floor');
    final unitValues = json['uvUnitsPerMeter'];
    VisionWorldProjection? projection;
    Offset? units;
    if (unitValues != null) {
      if (unitValues is! List || unitValues.length != 2) {
        throw const FormatException('Invalid world geometry meter scale.');
      }
      final u = finite(unitValues[0], 'u meter scale', positive: true);
      final v = finite(unitValues[1], 'v meter scale', positive: true);
      units = Offset(u, v);
      final origin = projectUv(Offset.zero);
      projection = VisionWorldProjection(
        origin: origin,
        axisU: projectUv(Offset(u, 0)) - origin,
        axisV: projectUv(Offset(0, v)) - origin,
      );
    }
    final maximumValue = json['maxDistanceMeters'];
    final maximum = maximumValue == null
        ? null
        : finite(maximumValue, 'maximum range', positive: true);
    if (maximum != null && projection == null) {
      throw const FormatException(
          'World range cap requires physical projection.');
    }
    final vertexValues = json['vertices'];
    final edgeValues = json['edges'];
    final layerValues = json['layers'];
    if (vertexValues is! List ||
        vertexValues.length.isOdd ||
        edgeValues is! List ||
        edgeValues.length.isOdd ||
        layerValues is! List ||
        layerValues.isEmpty) {
      throw const FormatException('Invalid world geometry arrays.');
    }
    final vertices = vertexValues is Int32List
        ? vertexValues
        : Int32List(vertexValues.length);
    // A decoded Int32List already guarantees both integer type and range.
    if (vertexValues is! Int32List) {
      for (var i = 0; i < vertexValues.length; i++) {
        final value = vertexValues[i];
        if (value is! int || value < -2147483648 || value > 2147483647) {
          throw const FormatException(
              'World vertices must be quantized integers.');
        }
        vertices[i] = value;
      }
    }

    Int32List indexes(List<dynamic> values, int count, String name) {
      final result = values is Int32List ? values : Int32List(values.length);
      for (var i = 0; i < values.length; i++) {
        final value = values[i];
        if (value is! int || value < 0 || value >= count) {
          throw FormatException('Invalid world geometry $name index.');
        }
        if (values is! Int32List) result[i] = value;
      }
      return result;
    }

    final edges = indexes(edgeValues, vertices.length ~/ 2, 'edge');
    for (var i = 0; i < edges.length; i += 2) {
      final a = edges[i] * 2, b = edges[i + 1] * 2;
      if (vertices[a] == vertices[b] && vertices[a + 1] == vertices[b + 1]) {
        throw const FormatException('Degenerate world geometry edge.');
      }
    }
    final elevations = <double>[];
    final layerEdges = <Int32List>[];
    final globalOrigins = <bool>[];
    final seenInLayer = Int32List(edges.length ~/ 2);
    for (final layer in layerValues) {
      if (layer is! Map<String, dynamic> || layer['edges'] is! List) {
        throw const FormatException('Invalid world geometry layer.');
      }
      final elevation = finite(layer['elevationCm'], 'layer elevation');
      final global = layer['globalOrigins'] ?? true;
      if (global is! bool) {
        throw const FormatException('Invalid world layer origin coverage.');
      }
      if (elevations.isNotEmpty && elevation <= elevations.last) {
        throw const FormatException(
            'World elevations must be strictly sorted.');
      }
      final ids = indexes(layer['edges'] as List, edges.length ~/ 2, 'layer');
      final marker = elevations.length + 1;
      for (final id in ids) {
        if (seenInLayer[id] == marker) {
          throw const FormatException(
              'Duplicate edge in world geometry layer.');
        }
        seenInLayer[id] = marker;
      }
      elevations.add(elevation);
      globalOrigins.add(global);
      layerEdges.add(ids);
    }
    if (!allowLocalSlices && !globalOrigins.any((value) => value)) {
      throw const FormatException(
          'World geometry needs a global manual layer.');
    }
    final menuValues = json['menuElevationsCm'];
    final menuElevations = menuValues == null
        ? <double>[floor + height]
        : menuValues is List && (menuValues.isNotEmpty || allowLocalSlices)
            ? [for (final value in menuValues) finite(value, 'menu elevation')]
            : throw const FormatException('Invalid world elevation choices.');
    if (!allowLocalSlices && menuValues != null) {
      for (var index = 0; index < menuElevations.length; index++) {
        final elevation = menuElevations[index];
        final layer = elevations.indexOf(elevation);
        if (layer < 0 ||
            !globalOrigins[layer] ||
            (index > 0 && elevation <= menuElevations[index - 1])) {
          throw const FormatException(
              'World menu must name sorted global layers.');
        }
      }
    }
    final spatialOrder = json['spatialOrder'];
    if (spatialOrder != null && spatialOrder != 'bvh-median-v1') {
      throw const FormatException('Unsupported world geometry spatial order.');
    }
    return VisionWorldData._(
      observerHeightCm: height,
      defaultFloorElevationCm: floor,
      elevations: List.unmodifiable(elevations),
      menuElevations: List.unmodifiable(menuElevations),
      planarized: json['planarized'] == true,
      spatiallyOrdered: spatialOrder == 'bvh-median-v1',
      projection: projection,
      maxDistanceMeters: maximum,
      globalOrigins: List.unmodifiable(globalOrigins),
      vertices: vertices,
      coordinateScale: scale,
      uvUnitsPerMeter: units,
      projectUv: projectUv,
      edges: edges,
      layerEdges: layerEdges,
    );
  }

  factory VisionWorldData.fromChunkManifest(
    MapValue map,
    Map<String, dynamic> json, {
    required Map<String, Uint8List> compressedChunks,
    required Offset Function(Offset) projectUv,
    int maxDecodedBytes = 128 * 1024 * 1024,
  }) {
    if (json['format'] != 'chunked-v1' || json['layers'] is! List) {
      throw const FormatException('Invalid chunked world manifest.');
    }
    final manifestLayers = json['layers'] as List;
    final metadata = VisionWorldData.fromJson(
        map,
        {
          ...json,
          'vertices': <int>[],
          'edges': <int>[],
          'layers': [
            for (final layer in manifestLayers)
              if (layer is Map<String, dynamic>)
                {...layer, 'edges': <int>[]}
              else
                throw const FormatException('Invalid world manifest layer.')
          ],
        },
        projectUv: projectUv);
    if (maxDecodedBytes <= 0) {
      throw ArgumentError.value(maxDecodedBytes, 'maxDecodedBytes');
    }
    final source = _WorldChunkSource(
        map, metadata, json, compressedChunks, projectUv, maxDecodedBytes);
    return VisionWorldData._(
      observerHeightCm: metadata.observerHeightCm,
      defaultFloorElevationCm: metadata.defaultFloorElevationCm,
      elevations: metadata.elevations,
      menuElevations: metadata.menuElevations,
      planarized: metadata.planarized,
      spatiallyOrdered: metadata.spatiallyOrdered,
      projection: metadata.projection,
      maxDistanceMeters: metadata.maxDistanceMeters,
      globalOrigins: metadata.globalOrigins,
      vertices: metadata._vertices,
      coordinateScale: metadata._coordinateScale,
      uvUnitsPerMeter: metadata._uvUnitsPerMeter,
      projectUv: projectUv,
      edges: metadata._edges,
      layerEdges: metadata._layerEdges,
      chunkSource: source,
    );
  }

  final double observerHeightCm;
  final double defaultFloorElevationCm;
  final List<double> elevations;
  final List<double> menuElevations;
  final bool planarized;
  final bool spatiallyOrdered;
  final VisionWorldProjection? projection;
  final double? maxDistanceMeters;
  final List<bool> globalOrigins;
  final List<int> _globalLayerIds;
  final Int32List _vertices;
  final double _coordinateScale;
  final Offset? _uvUnitsPerMeter;
  final Offset Function(Offset) _projectUv;
  final Int32List _edges;
  final List<Int32List> _layerEdges;
  final _WorldChunkSource? _chunkSource;

  ({int blocks, int bytes}) get residentChunks => (
        blocks: _chunkSource?.cache.length ?? 0,
        bytes: _chunkSource?.cachedBytes ?? 0,
      );

  /// Offline release-probe counters. Timing is compiled out of normal builds.
  ({
    int count,
    int micros,
    int gzipMicros,
    int binaryMicros,
    int validationMicros
  }) get chunkDecodeProfile => (
        count: _chunkSource?.decodeCount ?? 0,
        micros: _chunkSource?.decodeMicros ?? 0,
        gzipMicros: _chunkSource?.gzipMicros ?? 0,
        binaryMicros: _chunkSource?.binaryMicros ?? 0,
        validationMicros: _chunkSource?.validationMicros ?? 0,
      );

  /// Bundle validation checks every compressed block without retaining every
  /// decoded table or constructing every visibility polygon at once.
  void validateAllChunks() {
    final source = _chunkSource;
    if (source == null) return;
    for (var chunk = 0; chunk < source.names.length; chunk++) {
      source.load(chunk);
    }
  }

  int nearestLayer(double elevation) => _nearest(elevations, elevation);

  int nearestGlobalLayer(double elevation) {
    var low = 0;
    var high = _globalLayerIds.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (elevations[_globalLayerIds[middle]] < elevation) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low == 0) return _globalLayerIds.first;
    if (low == _globalLayerIds.length) return _globalLayerIds.last;
    final before = _globalLayerIds[low - 1], after = _globalLayerIds[low];
    return elevation - elevations[before] <= elevations[after] - elevation
        ? before
        : after;
  }

  static int _nearest(List<double> elevations, double elevation) {
    var low = 0;
    var high = elevations.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (elevations[middle] < elevation) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low == 0) return 0;
    if (low == elevations.length) return low - 1;
    return elevation - elevations[low - 1] <= elevations[low] - elevation
        ? low - 1
        : low;
  }

  List<VisionSegment> segmentsForLayer(int index,
      {required bool isAttack, bool metric = false}) {
    final source = _chunkSource;
    if (source != null) return source.segments(index, isAttack, metric);
    if (metric) {
      return VisionWorldSegments.fromQuantized(
        vertices: _vertices,
        edges: _edges,
        layerEdges: _layerEdges[index],
        coordinateScale: _coordinateScale,
        uvUnitsPerMeter: _uvUnitsPerMeter!,
      );
    }
    Offset point(int vertexId) {
      final u = _vertices[vertexId * 2] / _coordinateScale;
      final v = _vertices[vertexId * 2 + 1] / _coordinateScale;
      final value = metric
          ? Offset(u / _uvUnitsPerMeter!.dx, v / _uvUnitsPerMeter.dy)
          : _projectUv(Offset(u, v));
      if (!value.dx.isFinite || !value.dy.isFinite) {
        throw const FormatException('Non-finite world vertex projection.');
      }
      return metric || isAttack
          ? value
          : Offset(1000 * (16 / 9) - value.dx, 1000 - value.dy);
    }

    return List.unmodifiable([
      for (final id in _layerEdges[index])
        VisionSegment.unthickened(
            point(_edges[id * 2]), point(_edges[id * 2 + 1])),
    ]);
  }
}

/// Compressed blocks remain small; only nearby occupied height blocks inflate.
/// Segment objects copy their coordinates, so evicted typed tables can be freed
/// even while an active cone retains its spatial index.
class _WorldChunkSource {
  _WorldChunkSource(this.map, this.metadata, Map<String, dynamic> manifest,
      Map<String, Uint8List> compressed, this.projectUv, this.maxDecodedBytes)
      : verifiedCompressed = compressed is VerifiedWorldChunks,
        compressed = Map.unmodifiable(compressed) {
    final chunkValues = manifest['chunks'];
    if (chunkValues is! List || chunkValues.isEmpty) {
      throw const FormatException('World manifest has no chunks.');
    }
    for (final descriptor in chunkValues) {
      if (descriptor is! Map<String, dynamic>) {
        throw const FormatException('Invalid world chunk descriptor.');
      }
      final asset = descriptor['asset'];
      if (asset is! String ||
          !RegExp(r'^[a-z0-9_-]+\.bin\.gz$').hasMatch(asset) ||
          names.contains(asset) ||
          !compressed.containsKey(asset)) {
        throw const FormatException('Invalid or missing world chunk asset.');
      }
      names.add(asset);
      final compressedSize = descriptor['compressedBytes'];
      final rawSize = descriptor['uncompressedBytes'];
      if ((compressedSize != null &&
              (compressedSize is! int ||
                  compressedSize <= 0 ||
                  compressedSize != compressed[asset]!.lengthInBytes)) ||
          (rawSize != null && (rawSize is! int || rawSize <= 0))) {
        throw const FormatException('Invalid world chunk byte counts.');
      }
      rawSizes.add(rawSize as int?);
      chunkLayers.add(<int>[]);
    }
    if (compressed.length != names.length) {
      throw const FormatException('Unexpected world chunk payload.');
    }
    for (final value in manifest['layers'] as List) {
      final chunk = value['chunkIndex'], local = value['localLayerIndex'];
      if (chunk is! int ||
          chunk < 0 ||
          chunk >= names.length ||
          local is! int ||
          local != chunkLayers[chunk].length) {
        throw const FormatException('Invalid world chunk layer mapping.');
      }
      chunkLayers[chunk].add(layerChunks.length);
      layerChunks.add(chunk);
      localLayers.add(local);
    }
    if (chunkLayers.any((layers) => layers.isEmpty)) {
      throw const FormatException('Unused world chunk.');
    }
  }

  final MapValue map;
  final VisionWorldData metadata;
  final Map<String, Uint8List> compressed;
  final bool verifiedCompressed;
  final Offset Function(Offset) projectUv;
  final int maxDecodedBytes;
  final names = <String>[];
  final rawSizes = <int?>[];
  final layerChunks = <int>[];
  final localLayers = <int>[];
  final chunkLayers = <List<int>>[];
  final cache = <int, ({VisionWorldData data, int bytes})>{};
  var cachedBytes = 0;
  var decodeCount = 0;
  var decodeMicros = 0;
  var gzipMicros = 0;
  var binaryMicros = 0;
  var validationMicros = 0;

  List<VisionSegment> segments(int index, bool attack, bool metric) {
    RangeError.checkValidIndex(index, layerChunks);
    return load(layerChunks[index])
        .segmentsForLayer(localLayers[index], isAttack: attack, metric: metric);
  }

  VisionWorldData load(int chunk) {
    var cached = cache.remove(chunk);
    if (cached == null) {
      final watch = _profileChunkDecoding ? (Stopwatch()..start()) : null;
      final raw = decodeWorldGzip(compressed[names[chunk]]!,
          verifyChecksum: !verifiedCompressed);
      final inflatedAt = watch?.elapsedMicroseconds ?? 0;
      if (rawSizes[chunk] != null && rawSizes[chunk] != raw.lengthInBytes) {
        throw const FormatException(
            'World chunk inflated byte count mismatch.');
      }
      final decoded = decodeVisionWorldBinary(raw);
      final binaryAt = watch?.elapsedMicroseconds ?? 0;
      final data = VisionWorldData.fromJson(map, decoded,
          projectUv: projectUv, allowLocalSlices: true);
      if (data._coordinateScale != metadata._coordinateScale ||
          data._uvUnitsPerMeter != metadata._uvUnitsPerMeter ||
          data.observerHeightCm != metadata.observerHeightCm ||
          data.defaultFloorElevationCm != metadata.defaultFloorElevationCm ||
          data.planarized != metadata.planarized ||
          data.spatiallyOrdered != metadata.spatiallyOrdered ||
          data.maxDistanceMeters != metadata.maxDistanceMeters ||
          data.elevations.length != chunkLayers[chunk].length) {
        throw const FormatException('World chunk metadata mismatch.');
      }
      for (var local = 0; local < chunkLayers[chunk].length; local++) {
        final global = chunkLayers[chunk][local];
        if (data.elevations[local] != metadata.elevations[global] ||
            data.globalOrigins[local] != metadata.globalOrigins[global]) {
          throw const FormatException('World chunk elevation mismatch.');
        }
      }
      cached = (data: data, bytes: raw.lengthInBytes);
      cachedBytes += cached.bytes;
      if (watch != null) {
        decodeCount++;
        decodeMicros += watch.elapsedMicroseconds;
        gzipMicros += inflatedAt;
        binaryMicros += binaryAt - inflatedAt;
        validationMicros += watch.elapsedMicroseconds - binaryAt;
      }
    }
    cache[chunk] = cached;
    // Preserve neighboring heights for independently moving agents. Bytes bound
    // retention, so many small blocks do not evict each other prematurely.
    while (cache.length > 1 && cachedBytes > maxDecodedBytes) {
      cachedBytes -= cache.remove(cache.keys.first)!.bytes;
    }
    return cached.data;
  }
}
