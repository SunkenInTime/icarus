import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('a refresh after a failed page selection resumes its live read',
      () async {
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);
    await remote.openStrategy('strategy', activePagePublicId: 'a');

    // A teammate deletes page a; reading b, where the editor moves, fails.
    repository.failPageReads = true;
    repository.shells.add(_shell(['b']));
    await _settle();
    expect(remote.activePagePublicId, 'b');
    expect(repository.watchedPages, isNot(contains('b')));

    repository.failPageReads = false;
    // Two refreshes at once start one live read, not two.
    await Future.wait([remote.refresh(), remote.refresh()]);
    expect(repository.watchedPages.where((id) => id == 'b'), hasLength(1));
    expect(
      container
          .read(remoteEditorSnapshotProvider)
          .valueOrNull
          ?.activePage
          ?.page
          .revision,
      1,
    );

    // A teammate's later edit to b reaches the editor.
    repository.pageStreams['b']!.add(_page('b', revision: 2));
    await _settle();
    expect(
      container
          .read(remoteEditorSnapshotProvider)
          .valueOrNull
          ?.activePage
          ?.page
          .revision,
      2,
    );
  });

  test('a signed-out reader on a share link reads through the link', () async {
    final repository = _Repository();
    final auth = _SignedOutAuthProvider();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(() => auth),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    container.read(shareLinkViewProvider.notifier).state =
        (strategyPublicId: 'strategy', token: 'ICR-LINK');
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);

    await remote.openStrategy('strategy');
    expect(repository.readTokens, isNotEmpty);
    expect(repository.readTokens, everyElement('ICR-LINK'));

    // A refusal is the link's, not a broken session: there is no session,
    // so no auth incident opens, and the editor sees the error itself.
    repository.shellError = const ConvexFunctionException(
      code: ConvexErrorCode.unauthenticated,
      rawCode: 'UNAUTHENTICATED',
      message: 'Unauthenticated',
    );
    await remote.refresh();
    expect(auth.unauthenticatedReports, 0);
    expect(container.read(remoteEditorSnapshotProvider).hasError, isTrue);

    repository.shellError = const ConvexFunctionException(
      code: ConvexErrorCode.shareLinkRevoked,
      rawCode: 'SHARE_LINK_REVOKED',
      message: 'Share link revoked',
    );
    await remote.refresh();
    expect(auth.unauthenticatedReports, 0);
    expect(
      isShareLinkRevokedError(
        container.read(remoteEditorSnapshotProvider).error!,
      ),
      isTrue,
    );

    // A strategy opened any other way reads with the reader's own access.
    repository.shellError = null;
    repository.readTokens.clear();
    await remote.openStrategy('another-strategy');
    expect(repository.readTokens, everyElement(isNull));
  });
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

RemotePage _remotePage(String id, {int revision = 1}) => RemotePage(
      publicId: id,
      strategyPublicId: 'strategy',
      name: id,
      sortIndex: 0,
      isAttack: true,
      revision: revision,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

RemoteStrategyShell _shell(List<String> pageIds) => RemoteStrategyShell(
      header: RemoteStrategyHeader(
        publicId: 'strategy',
        name: 'Strategy',
        mapData: 'ascent',
        revision: 1,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        role: 'owner',
      ),
      pages: [for (final id in pageIds) _remotePage(id)],
    );

RemotePageSnapshot _page(String id, {int revision = 1}) => RemotePageSnapshot(
      page: _remotePage(id, revision: revision),
      content: RemotePageContent(
        revision: 1,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
      elements: const [],
      lineups: const [],
      assetsById: const {},
    );

class _Repository extends ConvexStrategyRepository {
  _Repository() : super(IcarusConvexApi(_UnusedTransport()));

  final shells = StreamController<RemoteStrategyShell>.broadcast();
  final pageStreams = <String, StreamController<RemotePageSnapshot>>{};
  final watchedPages = <String>[];

  /// The share token each read carried, in order.
  final readTokens = <String?>[];
  bool failPageReads = false;
  Object? shellError;

  @override
  Future<RemoteStrategyShell> fetchShell(
    String strategyPublicId, {
    String? shareToken,
  }) async {
    readTokens.add(shareToken);
    if (shellError case final error?) throw error;
    return _shell(failPageReads ? ['b'] : ['a', 'b']);
  }

  @override
  Stream<RemoteStrategyShell> watchShell(
    String strategyPublicId, {
    String? shareToken,
  }) {
    readTokens.add(shareToken);
    return shells.stream;
  }

  @override
  Future<RemotePageSnapshot> fetchPageSnapshot({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) async {
    readTokens.add(shareToken);
    if (failPageReads) throw StateError('offline');
    return _page(pagePublicId);
  }

  @override
  Stream<RemotePageSnapshot> watchPageSnapshot({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) {
    readTokens.add(shareToken);
    watchedPages.add(pagePublicId);
    return (pageStreams[pagePublicId] ??=
            StreamController<RemotePageSnapshot>.broadcast())
        .stream;
  }
}

class _ReadyAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: User(
          id: 'account-a',
          appMetadata: const <String, dynamic>{},
          userMetadata: const <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
}

class _SignedOutAuthProvider extends AuthProvider {
  int unauthenticatedReports = 0;

  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.signedOut,
        user: null,
      );

  @override
  Future<void> reportConvexUnauthenticated({
    required String source,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    unauthenticatedReports += 1;
  }
}

class _IdleOpQueue extends StrategyOpQueueNotifier {
  @override
  StrategyOpQueueState build() => const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'strategy',
        clientId: 'client',
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

class _UnusedTransport implements ConvexTransport {
  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Future<ConvexValue> query(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) =>
      throw UnimplementedError();
}
