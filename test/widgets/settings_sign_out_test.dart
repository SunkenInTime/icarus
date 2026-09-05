import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/services/guarded_sign_out.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('Settings account action uses guarded sign out', (tester) async {
    var requests = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(_SignedInAuth.new),
          guardedSignOutRequestProvider.overrideWithValue((context) async {
            requests += 1;
            return true;
          }),
        ],
        child: const ShadApp(
          home: Scaffold(body: AccountSettingsSection()),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('settings-sign-out')));
    await tester.pump();
    expect(requests, 1);
  });
}

class _SignedInAuth extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: User(
          id: 'account-a',
          appMetadata: <String, dynamic>{},
          userMetadata: <String, dynamic>{'full_name': 'Coach'},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
}
