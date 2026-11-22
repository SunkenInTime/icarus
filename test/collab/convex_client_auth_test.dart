import 'dart:async';

import 'package:convex_flutter/convex_flutter.dart' as native;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/src/convex_client_native.dart';
import 'package:icarus/collab/src/convex_client_types.dart';

class _Handle implements native.AuthHandleWrapper {
  var disposed = 0;

  @override
  void dispose() => disposed++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Vendored implements native.ConvexClient {
  final clearing = Completer<void>();
  final setting = Completer<native.AuthHandleWrapper>();

  @override
  Future<void> clearAuth() => clearing.future;

  @override
  Future<native.AuthHandleWrapper> setAuthWithRefresh({
    required Future<String?> Function() fetchToken,
    void Function(bool isAuthenticated)? onAuthChange,
  }) =>
      setting.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _config = ConvexConfig(deploymentUrl: 'https://x', clientId: 'test');

Future<List<Object>> _uncaught(Future<void> Function() body) async {
  final errors = <Object>[];
  final done = Completer<void>();
  runZonedGuarded(
    () => body().whenComplete(done.complete),
    (error, _) => errors.add(error),
  );
  await done.future;
  await pumpEventQueue();
  return errors;
}

void main() {
  test(
      'clearAuth counts the change at the call and hands back the vendored '
      'future itself', () {
    final vendored = _Vendored();
    final client = ConvexClient.over(vendored, _config);

    expect(client.clearAuth(), same(vendored.clearing.future));
    expect(client.authChanges, 1);
  });

  test(
      'a failed clearAuth whose future is dropped stays uncaught, as with '
      'nothing attached', () async {
    final refused = StateError('refused');
    final errors = await _uncaught(() async {
      final vendored = _Vendored();
      ConvexClient.over(vendored, _config).clearAuth();
      vendored.clearing.completeError(refused);
    });
    expect(errors, [same(refused)]);
  });

  test(
      'setAuthWithRefresh counts the change before the vendored call settles, '
      'and its failure reaches the caller unchanged', () async {
    final vendored = _Vendored();
    final client = ConvexClient.over(vendored, _config);
    final refused = StateError('refused');

    final setting = client.setAuthWithRefresh(fetchToken: () async => 't');
    expect(client.authChanges, 1);
    vendored.setting.completeError(refused);
    await expectLater(setting, throwsA(same(refused)));
    expect(client.authChanges, 1);
  });

  test('disposing the handle counts a change and disposes the vendored handle',
      () async {
    final vendored = _Vendored();
    final client = ConvexClient.over(vendored, _config);
    final handle = _Handle();
    final setting = client.setAuthWithRefresh(fetchToken: () async => 't');
    vendored.setting.complete(handle);
    final wrapper = await setting;

    wrapper.dispose();
    expect(handle.disposed, 1);
    expect(client.authChanges, 2);
  });
}
