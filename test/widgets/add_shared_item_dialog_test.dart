import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/widgets/dialogs/share_links_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  // Adding a strategy link opens the strategy on top of the dialog
  // (MouseNavigation pushes it while the add is still finishing). The dialog
  // used to close with a plain pop, which closed the strategy instead and
  // left the dialog up.
  testWidgets('adding a strategy leaves it open and closes the dialog',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shareLinkControllerProvider.overrideWith(
            () => _OpensStrategyController(navigatorKey),
          ),
        ],
        child: ShadApp(
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAddSharedItemDialog(context),
                child: const Text('Open add dialog'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open add dialog'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AddSharedItemDialog),
        matching: find.byType(EditableText),
      ),
      'ICR-2345-6789-ABCD-EFGH',
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Shared strategy'), findsOneWidget);
    expect(find.byType(AddSharedItemDialog), findsNothing);
  });
}

class _OpensStrategyController extends ShareLinkController {
  _OpensStrategyController(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Future<bool> redeemToken(String token) async {
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Shared strategy')),
      ),
    );
    return true;
  }
}
