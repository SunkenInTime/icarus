import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/replay_library_provider.dart';
import 'package:icarus/replay/replay_files.dart';
import 'package:icarus/widgets/replay/replay_library_content.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  /// Right-clicks a replay kept in Icarus and returns the menu's labels.
  Future<void> openMenu(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: ShadApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 300,
                child: ReplayTile(
                  listing: ReplayListing(
                    file: ReplayFile(
                      path: 'kept.vrf',
                      source: ReplaySource.icarus,
                      sizeBytes: 1,
                      modified: DateTime(2026, 7, 1),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(ReplayTile), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
  }

  testWidgets('a kept replay offers Remove on Windows', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await openMenu(tester);
      expect(find.text('Remove from Icarus'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('without a Recycle Bin there is no Remove', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await openMenu(tester);
      expect(find.text('Remove from Icarus'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
