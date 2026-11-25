import 'dart:async';

import 'package:icarus/collab/src/convex_client_types.dart';
import 'package:icarus/collab/transport/convex_transport.dart';

abstract base class NormalizedConvexTransport implements ConvexTransport {
  const NormalizedConvexTransport(this.client);

  final ConvexClientValueSource client;

  @override
  Future<ConvexValue> query(String name, ConvexObject args) => _invoke(
        '$name.returns',
        () => client.queryValue(name, args.toDart()),
      );

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) => _invoke(
        '$name.returns',
        () => client.mutationValue(name: name, args: args.toDart()),
      );

  @override
  Future<ConvexValue> action(String name, ConvexObject args) => _invoke(
        '$name.returns',
        () => client.actionValue(name: name, args: args.toDart()),
      );

  Future<ConvexValue> _invoke(
    String path,
    Future<Object?> Function() operation,
  ) async {
    try {
      return _normalize(await operation(), path);
    } on ConvexClientFunctionError catch (error) {
      throw _transportError(error);
    }
  }

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) =>
      _watch<ConvexValue>(
        (onUpdate, onError) => client.subscribeValue(
          name: name,
          args: args.toDart(),
          onUpdate: onUpdate,
          onError: onError,
        ),
        (value) => _normalize(value, '$name.returns'),
      );

  @override
  Stream<List<ConvexValue>> subscribeTogether(
    List<(String name, ConvexObject args)> queries,
  ) =>
      _watch<List<ConvexValue>>(
        (onUpdate, onError) => client.subscribeValues(
          queries: [
            for (final (name, args) in queries)
              (name: name, args: args.toDart()),
          ],
          onUpdate: onUpdate,
          onError: onError,
        ),
        (values) => [
          for (final (index, value) in (values! as List<Object?>).indexed)
            _normalize(value, '${queries[index].$1}.returns'),
        ],
      );

  /// A stream of what [subscribe] delivers, each value through [normalize].
  /// A value that can't be normalized ends the stream with that error.
  Stream<T> _watch<T>(
    Future<SubscriptionHandle> Function(
      void Function(Object? value) onUpdate,
      void Function(ConvexClientFunctionError error) onError,
    ) subscribe,
    T Function(Object? value) normalize,
  ) {
    late final StreamController<T> controller;
    SubscriptionHandle? handle;
    var active = false;

    Future<void> closeForContractFailure(
        Object error, StackTrace stackTrace) async {
      if (!active) return;
      active = false;
      controller.addError(error, stackTrace);
      handle?.cancel();
      handle = null;
      await controller.close();
    }

    Future<void> start() async {
      active = true;
      try {
        final nextHandle = await subscribe(
          (value) {
            if (!active) return;
            try {
              controller.add(normalize(value));
            } catch (error, stackTrace) {
              closeForContractFailure(error, stackTrace);
            }
          },
          (error) {
            if (!active) return;
            controller.addError(_transportError(error));
          },
        );
        if (!active) {
          nextHandle.cancel();
          return;
        }
        handle = nextHandle;
      } catch (error, stackTrace) {
        await closeForContractFailure(error, stackTrace);
      }
    }

    controller = StreamController<T>(
      onListen: start,
      onCancel: () {
        active = false;
        handle?.cancel();
        handle = null;
      },
    );
    return controller.stream;
  }

  ConvexValue _normalize(Object? value, String path) {
    try {
      return ConvexValue.fromDart(value);
    } catch (error) {
      throw ConvexNormalizationError(path, error);
    }
  }

  ConvexTransportError _transportError(ConvexClientFunctionError error) {
    ConvexValue? data;
    if (error.data != null) {
      try {
        data = ConvexValue.fromDart(error.data);
      } catch (_) {
        data = ConvexString(error.data.toString());
      }
    }
    return ConvexTransportError(
      rawCode: error.rawCode,
      message: error.message,
      data: data,
    );
  }
}

abstract base class StampedNormalizedTransport extends NormalizedConvexTransport
    implements StampedConvexTransport {
  const StampedNormalizedTransport(this.stamped) : super(stamped);

  final StampedValueSource stamped;

  @override
  Future<Stamped<ConvexValue>> queryStamped(
    String name,
    ConvexObject args,
  ) async =>
      _stampedOf(
        '$name.returns',
        await stamped.queryStamped(name, args.toDart()),
        (value, path) => _normalize(value, path),
      );

  @override
  Future<Stamped<ConvexValue>> mutationStamped(
    String name,
    ConvexObject args,
  ) async =>
      _stampedOf(
        '$name.returns',
        await stamped.mutationStamped(name: name, args: args.toDart()),
        (value, path) => _normalize(value, path),
      );

  @override
  Stream<Stamped<ConvexValue>> subscribeStamped(
    String name,
    ConvexObject args,
  ) =>
      _watchStamped<Object?, ConvexValue>(
        (onResult, onBroken) => stamped.subscribeStamped(
          name: name,
          args: args.toDart(),
          onResult: onResult,
          onBroken: onBroken,
        ),
        (outcome) => _stampedOf(
          '$name.returns',
          outcome,
          (value, path) => _normalize(value, path),
        ),
      );

  @override
  Stream<Stamped<List<ConvexValue>>> subscribeTogetherStamped(
    List<(String name, ConvexObject args)> queries,
  ) =>
      _watchStamped<List<Object?>, List<ConvexValue>>(
        (onResult, onBroken) => stamped.subscribeValuesStamped(
          queries: [
            for (final (name, args) in queries)
              (name: name, args: args.toDart()),
          ],
          onResult: onResult,
          onBroken: onBroken,
        ),
        (outcome) => _stampedOf(
          '',
          outcome,
          (values, _) => [
            for (final (index, value) in values.indexed)
              _normalize(value, '${queries[index].$1}.returns'),
          ],
        ),
      );

  @override
  Future<({int client, int connection})> generation() => stamped.generation();

  Stamped<T> _stampedOf<V, T>(
    String path,
    StampedOutcome<V> outcome,
    T Function(V value, String path) normalize,
  ) =>
      switch (outcome) {
        StampedAnswer(:final value, :final stamp) =>
          StampedValue(normalize(value, path), stamp),
        StampedFunctionError(:final error, :final stamp) =>
          StampedError(_transportError(error), stamp),
      };

  Stream<Stamped<T>> _watchStamped<V, T>(
    Future<SubscriptionHandle> Function(
      void Function(StampedOutcome<V> outcome) onResult,
      void Function(Object error, StackTrace stackTrace) onBroken,
    ) subscribe,
    Stamped<T> Function(StampedOutcome<V> outcome) normalize,
  ) {
    late final StreamController<Stamped<T>> controller;
    SubscriptionHandle? handle;
    var active = false;

    Future<void> closeForContractFailure(
        Object error, StackTrace stackTrace) async {
      if (!active) return;
      active = false;
      controller.addError(error, stackTrace);
      handle?.cancel();
      handle = null;
      await controller.close();
    }

    Future<void> start() async {
      active = true;
      try {
        final nextHandle = await subscribe(
          (outcome) {
            if (!active) return;
            try {
              controller.add(normalize(outcome));
            } catch (error, stackTrace) {
              closeForContractFailure(error, stackTrace);
            }
          },
          closeForContractFailure,
        );
        if (!active) {
          nextHandle.cancel();
          return;
        }
        handle = nextHandle;
      } catch (error, stackTrace) {
        await closeForContractFailure(error, stackTrace);
      }
    }

    controller = StreamController<Stamped<T>>(
      onListen: start,
      onCancel: () {
        active = false;
        handle?.cancel();
        handle = null;
      },
    );
    return controller.stream;
  }
}
