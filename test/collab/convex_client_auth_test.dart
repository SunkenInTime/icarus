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

void main() {
  group('clearAuth', () {
    test(
        'hands back the vendored future itself, and counts a change that '
        'settles when it does', () async {
      final vendored = _Vendored();
      final client = ConvexClient.over(vendored, _config);

      final cleared = client.clearAuth();
      expect(cleared, same(vendored.clearing.future));
      expect(client.authChanges, 1);
      expect(client.authSettled, isFalse);

      vendored.clearing.complete();
      await cleared;
      expect(client.authSettled, isTrue);
    });

    test(
        'a listener already on the vendored future still runs before the caller '
        'goes on, on success and on failure', () async {
      for (final fails in [false, true]) {
        final vendored = _Vendored();
        final client = ConvexClient.over(vendored, _config);
        final order = <String>[];
        unawaited(
          vendored.clearing.future.then<void>(
            (_) => order.add('listener'),
            onError: (Object _) => order.add('listener'),
          ),
        );
        final caller = () async {
          try {
            await client.clearAuth();
          } catch (_) {}
          order.add('caller');
        }();
        if (fails) {
          vendored.clearing.completeError(StateError('refused'));
        } else {
          vendored.clearing.complete();
        }
        await caller;
        expect(order, ['listener', 'caller'], reason: 'fails: $fails');
        expect(client.authSettled, isTrue);
      }
    });
  });

  group('setAuthWithRefresh', () {
    test(
        'a listener already on the vendored future runs before the caller goes on, '
        'the error reaches the caller unchanged, and the change is counted',
        () async {
      for (final fails in [false, true]) {
        final vendored = _Vendored();
        final client = ConvexClient.over(vendored, _config);
        final order = <String>[];
        final refused = StateError('refused');
        Object? caught;
        unawaited(
          vendored.setting.future.then<void>(
            (_) => order.add('listener'),
            onError: (Object _) => order.add('listener'),
          ),
        );
        final caller = () async {
          try {
            await client.setAuthWithRefresh(fetchToken: () async => 't');
          } catch (error) {
            caught = error;
          }
          order.add('caller');
        }();
        expect(client.authChanges, 1);
        expect(client.authSettled, isFalse);
        if (fails) {
          vendored.setting.completeError(refused);
        } else {
          vendored.setting.complete(_Handle());
        }
        await caller;
        expect(order, ['listener', 'caller'], reason: 'fails: $fails');
        expect(caught, fails ? same(refused) : isNull);
        expect(client.authSettled, isTrue);
      }
    });

    test(
        'disposing the handle is a change that stays unsettled until the '
        'next sign-in call settles', () async {
      final vendored = _Vendored();
      final client = ConvexClient.over(vendored, _config);
      final handle = _Handle();
      final setting = client.setAuthWithRefresh(fetchToken: () async => 't');
      vendored.setting.complete(handle);
      final wrapper = await setting;

      wrapper.dispose();
      expect(handle.disposed, 1);
      expect(client.authChanges, 2);
      expect(client.authSettled, isFalse);
    });
  });
}
