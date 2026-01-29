import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Only used for strategies imported from Valorant match JSON.
///
/// Null means "not in Valorant match mode".
final valorantRoundProvider =
    NotifierProvider<ValorantRoundProvider, int?>(ValorantRoundProvider.new);

class ValorantRoundProvider extends Notifier<int?> {
  @override
  int? build() => null;

  void setRound(int? roundIndex) {
    state = roundIndex;
  }
}
