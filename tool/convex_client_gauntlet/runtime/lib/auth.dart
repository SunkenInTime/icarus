import 'dart:convert';

import 'package:supabase/supabase.dart';

/// Where the runner gets its disposable account's access tokens.
abstract interface class GauntletAuth {
  /// Signs in and returns the first access token.
  Future<String> signIn();

  /// Returns a fresh access token for the same account.
  Future<String> refresh();

  /// The account's identity subject (the JWT `sub`), once signed in.
  String get accountSubject;

  Future<void> close();
}

/// Picks the account from the run's settings: a pair of tokens minted by
/// `tool/run_with_local_deployment.mjs` when it set them, otherwise a real
/// Supabase test user.
GauntletAuth gauntletAuthFromSettings(String Function(String name) setting) {
  final accessToken = setting('GAUNTLET_ACCESS_TOKEN');
  if (accessToken.isNotEmpty) {
    final refreshedAccessToken = setting('GAUNTLET_REFRESHED_ACCESS_TOKEN');
    if (refreshedAccessToken.isEmpty) {
      throw StateError('GAUNTLET_REFRESHED_ACCESS_TOKEN is missing');
    }
    return MintedGauntletAuth(
      accessToken: accessToken,
      refreshedAccessToken: refreshedAccessToken,
    );
  }
  final settings = [
    setting('SUPABASE_URL'),
    setting('SUPABASE_KEY'),
    setting('TEST_EMAIL'),
    setting('TEST_PASSWORD'),
  ];
  if (settings.any((value) => value.isEmpty)) {
    throw StateError(
      'Set GAUNTLET_ACCESS_TOKEN, or SUPABASE_URL, SUPABASE_KEY, TEST_EMAIL '
      'and TEST_PASSWORD',
    );
  }
  return SupabaseGauntletAuth(
    supabaseUrl: settings[0],
    supabaseKey: settings[1],
    email: settings[2],
    password: settings[3],
  );
}

/// A real Supabase test user, signed in with the public anon key.
final class SupabaseGauntletAuth implements GauntletAuth {
  SupabaseGauntletAuth({
    required String supabaseUrl,
    required String supabaseKey,
    required this.email,
    required this.password,
  }) : _supabase = SupabaseClient(
         supabaseUrl,
         supabaseKey,
         authOptions: const AuthClientOptions(
           authFlowType: AuthFlowType.implicit,
           autoRefreshToken: false,
         ),
       );

  final SupabaseClient _supabase;
  final String email;
  final String password;
  String? _accountSubject;

  @override
  String get accountSubject =>
      _accountSubject ?? (throw StateError('Not signed in'));

  @override
  Future<String> signIn() async {
    final signIn = await _supabase.auth.signInWithPassword(
      email: email,
      password: password,
    );
    final session =
        signIn.session ??
        (throw StateError('Disposable account sign-in failed'));
    _accountSubject = session.user.id;
    return session.accessToken;
  }

  @override
  Future<String> refresh() async {
    final refreshed = await _supabase.auth.refreshSession();
    final session = refreshed.session;
    if (session == null) {
      throw StateError('refreshSession returned no session');
    }
    return session.accessToken;
  }

  @override
  Future<void> close() => _supabase.dispose();
}

/// Two tokens for one account, signed by a throwaway issuer that only a
/// local deployment made by `tool/run_with_local_deployment.mjs` trusts.
final class MintedGauntletAuth implements GauntletAuth {
  MintedGauntletAuth({
    required this.accessToken,
    required this.refreshedAccessToken,
  });

  final String accessToken;
  final String refreshedAccessToken;

  @override
  String get accountSubject {
    final claims = accessToken.split('.')[1];
    final json = utf8.decode(base64Url.decode(base64Url.normalize(claims)));
    return (jsonDecode(json) as Map<String, Object?>)['sub'] as String;
  }

  @override
  Future<String> signIn() async => accessToken;

  @override
  Future<String> refresh() async => refreshedAccessToken;

  @override
  Future<void> close() async {}
}
