import 'dart:async';

import 'package:convex_flutter/src/convex_config.dart';
import 'package:convex_flutter/src/impl/convex_client_native.dart';
import 'package:convex_flutter/src/rust/lib.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Restarting implements MobileConvexClient {
  @override
  Future<ClientGeneration> generation() => Completer<ClientGeneration>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
      'asking the generation of a client that never answers times out like '
      'its other calls', () async {
    final client = NativeConvexClient.over(
      _Restarting(),
      const ConvexConfig(
        deploymentUrl: 'https://generation-check.convex.cloud',
        operationTimeout: Duration(milliseconds: 50),
      ),
    );

    await expectLater(
      client.generation(),
      throwsA(isA<TimeoutException>()),
    );
  });
}
