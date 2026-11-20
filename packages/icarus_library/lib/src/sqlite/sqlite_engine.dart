import 'dart:async';
import 'dart:isolate';

import '../store/engine_contract.dart';
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

final class _Commit extends _Request {
  const _Commit(super.id, this.changes);

  final List<Change> changes;
}

final class _Release extends _Request {
  const _Release(super.id);
}

final class _HoldNextCommit {
  const _HoldNextCommit();
}

final class _LetGo {
  const _LetGo();
}

final class _Reached {
  const _Reached();
}

final class _Ready {
  const _Ready(this.requests);

  final SendPort requests;
}

final class _Reply {
  const _Reply(this.id, this.result);

  final int id;
  final Object result;
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
      final waiting = <_Request>[];
      var holding = false;
      var busy = false;
      Completer<void>? letGo;
      Future<void> answer() async {
        if (busy) return;
        busy = true;
        while (waiting.isNotEmpty) {
          final request = waiting.removeAt(0);
          if (request is _Commit && holding) {
            holding = false;
            final gate = letGo = Completer<void>();
            replies.send(const _Reached());
            await gate.future;
          }
          final Object result = switch (request) {
            _Read(:final area, :final key) => rows.read(area, key),
            _Keys(:final area, :final prefix) => rows.keys(area, prefix),
            _Entries(:final area, :final prefix) => rows.entries(area, prefix),
            _Commit(:final changes) => rows.commit(changes),
            _Release() => _released(rows, requests),
          };
          replies.send(_Reply(request.id, result));
        }
        busy = false;
      }

      requests.listen((message) {
        switch (message) {
          case _HoldNextCommit():
            holding = true;
          case _LetGo():
            letGo?.complete();
          case final _Request request:
            waiting.add(request);
            unawaited(answer());
        }
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
  var _closed = false;

  @override
  Future<Leasing> lease() async {
    if (_closed) return const LeaseFailed(EngineClosed());
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
          granted!._pending.remove(id)!.$1.complete(result);
        case _Reached():
          granted!._held?._reached.complete();
        case [final error, final stack]:
          final failure = DeviceFailure(
            'the library worker failed: $error\n$stack',
          );
          granted?._stop(failure);
          if (!first.isCompleted) first.complete(LeaseFailed(failure));
        case null:
          replies.close();
          const failure = DeviceFailure('the library worker stopped');
          if (granted case final lease? when lease._worker is _Running) {
            lease._stop(failure);
          }
          if (!first.isCompleted) first.complete(const LeaseFailed(failure));
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

  PendingWrite holdNextCommit() => _granted.last._holdNextCommit();

  Future<void> close() async {
    _closed = true;
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
  const _Gone(this.failure);

  final StorageFailure failure;
}

final class SqliteLease implements StorageLease {
  SqliteLease._(SendPort requests) : _worker = _Running(requests);

  _Worker _worker;
  _HeldCommit? _held;
  var _next = 0;
  final _pending =
      <int, (Completer<Object>, Object Function(StorageFailure))>{};

  PendingWrite _holdNextCommit() => switch (_worker) {
    _Running(:final requests) => _held = _HeldCommit(
      requests..send(const _HoldNextCommit()),
    ),
    _Ended() || _Gone() => throw StateError('no running lease to hold'),
  };

  void _stop(StorageFailure failure) {
    _worker = _Gone(failure);
    for (final (waiting, gone) in _pending.values) {
      waiting.complete(gone(failure));
    }
    _pending.clear();
  }

  Future<R> _ask<R extends Object>(
    _Request Function(int id) request, {
    required R ended,
    required R Function(StorageFailure failure) gone,
  }) async {
    switch (_worker) {
      case _Ended():
        return ended;
      case _Gone(:final failure):
        return gone(failure);
      case _Running(:final requests):
        final id = _next++;
        final reply = Completer<Object>();
        _pending[id] = (reply, gone);
        requests.send(request(id));
        return await reply.future as R;
    }
  }

  static const _ended = StorageFailed<Never>(LeaseEnded());

  @override
  LeaseStatus get status => switch (_worker) {
    _Running() => const Holding(),
    _Ended() || _Gone() => const Ended(),
  };

  @override
  int get maxKeyLength => rowsMaxKeyLength;

  static StorageFailed<Never> _failed(StorageFailure failure) =>
      StorageFailed(failure);

  @override
  Future<KeyRead> read(String area, String key) => _ask(
    (id) => _Read(id, area, key),
    ended: const KeyNotRead(LeaseEnded()),
    gone: KeyNotRead.new,
  );

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) =>
      _ask((id) => _Keys(id, area, prefix), ended: _ended, gone: _failed);

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) =>
      _ask((id) => _Entries(id, area, prefix), ended: _ended, gone: _failed);

  @override
  Future<Committing> commit(List<Change> changes) => _ask(
    (id) => _Commit(id, changes),
    ended: const CommitRefused(LeaseEnded()),
    gone: CommitUnknown.new,
  );

  @override
  Future<Releasing> release() async {
    if (_worker is! _Running) return const Released();
    final releasing = _ask<Stored<void>>(
      _Release.new,
      ended: done,
      gone: _failed,
    );
    _worker = const _Ended();
    return switch (await releasing) {
      Done() => const Released(),
      StorageFailed(:final failure) => ReleaseFailed(failure),
    };
  }
}

final class _HeldCommit implements PendingWrite {
  _HeldCommit(this._requests);

  final SendPort _requests;
  final _reached = Completer<void>();

  @override
  Future<void> get reached => _reached.future;

  @override
  void letGo() => _requests.send(const _LetGo());
}
