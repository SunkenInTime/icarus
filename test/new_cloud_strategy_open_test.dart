import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/open_attempt.dart';
import 'package:icarus/strategy/open_seen.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

import 'editor_on_screen_support.dart';
import 'library_rows/generated_strategies.dart';
import 'library_store/unit_harness.dart';

final _at = DateTime.utc(2026);

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

final class _CloudSelected extends LibraryWorkspaceNotifier {
  @override
  LibraryWorkspace build() => LibraryWorkspace.cloud;
}

final class _MadeInTheCloud extends StrategyProvider {
  @override
  Future<StrategyData> createNewStrategy({
    required MapValue map,
    String? name,
    bool local = false,
  }) async =>
      generatedStrategy(Optionals.set).copyWith(id: 'made', name: 'made');

  @override
  Future<Directory> setStorageDirectory(String strategyID) async =>
      Directory.systemTemp;
}

final class _ReadsItsHeader extends RemoteEditorSnapshotNotifier {
  @override
  Future<RemoteEditorSnapshot?> build() => SynchronousFuture(null);

  @override
  Future<void> openStrategy(
    String strategyPublicId, {
    String? activePagePublicId,
  }) async {
    state = AsyncData(RemoteEditorSnapshot(
      shell: RemoteStrategyShell(
        header: RemoteStrategyHeader(
          publicId: strategyPublicId,
          name: 'made',
          mapData: Maps.mapNames[MapValue.ascent]!,
          revision: 1,
          createdAt: _at,
          updatedAt: _at,
        ),
        pages: const [],
      ),
      activePage: null,
    ));
  }

  @override
  void clear() => state = const AsyncData(null);
}

final class _PagesUnreadable extends StrategyPageSessionNotifier {
  @override
  Future<void> initializeForStrategy({
    required String strategyId,
    required StrategySource source,
    required bool selectFirstPageIfNeeded,
    String? preferredPageId,
    OpenAttempt? attempt,
  }) async =>
      throw StateError('The pages could not be read.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer(overrides: [
    authProvider.overrideWith(_SignedOut.new),
    libraryWorkspaceProvider.overrideWith(_CloudSelected.new),
    cloudLibraryShowsCopyProvider.overrideWithValue(false),
    strategyProvider.overrideWith(_MadeInTheCloud.new),
    remoteEditorSnapshotProvider.overrideWith(_ReadsItsHeader.new),
    strategyPageSessionProvider.overrideWith(_PagesUnreadable.new),
  ]);
  appProviderContainer = container;
  final strategies = container.read(strategyProvider.notifier);
  setUp(openUnitHive);

  testWidgets(
      'a cloud strategy New Strategy made, whose open fails after it was '
      'published, is closed, so nothing stays open without an editor',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1440);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext library;
    late WidgetRef libraryRef;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: ToastificationWrapper(
        child: ShadApp(
          navigatorKey: appNavigatorKey,
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              library = context;
              libraryRef = ref;
              return const Text('library');
            }),
          ),
        ),
      ),
    ));

    unawaited(pickMapAndOpenNewStrategy(ref: libraryRef, context: library));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find
        .byWidgetPredicate(
            (widget) => '${widget.key}'.contains('create-strategy-map-'))
        .first);
    for (var turn = 0; turn < 10; turn++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(
      find.text('Strategy created, but it could not be opened. Open it from '
          'your cloud library.'),
      findsOneWidget,
    );
    expect(container.read(strategyProvider).strategyId, isNull);
    await tester.pump(const Duration(seconds: 10));
    await closeHive(tester);
  });

  testWidgets(
      'a cloud open that failed after it put its strategy on screen leaves '
      'that strategy alone once another open or a close came since',
      (tester) async {
    final asked = strategies.askedByTheUserNow();
    await tester.runAsync(() => expectLater(
          strategies.openCloud('made', asked: asked),
          throwsStateError,
        ));
    expect(container.read(strategyProvider).strategyId, 'made');
    final now = strategies.askedByTheUserNow();
    expect(strategies.closeStrategy(asked: now), isA<Changed>());

    expect(strategies.closeAfterFailedOpen(asked: asked), isA<GaveWay>());
    await tester.pump(const Duration(seconds: 1));
    await closeHive(tester);
  });
}
