import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('confirmation actions expose stable tappable semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      const ShadApp(
        home: Scaffold(
          body: ConfirmAlertDialog(
            title: 'Sign out?',
            content: 'Cloud work stays online.',
            confirmText: 'Sign Out',
          ),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byKey(const ValueKey('confirm-alert-cancel'))),
      matchesSemantics(label: 'Cancel', isButton: true, hasTapAction: true),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('confirm-alert-confirm'))),
      matchesSemantics(label: 'Sign Out', isButton: true, hasTapAction: true),
    );
    semantics.dispose();
  });
}
