import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

final placementCenterProvider = NotifierProvider<PlacementCenterNotifier, Offset>(
  PlacementCenterNotifier.new,
);

class PlacementCenterNotifier extends Notifier<Offset> {
  @override
  Offset build() => const Offset(500, 500);

  void updateCenter(Offset center) {
    if (state == center) return;
    state = center;
  }
}
