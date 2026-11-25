@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/collab/transport/convex_transport_adapter.dart';

import 'load_convex_bundle.dart';

const _deploymentUrl = String.fromEnvironment('CONVEX_URL');
const _accessToken = String.fromEnvironment('GAUNTLET_ACCESS_TOKEN');
const _bundleUrl = String.fromEnvironment('CONVEX_BUNDLE_URL');
const _protocol = 6.0;
const _patience = Duration(seconds: 30);

const _controlledSocket = r'''
(() => {
  const Real = globalThis.WebSocket;
  const control = { sockets: [], hold: false, held: [], dropOwned: false, owned: new Set() };
  globalThis.icarusSocketControl = control;
  control.release = () => {
    control.hold = false;
    const held = control.held;
    control.held = [];
    held.forEach((deliver) => deliver());
  };
  control.closeAll = () => control.sockets.forEach((socket) => socket.inner.close());
  class ControlledSocket {
    constructor(url, protocols) {
      this.inner = new Real(url, protocols);
      this.onopen = null;
      this.onclose = null;
      this.onerror = null;
      this.onmessage = null;
      this.inner.onopen = (event) => this.onopen && this.onopen(event);
      this.inner.onclose = (event) => this.onclose && this.onclose(event);
      this.inner.onerror = (event) => this.onerror && this.onerror(event);
      this.inner.onmessage = (event) => {
        let data = event.data;
        const message = JSON.parse(data);
        if (control.dropOwned && message.type === 'Transition') {
          message.modifications = message.modifications.filter(
            (change) => !control.owned.has(change.queryId),
          );
          data = JSON.stringify(message);
        }
        const deliver = () => this.onmessage && this.onmessage({ data });
        if (control.hold) control.held.push(deliver);
        else deliver();
      };
      control.sockets.push(this);
    }
    get readyState() { return this.inner.readyState; }
    send(data) {
      const message = JSON.parse(data);
      if (message.type === 'ModifyQuerySet') {
        for (const change of message.modifications) {
          if (change.type === 'Add' && JSON.stringify(change.args).includes('"owned"')) {
            control.owned.add(change.queryId);
          }
        }
      }
      this.inner.send(data);
    }
    close(code, reason) { this.inner.close(code, reason); }
  }
  ControlledSocket.CONNECTING = 0;
  ControlledSocket.OPEN = 1;
  ControlledSocket.CLOSING = 2;
  ControlledSocket.CLOSED = 3;
  globalThis.WebSocket = ControlledSocket;
})();
''';

JSObject get _control => globalContext['icarusSocketControl']! as JSObject;

void _installControlledSocket() {
  final document = globalContext['document']! as JSObject;
  final script =
      document.callMethod<JSObject>('createElement'.toJS, 'script'.toJS);
  script['text'] = _controlledSocket.toJS;
  (document['head']! as JSObject)
      .callMethod<JSAny?>('appendChild'.toJS, script);
}

Future<T> _within<T>(Future<T> future, String what) =>
    future.timeout(_patience, onTimeout: () => fail('$what within $_patience'));

Future<void> _until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(_patience);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('$what within $_patience');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

List<String> _names(Object? tree) => [
      for (final folder in tree! as List<FoldersListTreeResultItem>)
        folder.name,
    ];

void main() {
  test(
    'across a reconnect, a held answer keeps its connection and a group '
    'waits for every member on the new one',
    () async {
      final subscriptions = <StreamSubscription<Object?>>[];
      addTearDown(() async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      });
      _installControlledSocket();
      await loadConvexBundle(_bundleUrl);
      await ConvexClient.initialize(
        const ConvexConfig(
          deploymentUrl: _deploymentUrl,
          clientId: 'icarus-stamped-transport-reconnect',
          operationTimeout: _patience,
        ),
      );
      await ConvexClient.instance
          .setAuthWithRefresh(fetchToken: () async => _accessToken);
      final transport = StampedPlatformTransport(ConvexClient.instance);
      final api = IcarusConvexApi(transport);
      await api.users.ensureCurrentUser(clientProtocolVersion: _protocol);
      final all = api.folders.listTree(
        scope: const ConvexOptional.present(FoldersListTreeArgsScope.all),
      );
      final owned = api.folders.listTree(
        scope: const ConvexOptional.present(FoldersListTreeArgsScope.owned),
      );

      final held = <Stamped<List<FoldersListTreeResultItem>>>[];
      subscriptions.add(all.stampedOn(transport).watch().listen(held.add));
      final grouped = <Stamped<List<Object?>>>[];
      subscriptions.add(
        StampedConvexQuery.watchTogether(transport, [all, owned])
            .listen(grouped.add),
      );
      await _until(() => held.isNotEmpty && grouped.isNotEmpty, 'no answer');
      final before = await transport.connectionGeneration();
      expect(held.last.stamp.connection, before);
      expect(grouped.last.stamp.connection, before);

      _control['hold'] = true.toJS;
      _control['dropOwned'] = true.toJS;
      _control.callMethod<JSAny?>('closeAll'.toJS);
      await _until(
        () {
          unawaited(transport.connectionGeneration().then((now) => _now = now));
          return _now > before;
        },
        'the socket did not open again',
      );

      final cached =
          await _within(all.stampedOn(transport).fetch(), 'no cached answer');
      expect(cached.stamp.connection, before,
          reason: 'a value held from the old connection keeps its number');
      final secondListener = Completer<Stamped<Object?>>();
      subscriptions.add(owned.stampedOn(transport).watch().listen((answer) {
        if (!secondListener.isCompleted) secondListener.complete(answer);
      }));
      final cachedWatch =
          await _within(secondListener.future, 'no cached watch answer');
      expect(cachedWatch.stamp.connection, before);

      final groupedBeforeRelease = grouped.length;
      _control.callMethod<JSAny?>('release'.toJS);
      await _until(
        () => held.any((answer) => answer.stamp.connection > before),
        'the held query was not answered on the new connection',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(
        grouped.skip(groupedBeforeRelease),
        isEmpty,
        reason: 'only one member answered on the new connection, so the '
            'group waits',
      );

      _control['dropOwned'] = false.toJS;
      final name = 'Reconnect ${DateTime.now().microsecondsSinceEpoch}';
      await api.folders.create(
        clientProtocolVersion: _protocol,
        name: name,
        publicId: 'reconnect-${DateTime.now().microsecondsSinceEpoch}',
      );
      await _until(
        () => grouped.skip(groupedBeforeRelease).isNotEmpty,
        'the group was not handed on once both members answered',
      );
      final after = grouped.skip(groupedBeforeRelease).first;
      expect(after.stamp.connection, greaterThan(before));
      final values = (after as StampedValue<List<Object?>>).value;
      expect(_names(values[0]), contains(name));
      expect(_names(values[1]), contains(name));
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: _deploymentUrl.isEmpty
        ? 'Run through tool/convex_client_gauntlet/runtime/tool/'
            'run_with_local_deployment.mjs'
        : false,
  );
}

int _now = -1;
