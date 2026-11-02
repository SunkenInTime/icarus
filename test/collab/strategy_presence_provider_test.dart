import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/strategy_presence_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

const _strategyId = 'strategy-1';

class _OpenCloudStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: _strategyId,
        strategyName: null,
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      );
}

/// Counts passes asked for. Null keeps the room off, so no socket opens.
class _Passes extends Fake implements ConvexStrategyRepository {
  final List<String> asked = [];

  @override
  Future<RoomPass?> issueRoomPass(String strategyPublicId) async {
    asked.add(strategyPublicId);
    return null;
  }
}

void main() {
  late _Passes passes;

  ProviderContainer open({ShareLinkView? view}) {
    passes = _Passes();
    final container = ProviderContainer(
      overrides: [
        strategyProvider.overrideWith(_OpenCloudStrategy.new),
        isCloudCollabEnabledProvider.overrideWithValue(true),
        convexStrategyRepositoryProvider.overrideWithValue(passes),
        shareLinkViewProvider.overrideWith((ref) => view),
      ],
    );
    addTearDown(container.dispose);
    container.listen(strategyPresenceProvider, (_, __) {});
    return container;
  }

  test('someone with access asks for a pass', () async {
    open();
    await pumpEventQueue();

    expect(passes.asked, [_strategyId]);
  });

  test('a reader here only through a link asks for nothing', () async {
    final container = open(
      view: (strategyPublicId: _strategyId, token: 'ICR-TOKEN'),
    );
    await pumpEventQueue();

    expect(passes.asked, isEmpty);
    expect(
      container.read(strategyPresenceProvider).connection,
      PresenceConnection.off,
    );
  });

  test('adding the strategy joins the room straight away', () async {
    final container = open(
      view: (strategyPublicId: _strategyId, token: 'ICR-TOKEN'),
    );
    await pumpEventQueue();

    // Redeeming clears the view only after the server has the member row.
    container.read(shareLinkViewProvider.notifier).state = null;
    await pumpEventQueue();

    expect(passes.asked, [_strategyId]);
  });

  test('a link to another strategy keeps nobody out of this room', () async {
    open(view: (strategyPublicId: 'strategy-2', token: 'ICR-TOKEN'));
    await pumpEventQueue();

    expect(passes.asked, [_strategyId]);
  });
}
