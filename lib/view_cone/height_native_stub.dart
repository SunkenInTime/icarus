import 'dart:typed_data';

class HeightFrame {
  HeightFrame(this.stamp, this.positions, this.offsets, this.timings);
  final int stamp;
  final Float32List positions;
  final Uint32List offsets;
  final Map<String, num> timings;
  Float32List cone(int index) =>
      Float32List.sublistView(positions, offsets[index], offsets[index + 1]);
}

String heightNativeLibraryPath() =>
    throw UnsupportedError('Native height workers require desktop.');

class HeightNativeWorker {
  final Map<String, Object?> info = const {};
  static Future<HeightNativeWorker> open(
          String dll, String folder, int workers) async =>
      throw UnsupportedError('Native height workers require desktop.');
  static Future<HeightNativeWorker> openProtocolTestWorker(
          void Function(List<Object>) entry) async =>
      throw UnsupportedError('Native height workers require desktop.');
  Future<HeightFrame> compute(int stamp, Float64List queries) async =>
      throw UnsupportedError('Native height workers require desktop.');
  Future<void> close() async {}
}
