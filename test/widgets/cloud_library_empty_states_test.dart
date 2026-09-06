import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/widgets/dialogs/share_links_dialog.dart';
import 'package:icarus/widgets/folder_content.dart';
import 'package:icarus/widgets/text_editing_shortcut_scope.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    CoordinateSystem(playAreaSize: const Size(1280, 720));
    tempDir = await Directory.systemTemp.createTemp('icarus-library-');
    Hive.init(tempDir.path);
    // My Library lists the local store next to the cloud one, so the widget
    // reads these boxes even in cloud mode.
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  testWidgets('empty library leads to creating a strategy', (tester) async {
    var createCount = 0;
    await tester.pumpWidget(
      _cloudApp(
        FolderContent(onCreateStrategy: () => createCount++),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('library-empty-state')), findsOneWidget);
    expect(find.text('Your library is empty'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-empty-create-strategy')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('library-empty-create-strategy')),
    );
    expect(createCount, 1);
  });

  testWidgets('empty Shared leads to adding a link or code', (tester) async {
    await tester.pumpWidget(
      _cloudApp(
        FolderContent(onCreateStrategy: () {}),
        section: CloudLibrarySection.sharedWithMe,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('shared-empty-state')), findsOneWidget);
    expect(find.text('Nothing shared with you yet'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('shared-empty-add-item')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('shared-empty-add-item')));
    await tester.pumpAndSettle();

    expect(find.byType(AddSharedItemDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AddSharedItemDialog),
        matching: find.byType(TextEditingShortcutScope),
      ),
      findsOneWidget,
    );
  });
}

Widget _cloudApp(
  Widget child, {
  CloudLibrarySection section = CloudLibrarySection.home,
}) {
  return ProviderScope(
    overrides: [
      authProvider.overrideWith(_CloudReadyAuthProvider.new),
      libraryWorkspaceProvider.overrideWith(_CloudWorkspaceNotifier.new),
      cloudLibrarySectionProvider.overrideWith(
        () => _CloudSectionNotifier(section),
      ),
      cloudFolderTreeProvider.overrideWith(
        (_) => Stream.value(const <CloudFolderEntry>[]),
      ),
      cloudStrategiesProvider.overrideWith(
        (_) => Stream.value(const <CloudStrategyEntry>[]),
      ),
    ],
    child: ShadApp(home: Scaffold(body: child)),
  );
}

class _CloudReadyAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: null,
      );
}

class _CloudWorkspaceNotifier extends LibraryWorkspaceNotifier {
  @override
  LibraryWorkspace build() => LibraryWorkspace.cloud;
}

class _CloudSectionNotifier extends CloudLibrarySectionNotifier {
  _CloudSectionNotifier(this._section);

  final CloudLibrarySection _section;

  @override
  CloudLibrarySection build() => _section;
}
