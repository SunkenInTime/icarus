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

/// The library's `IcarusReplayControl`: a decode's progress and cancel
/// request, read and written atomically on the native side.
final class _Control extends Opaque {}

typedef _ProbeC = _Buffer Function(Pointer<Utf8>);
typedef _DecodeC = _Buffer Function(Pointer<Utf8>, Pointer<_Control>);
typedef _FreeC = Void Function(_Buffer);
typedef _FreeD = void Function(_Buffer);
typedef _ControlNewC = Pointer<_Control> Function();
typedef _ControlProgressC = Uint32 Function(Pointer<_Control>);
typedef _ControlProgressD = int Function(Pointer<_Control>);
typedef _ControlC = Void Function(Pointer<_Control>);
typedef _ControlD = void Function(Pointer<_Control>);

class _Library {
  _Library(DynamicLibrary library)
      : probe = library.lookupFunction<_ProbeC, _ProbeC>('icarus_replay_probe'),
        decode = library.lookupFunction<_DecodeC, _DecodeC>(
          'icarus_replay_decode',
        ),
        free = library.lookupFunction<_FreeC, _FreeD>('icarus_replay_free'),
        controlNew = library.lookupFunction<_ControlNewC, _ControlNewC>(
          'icarus_replay_control_new',
        ),
        controlProgress =
            library.lookupFunction<_ControlProgressC, _ControlProgressD>(
          'icarus_replay_control_progress',
        ),
        controlCancel = library.lookupFunction<_ControlC, _ControlD>(
          'icarus_replay_control_cancel',
        ),
        controlFree = library.lookupFunction<_ControlC, _ControlD>(
          'icarus_replay_control_free',
        );

  final _Buffer Function(Pointer<Utf8>) probe;
  final _Buffer Function(Pointer<Utf8>, Pointer<_Control>) decode;
  final _FreeD free;
  final Pointer<_Control> Function() controlNew;
  final _ControlProgressD controlProgress;
  final _ControlD controlCancel;
  final _ControlD controlFree;

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
    // The control is shared with the decoding isolate by address, so it is
    // freed only after that isolate has finished with it. Both sides reach
    // it only through the library, which accesses it atomically.
    final controlAddress = _control.address;
    result = Isolate.run(() {
      final library = _Library.instance;
      final nativePath = path.toNativeUtf8();
      try {
        return library.take(
          library.decode(
            nativePath,
            Pointer<_Control>.fromAddress(controlAddress),
          ),
        );
      } finally {
        malloc.free(nativePath);
      }
    }).whenComplete(() {
      _done = true;
      _library.controlFree(_control);
    });
  }

  final _Library _library = _Library.instance;
  late final Pointer<_Control> _control = _library.controlNew();
  bool _done = false;

  @override
  late final Future<Uint8List> result;

  @override
  double get progress => _done ? 1 : _library.controlProgress(_control) / 10000;

  @override
  void cancel() {
    if (!_done) _library.controlCancel(_control);
  }
}
