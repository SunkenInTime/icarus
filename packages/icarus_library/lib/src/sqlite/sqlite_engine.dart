import 'dart:async';
import 'dart:isolate';

import '../store/engine.dart';
import 'library_file.dart';
import 'rows_database.dart';

sealed class _Request {
  const _Request(this.id);

  final int id;
}

final class _Read extends _Request {
  const _Read(super.id, this.area, this.key);

  final String area;
  final String key;
}

final class _Keys extends _Request {
  const _Keys(super.id, this.area, this.prefix);

  final String area;
  final String prefix;
}

final class _Entries extends _Request {
  const _Entries(super.id, this.area, this.prefix);

  final String area;
  final String prefix;
}

final class _Write extends _Request {
  const _Write(super.id, this.area, this.values);

  final String area;
  final Map<String, String> values;
}

final class _Delete extends _Request {
  const _Delete(super.id, this.area, this.keys);

  final String area;
  final List<String> keys;
}

final class _Release extends _Request {
  const _Release(super.id);
}

final class _Ready {
  const _Ready(this.requests);

  final SendPort requests;
}

final class _Reply {
  const _Reply(this.id, this.result);

  final int id;
  final Stored<Object?> result;
}

void _serve((String, SendPort) start) {
  final (path, replies) = start;
  switch (openLibraryFile(path, const DiskLibraryFiles())) {
    case RowsHeld():
      replies.send(const HeldByAnotherWriter());
    case RowsRefused(:final failure):
      replies.send(LeaseFailed(failure));
    case RowsOpened(:final rows):
      final requests = ReceivePort();
      replies.send(_Ready(requests.sendPort));
      requests.listen((message) {
        final request = message as _Request;
        final Stored<Object?> result = switch (request) {
          _Read(:final area, :final key) => rows.read(area, key),
          _Keys(:final area, :final prefix) => rows.keys(area, prefix),
          _Entries(:final area, :final prefix) => rows.entries(area, prefix),
          _Write(:final area, :final values) => rows.write(area, values),
          _Delete(:final area, :final keys) => rows.delete(area, keys),
          _Release() => _released(rows, requests),
        };
        replies.send(_Reply(request.id, result));
      });
  }
}

Stored<void> _released(RowsDatabase rows, ReceivePort requests) {
  rows.close();
  requests.close();
  return done;
}

final class SqliteEngine implements StorageEngine {
  SqliteEngine(this.path);

  final String path;
  final _granted = <SqliteLease>[];

  @override
  Future<Leasing> lease() async {
    final replies = ReceivePort();
    final first = Completer<Leasing>();
    SqliteLease? granted;
    replies.listen((message) {
      switch (message) {
        case _Ready(:final requests):
          final lease = granted = SqliteLease._(requests);
          _granted.add(lease);
          first.complete(Leased(lease));
        case final Leasing refused:
          replies.close();
          first.complete(refused);
        case _Reply(:final id, :final result):
          granted!._pending.remove(id)!.complete(result);
        case [final error, final stack]:
          granted?._stop('the library worker failed: $error\n$stack');
          if (!first.isCompleted) first.completeError(StateError('$error'));
        case null:
          replies.close();
          if (granted case final lease? when lease._worker is _Running) {
            lease._stop('the library worker stopped');
          }
          if (!first.isCompleted) {
            first.completeError(StateError('the library worker stopped'));
          }
      }
    });
    await Isolate.spawn(
      _serve,
      (path, replies.sendPort),
      onError: replies.sendPort,
      onExit: replies.sendPort,
      debugName: 'icarus library',
    );
    return first.future;
  }

  Future<void> close() async {
    for (final lease in _granted) {
      await lease.release();
    }
    _granted.clear();
  }
}

sealed class _Worker {
  const _Worker();
}

final class _Running extends _Worker {
  const _Running(this.requests);

  final SendPort requests;
}

final class _Ended extends _Worker {
  const _Ended();
}

final class _Gone extends _Worker {
  const _Gone(this.reason);

  final String reason;
}

final class SqliteLease implements StorageLease {
  SqliteLease._(SendPort requests) : _worker = _Running(requests);

  _Worker _worker;
  var _next = 0;
  final _pending = <int, Completer<Stored<Object?>>>{};

  void _stop(String reason) {
    _worker = _Gone(reason);
    for (final waiting in _pending.values) {
      waiting.completeError(StateError(reason));
    }
    _pending.clear();
  }

  Future<Stored<T>> _ask<T>(_Request Function(int id) request) async {
    switch (_worker) {
      case _Ended():
        return const StorageFailed(LeaseEnded());
      case _Gone(:final reason):
        throw StateError(reason);
      case _Running(:final requests):
        final id = _next++;
        final reply = _pending[id] = Completer<Stored<Object?>>();
        requests.send(request(id));
        return await reply.future as Stored<T>;
    }
  }

  @override
  int get maxKeyLength => rowsMaxKeyLength;

  @override
  Future<Stored<String?>> read(String area, String key) =>
      _ask((id) => _Read(id, area, key));

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) =>
      _ask((id) => _Keys(id, area, prefix));

  Future<Stored<Map<String, String>>> entries(String area, String prefix) =>
      _ask((id) => _Entries(id, area, prefix));

  @override
  Future<Stored<void>> write(String area, Map<String, String> values) =>
      _ask((id) => _Write(id, area, values));

  @override
  Future<Stored<void>> delete(String area, Iterable<String> keys) =>
      _ask((id) => _Delete(id, area, keys.toList()));

  @override
  Future<void> release() async {
    if (_worker is! _Running) return;
    final releasing = _ask<void>(_Release.new);
    _worker = const _Ended();
    await releasing;
  }
}
