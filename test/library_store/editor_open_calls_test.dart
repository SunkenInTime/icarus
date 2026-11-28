import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_copy_scope_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/editor_subscriptions_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import 'cloud_sender_live_test.dart' show LivePageServer, theList;
import 'sender_world.dart';
import 'server_fixtures.dart' show pageId, servedAccount, strategyId;

final class _CountingServer extends LivePageServer {
  _CountingServer(super.world);

  @override
  Future<ConvexValue> query(String name, ConvexObject args) async {
    calls.add('query $name');
    return switch (name) {
      'strategy:getPageList' => wireOf(theList),
      _ => wireOf(args.value['pagePublicId']!.toDart()! as String),
    };
  }

  @override
  Future<Stamped<ConvexValue>> queryStamped(
    String name,
    ConvexObject args,
  ) async {
    calls.add('queryStamped $name');
    final subject = name == 'strategy:getPageList'
        ? theList
        : args.value['pagePublicId']!.toDart()! as String;
    return answerOf(subject);
  }
}

class _SignedIn extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: User(
          id: servedAccount.subject,
          appMetadata: const <String, dynamic>{},
          userMetadata: const <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
}

class _IdleOpQueue extends StrategyOpQueueNotifier {
  @override
  StrategyOpQueueState build() => const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: strategyId,
        clientId: 'calls-client',
        durableLoaded: true,
      );

  @override
  void setActiveStrategy(
    String? strategyPublicId, {
    required String? accountId,
  }) {}
}

class _IdleMediaQueue extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() =>
      const CloudMediaUploadQueueState(jobs: [], isProcessing: false);
}

ProviderContainer _editor(World world, _CountingServer server) {
  final container = ProviderContainer(overrides: [
    cloudStoreSwitchProvider.overrideWithValue(const CloudStoreSend()),
    convexStrategyRepositoryProvider.overrideWithValue(
      ConvexStrategyRepository(IcarusConvexApi(server)),
    ),
    storeRepositoryProvider.overrideWithValue(
      ConvexStrategyRepository.stamped(server),
    ),
    authProvider.overrideWith(_SignedIn.new),
    strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
    cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
    cloudMediaAccountIdProvider.overrideWithValue(null),
    cloudCopyScopeProvider.overrideWithValue(null),
    convexConnectionSnapshotProvider.overrideWithValue(true),
    cloudOfflineProvider.overrideWithValue(false),
  ]);
  container.read(storeLiveResultsProvider).attach(world.sender);
  return container;
}

typedef _Counted = ({List<String> editor, List<String> sender});

int _total(_Counted counted) => counted.editor.length + counted.sender.length;

_Counted _during(World world, _CountingServer server, void Function() act) {
  final editorBefore = server.calls.length;
  final senderBefore =
      world.server.readCalls.length + world.server.calls.length;
  act();
  world.settle(const Duration(seconds: 30));
  return (
    editor: server.calls.skip(editorBefore).toList(),
    sender: [
      for (final call in world.server.readCalls) 'read $call',
      for (final call in world.server.calls) 'send ${call.opIds.join(',')}',
    ].skip(senderBefore).toList(),
  );
}

void main() {
  test(
      'the editor in send mode on today\'s path, as the transport sees it: a '
      'first open is the page list and the shown page watched, a later open '
      'the same two, a page switch one watch, and an edit one send', () {
    inWorld(
      (world) {
        world.secondPageOnServer();
        final server = _CountingServer(world);
        final container = _editor(world, server);
        final remote = container.read(remoteEditorSnapshotProvider.notifier);
        world.settle();

        final first = _during(world, server, () {
          world.openInEditor(strategyId);
          world.sender.adopt(strategyId);
          unawaited(
              remote.openStrategy(strategyId, activePagePublicId: pageId));
        });
        expect(
          container
              .read(remoteEditorSnapshotProvider)
              .valueOrNull
              ?.activePage
              ?.page
              .publicId,
          pageId,
        );
        expect(world.sender.adopting(strategyId), isFalse);

        final later = _during(world, server, () {
          remote.clear();
          world.settle();
          unawaited(
              remote.openStrategy(strategyId, activePagePublicId: pageId));
        });

        final subscriptions = container.read(editorSubscriptionsProvider);
        final switched = _during(world, server, () {
          unawaited(subscriptions
              .readPage(strategyPublicId: strategyId, pagePublicId: 'p2')
              .then((_) => subscriptions
                  .page(strategyPublicId: strategyId, pagePublicId: 'p2')
                  .listen((_) {})));
        });

        final edit = _during(world, server, () => world.commitMove(1));

        printOnFailure('first open: $first\nlater open: $later\n'
            'page switch: $switched\none edit: $edit');
        expect(first.editor, [
          'subscribeStamped strategy:getPageList',
          'subscribeStamped page:getSnapshot',
        ]);
        expect(first.sender, isEmpty);
        expect(_total(later), 2);
        expect(later.sender, isEmpty);
        expect(switched.editor, ['subscribeStamped page:getSnapshot']);
        expect(switched.sender, isEmpty);
        expect(edit.editor, isEmpty);
        expect(edit.sender, ['send move-1']);

        container.dispose();
        world.settle();
      },
      addStrategy: false,
    );
  });
}
