import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_payload_codecs.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';

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
    expect(() => ConvexValue.fromDart(double.nan), throwsFormatException);
    expect(() => ConvexValue.fromDart(double.infinity), throwsFormatException);
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
}

ConvexArray _folderTreeValue({String role = 'owner'}) => ConvexArray([
      ConvexObject({
        'color': const ConvexNull(),
        'createdAt': const ConvexInteger(1),
        'customColorValue': const ConvexNull(),
        'iconCodePoint': const ConvexNull(),
        'iconFontFamily': const ConvexNull(),
        'iconFontPackage': const ConvexNull(),
        'iconId': const ConvexNull(),
        'name': const ConvexString('Defaults'),
        'parentFolderPublicId': const ConvexNull(),
        'publicId': const ConvexString('folder-1'),
        'role': ConvexString(role),
        'updatedAt': const ConvexInteger(2),
      }),
    ]);

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
