import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_payload_codecs.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/src/convex_client_types.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/collab/transport/convex_transport_adapter.dart';

void main() {
  test('generated query fetch and watch decode the same typed folder tree',
      () async {
    final transport = _FakeTransport(result: _folderTreeValue());
    final api = IcarusConvexApi(transport);
    final query = api.folders.listTree(
      scope: const ConvexOptional.present(FoldersListTreeArgsScope.all),
    );

    final fetched = await query.fetch();
    final watched = await query.watch().first;

    expect(fetched.single.publicId, 'folder-1');
    expect(watched.single.role, FoldersListTreeResultItemRole.owner);
    expect(transport.lastName, 'folders:listTree');
    expect(
      (transport.lastArgs!.value['scope'] as ConvexString).value,
      'all',
    );
  });

  test('generated decoder reports the full endpoint and field path', () {
    final invalid = _folderTreeValue(role: 'future-role');
    expect(
      () => decodeFoldersListTreeResult(invalid),
      throwsA(
        isA<ConvexDecodingException>().having(
          (error) => error.path,
          'path',
          'folders.js:listTree.returns[0].role',
        ),
      ),
    );
  });

  test('unknown server error code and structured data are preserved', () async {
    final data = ConvexObject({'retryable': const ConvexBoolean(true)});
    final api = IcarusConvexApi(
      _FakeTransport(
        result: const ConvexNull(),
        error: ConvexTransportError(
          rawCode: 'FUTURE_SERVER_CODE',
          message: 'Try again later',
          data: data,
        ),
      ),
    );

    await expectLater(
      api.health.ping().fetch(),
      throwsA(
        isA<ConvexFunctionException>()
            .having((error) => error.code, 'code', ConvexErrorCode.unknown)
            .having(
              (error) => error.rawCode,
              'rawCode',
              'FUTURE_SERVER_CODE',
            )
            .having((error) => error.data, 'data', same(data)),
      ),
    );
  });

  test('normalized Convex values round-trip fixed-seed nested values', () {
    final random = Random(0x1ca405);
    for (var index = 0; index < 250; index += 1) {
      final source = _randomJsonValue(random, 4);
      final decoded = ConvexValue.fromDart(source).toDart();
      expect(jsonEncode(decoded), jsonEncode(source),
          reason: 'seed item $index');
    }

    final bytes = Uint8List.fromList([0, 1, 127, 128, 255]);
    final decodedBytes = ConvexValue.fromDart(bytes).toDart() as Uint8List;
    expect(decodedBytes, bytes);
    expect(
      (ConvexValue.fromDart(double.nan).toDart() as double).isNaN,
      isTrue,
    );
    expect(
      ConvexValue.fromDart(double.infinity).toDart(),
      double.infinity,
    );
  });

  test('annotated payload codecs enforce their exact server tag', () {
    final payload = cloudElementPayload(
      kind: 'agent',
      data: {
        'id': 'agent-1',
        'position': [12.5, 8.0],
      },
    );
    const codec = AgentConvexCodec();

    expect(codec.decode(codec.encode(payload)), payload);
    expect(
      () => codec.encode({...payload, 'kind': 'drawing'}),
      throwsFormatException,
    );
  });

  test('platform transport normalizes native and web value shapes identically',
      () async {
    final raw = <String, Object?>{
      'nullValue': null,
      'integerValue': 9223372036854775807,
      'bigintValue': BigInt.parse('-9223372036854775808'),
      'floatValue': -0.0,
      'bytesValue': Uint8List.fromList([0, 127, 255]),
      'nested': [
        true,
        {'present': 'yes'},
      ],
    };
    final nativeLike = PlatformConvexTransport(
      _ScriptedValueSource(result: raw),
    );
    final webLike = PlatformConvexTransport(
      _ScriptedValueSource(result: Map<String, Object?>.from(raw)),
    );

    final nativeValue = await nativeLike.query(
      'fixture:values',
      ConvexObject(const {}),
    );
    final webValue = await webLike.query(
      'fixture:values',
      ConvexObject(const {}),
    );

    expect(_describeConvexValue(nativeValue), _describeConvexValue(webValue));
    final object = nativeValue as ConvexObject;
    expect(object.value.containsKey('omitted'), isFalse);
    expect(
      (object.value['bytesValue'] as ConvexBytes).value,
      Uint8List.fromList([0, 127, 255]),
    );
    expect(
      (object.value['floatValue'] as ConvexFloat).value.isNegative,
      isTrue,
    );
  });

  test('recoverable function error does not close a generated watch', () async {
    final source = _ScriptedValueSource(
      result: _folderTreeValue().toDart(),
      subscriptionEvents: [
        _folderTreeValue(name: 'Before error').toDart(),
        const ConvexClientFunctionError(
          rawCode: 'CONFLICT',
          message: 'retryable conflict',
          data: {'code': 'CONFLICT', 'revision': 4},
        ),
        _folderTreeValue(name: 'After error').toDart(),
      ],
    );
    final api = IcarusConvexApi(PlatformConvexTransport(source));
    final names = <String>[];
    final errors = <Object>[];
    final receivedSecondValue = Completer<void>();
    final subscription = api.folders.listTree().watch().listen(
      (folders) {
        names.add(folders.single.name);
        if (names.length == 2) receivedSecondValue.complete();
      },
      onError: (Object error) => errors.add(error),
    );

    await receivedSecondValue.future.timeout(const Duration(seconds: 2));
    await subscription.cancel();

    expect(names, ['Before error', 'After error']);
    expect(errors, [isA<ConvexFunctionException>()]);
    final error = errors.single as ConvexFunctionException;
    expect(error.code, ConvexErrorCode.conflict);
    expect(error.rawCode, 'CONFLICT');
    expect(source.handle.cancelled, isTrue);
  });

  test('normalization failure closes a generated watch', () async {
    final source = _ScriptedValueSource(
      result: _folderTreeValue().toDart(),
      subscriptionEvents: [DateTime.utc(2026), _folderTreeValue().toDart()],
    );
    final api = IcarusConvexApi(PlatformConvexTransport(source));
    final errors = <Object>[];
    final done = Completer<void>();

    api.folders.listTree().watch().listen(
          (_) => fail('A contract-failed watch must not emit another value'),
          onError: (Object error) => errors.add(error),
          onDone: done.complete,
        );
    await done.future.timeout(const Duration(seconds: 2));

    expect(errors, [isA<ConvexNormalizationError>()]);
    expect(source.handle.cancelled, isTrue);
  });
}

ConvexArray _folderTreeValue({
  String role = 'owner',
  String name = 'Defaults',
}) =>
    ConvexArray([
      ConvexObject({
        'color': const ConvexNull(),
        'createdAt': const ConvexInteger(1),
        'customColorValue': const ConvexNull(),
        'iconCodePoint': const ConvexNull(),
        'iconFontFamily': const ConvexNull(),
        'iconFontPackage': const ConvexNull(),
        'iconId': const ConvexNull(),
        'name': ConvexString(name),
        'parentFolderPublicId': const ConvexNull(),
        'publicId': const ConvexString('folder-1'),
        'role': ConvexString(role),
        'updatedAt': const ConvexInteger(2),
      }),
    ]);

Object? _describeConvexValue(ConvexValue value) => switch (value) {
      ConvexNull() => 'null',
      ConvexBoolean(:final value) => ['boolean', value],
      ConvexInteger(:final value) => ['integer', value],
      ConvexFloat(:final value) => [
          'float',
          value == 0 && value.isNegative ? '-0' : value,
        ],
      ConvexBigInt(:final value) => ['bigint', value.toString()],
      ConvexString(:final value) => ['string', value],
      ConvexBytes(:final value) => ['bytes', ...value],
      ConvexArray(:final value) => [
          'array',
          ...value.map(_describeConvexValue),
        ],
      ConvexObject(:final value) => {
          'object': {
            for (final entry in value.entries)
              entry.key: _describeConvexValue(entry.value),
          },
        },
    };

Object? _randomJsonValue(Random random, int depth) {
  if (depth == 0) {
    return switch (random.nextInt(4)) {
      0 => null,
      1 => random.nextBool(),
      2 => random.nextInt(100000),
      _ => 'value-${random.nextInt(100000)}',
    };
  }
  return switch (random.nextInt(6)) {
    0 => null,
    1 => random.nextBool(),
    2 => random.nextInt(100000),
    3 => random.nextDouble() * 1000,
    4 => [
        for (var index = 0; index < random.nextInt(5); index += 1)
          _randomJsonValue(random, depth - 1),
      ],
    _ => {
        for (var index = 0; index < random.nextInt(5); index += 1)
          'key-$index': _randomJsonValue(random, depth - 1),
      },
  };
}

final class _FakeTransport implements ConvexTransport {
  _FakeTransport({required this.result, this.error});

  final ConvexValue result;
  final ConvexTransportError? error;
  String? lastName;
  ConvexObject? lastArgs;

  Future<ConvexValue> _respond(String name, ConvexObject args) async {
    lastName = name;
    lastArgs = args;
    final failure = error;
    if (failure != null) throw failure;
    return result;
  }

  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      _respond(name, args);

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) =>
      _respond(name, args);

  @override
  Future<ConvexValue> query(String name, ConvexObject args) =>
      _respond(name, args);

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) async* {
    yield await _respond(name, args);
  }
}

final class _ScriptedValueSource implements ConvexClientValueSource {
  _ScriptedValueSource({
    required this.result,
    this.subscriptionEvents = const [],
  });

  final Object? result;
  final List<Object?> subscriptionEvents;
  final _TestSubscriptionHandle handle = _TestSubscriptionHandle();

  @override
  Future<Object?> actionValue({
    required String name,
    required Map<String, Object?> args,
  }) async =>
      result;

  @override
  Future<Object?> mutationValue({
    required String name,
    required Map<String, Object?> args,
  }) async =>
      result;

  @override
  Future<Object?> queryValue(String name, Map<String, Object?> args) async =>
      result;

  @override
  Future<SubscriptionHandle> subscribeValue({
    required String name,
    required Map<String, Object?> args,
    required void Function(Object? value) onUpdate,
    required void Function(ConvexClientFunctionError error) onError,
  }) async {
    scheduleMicrotask(() {
      for (final event in subscriptionEvents) {
        if (handle.cancelled) return;
        if (event is ConvexClientFunctionError) {
          onError(event);
        } else {
          onUpdate(event);
        }
      }
    });
    return handle;
  }
}

final class _TestSubscriptionHandle implements SubscriptionHandle {
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}
