import 'dart:async';

import 'package:icarus/collab/transport/convex_transport.dart';

/// [ConvexTransport.subscribeTogether] for fakes whose [subscribe] streams
/// answer from one state at a time: every value, once each query has one,
/// whenever any of them answers. Answers that arrive in one go (before a
/// microtask runs) go out together, as one server answer does. A query that
/// fails has no value until it answers again.
mixin SubscribeTogetherFromEach implements ConvexTransport {
  @override
  Stream<List<ConvexValue>> subscribeTogether(
    List<(String, ConvexObject)> queries,
  ) {
    late final StreamController<List<ConvexValue>> controller;
    final subscriptions = <StreamSubscription<ConvexValue>>[];
    final values = List<ConvexValue?>.filled(queries.length, null);
    var handOnScheduled = false;

    void handOnSoon() {
      if (handOnScheduled) return;
      handOnScheduled = true;
      scheduleMicrotask(() {
        handOnScheduled = false;
        if (controller.isClosed || values.contains(null)) return;
        controller.add(List.unmodifiable(values));
      });
    }

    controller = StreamController<List<ConvexValue>>(
      onListen: () {
        for (final (index, (name, args)) in queries.indexed) {
          subscriptions.add(subscribe(name, args).listen(
            (value) {
              values[index] = value;
              handOnSoon();
            },
            onError: (Object error, StackTrace stackTrace) {
              values[index] = null;
              controller.addError(error, stackTrace);
            },
          ));
        }
      },
      onCancel: () => Future.wait([
        for (final subscription in subscriptions) subscription.cancel(),
      ]),
    );
    return controller.stream;
  }
}
