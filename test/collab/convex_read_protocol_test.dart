import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';

/// The server refuses element and lineup payloads, and the shell, to a
/// client that does not say which protocol it reads, so every such read
/// says it.
void main() {
  late _RecordingTransport transport;
  late ConvexStrategyRepository repository;

  setUp(() {
    transport = _RecordingTransport();
    repository = ConvexStrategyRepository(IcarusConvexApi(transport));
  });

  void expectProtocolSent(String name) {
    final (calledName, args) = transport.calls.single;
    expect(calledName, name);
    expect(
      args.value['clientProtocolVersion']?.toDart(),
      currentCloudProtocolVersion,
    );
  }

  test('the shell is read with the protocol', () async {
    await expectLater(repository.fetchShell('strategy'), throwsStateError);
    expectProtocolSent('strategy:getShell');
  });

  test('the shell is watched with the protocol', () async {
    await expectLater(
        repository.watchShell('strategy').first, throwsStateError);
    expectProtocolSent('strategy:getShell');
  });

  test('a page snapshot is read with the protocol', () async {
    await expectLater(
      repository.fetchPageSnapshot(
        strategyPublicId: 'strategy',
        pagePublicId: 'page',
      ),
      throwsStateError,
    );
    expectProtocolSent('page:getSnapshot');
  });

  test('a page snapshot is watched with the protocol', () async {
    await expectLater(
      repository
          .watchPageSnapshot(strategyPublicId: 'strategy', pagePublicId: 'page')
          .first,
      throwsStateError,
    );
    expectProtocolSent('page:getSnapshot');
  });

  test('a full snapshot is read with the protocol', () async {
    await expectLater(
      repository.fetchFullSnapshot('strategy'),
      throwsStateError,
    );
    expectProtocolSent('strategy:getFullSnapshot');
  });
}

final class _RecordingTransport implements ConvexTransport {
  final calls = <(String, ConvexObject)>[];

  @override
  Future<ConvexValue> query(String name, ConvexObject args) async {
    calls.add((name, args));
    throw StateError('not answered in this test');
  }

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) {
    calls.add((name, args));
    return Stream.error(StateError('not answered in this test'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
