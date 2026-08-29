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
  Stream<ConvexValue> subscribe(String name, ConvexObject args) {
    late final StreamController<ConvexValue> controller;
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
        final nextHandle = await client.subscribeValue(
          name: name,
          args: args.toDart(),
          onUpdate: (value) {
            if (!active) return;
            try {
              controller.add(_normalize(value, '$name.returns'));
            } catch (error, stackTrace) {
              closeForContractFailure(error, stackTrace);
            }
          },
          onError: (error) {
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

    controller = StreamController<ConvexValue>(
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
