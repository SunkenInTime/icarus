import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/account_avatar.dart';

void main() {
  testWidgets('falls back without reporting a UI error when avatar load fails',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AccountAvatar(
          radius: 16,
          backgroundColor: Colors.black,
          avatarUrl: 'https://invalid.invalid/avatar.png',
          fallback: Text('D'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('D'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
