import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'replay_decoder.dart';

const bool replayDecoderAvailable = true;

/// Where the bundled `native/replay` library sits next to the executable.
/// `ICARUS_REPLAY_LIBRARY` overrides it for tests and tools.
String replayNativeLibraryPath() {
  final override = Platform.environment['ICARUS_REPLAY_LIBRARY'];
  if (override != null && override.isNotEmpty) return override;
  final executable = File(Platform.resolvedExecutable).parent;
  if (Platform.isWindows) return '${executable.path}/icarus_replay.dll';
  if (Platform.isLinux) return '${executable.path}/lib/libicarus_replay.so';
  if (Platform.isMacOS) {
    return '${executable.parent.path}/Frameworks/libicarus_replay.dylib';
  }
  throw UnsupportedError('Replays require a desktop build.');
}

final class _Buffer extends Struct {
  external Pointer<Uint8> ptr;

  @Size()
  external int len;

  @Uint32()
  external int isError;
}

typedef _ProbeC = _Buffer Function(Pointer<Utf8>);
typedef _DecodeC = _Buffer Function(
    Pointer<Utf8>, Pointer<Uint32>, Pointer<Uint32>);
typedef _DecodeD = _Buffer Function(
    Pointer<Utf8>, Pointer<Uint32>, Pointer<Uint32>);
typedef _FreeC = Void Function(_Buffer);
typedef _FreeD = void Function(_Buffer);

class _Library {
  _Library(DynamicLibrary library)
      : probe = library.lookupFunction<_ProbeC, _ProbeC>('icarus_replay_probe'),
        decode = library.lookupFunction<_DecodeC, _DecodeD>(
          'icarus_replay_decode',
        ),
        free = library.lookupFunction<_FreeC, _FreeD>('icarus_replay_free');

  final _Buffer Function(Pointer<Utf8>) probe;
  final _DecodeD decode;
  final _FreeD free;

  static _Library? _instance;

  /// Opened once per isolate.
  static _Library get instance {
    final existing = _instance;
    if (existing != null) return existing;
    final DynamicLibrary library;
    try {
      library = DynamicLibrary.open(replayNativeLibraryPath());
    } on ArgumentError catch (error) {
      throw ReplayDecodeException(
        'io',
        'The replay decoder is missing from this install ($error).',
      );
    }
    return _instance = _Library(library);
  }

  /// Copies the buffer out, frees it, and throws when it holds an error.
  Uint8List take(_Buffer buffer) {
    try {
      final bytes = Uint8List.fromList(buffer.ptr.asTypedList(buffer.len));
      if (buffer.isError != 0) {
        throw ReplayDecodeException.fromJson(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        );
      }
      return bytes;
    } finally {
      free(buffer);
    }
  }
}

Future<ReplayProbe> probeReplay(String path) => Isolate.run(() {
      final library = _Library.instance;
      final nativePath = path.toNativeUtf8();
      try {
        final bytes = library.take(library.probe(nativePath));
        return ReplayProbe.fromJson(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        );
      } finally {
        malloc.free(nativePath);
      }
    });

ReplayDecodeJob decodeReplay(String path) => _IoDecodeJob(path);

class _IoDecodeJob implements ReplayDecodeJob {
  _IoDecodeJob(String path) {
    // Both cells are written across isolates, so they live in native memory
    // and are freed only after the decoding isolate has finished with them.
    final progressAddress = _progress.address;
    final cancelAddress = _cancel.address;
    result = Isolate.run(() {
      final library = _Library.instance;
      final nativePath = path.toNativeUtf8();
      try {
        return library.take(
          library.decode(
            nativePath,
            Pointer<Uint32>.fromAddress(progressAddress),
            Pointer<Uint32>.fromAddress(cancelAddress),
          ),
        );
      } finally {
        malloc.free(nativePath);
      }
    }).whenComplete(() {
      calloc.free(_progress);
      calloc.free(_cancel);
      _done = true;
    });
  }

  final Pointer<Uint32> _progress = calloc<Uint32>();
  final Pointer<Uint32> _cancel = calloc<Uint32>();
  bool _done = false;

  @override
  late final Future<Uint8List> result;

  @override
  double get progress => _done ? 1 : _progress.value / 10000;

  @override
  void cancel() {
    if (!_done) _cancel.value = 1;
  }
}
