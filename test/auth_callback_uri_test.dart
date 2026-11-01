import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:icarus/services/auth_callback_uri.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('authLinkNoticeFor', () {
    final codeLink = Uri.parse('https://beta.icarusstrats.com/?code=abc');

    test('a code proves the email was confirmed when it cannot finish here',
        () async {
      // The real client, so an upgrade that rewords this is caught here.
      final noVerifier = await GoTrueClient(
        url: 'http://localhost:1',
        asyncStorage: _EmptyStorage(),
        flowType: AuthFlowType.pkce,
      ).getSessionFromUrl(codeLink).then<Object>(
            (_) => fail('Expected the exchange to fail'),
            onError: (Object error) => error,
          );
      for (final error in [
        noVerifier,
        const AuthApiException(
          'invalid flow state, flow state has expired',
          statusCode: '400',
          code: 'flow_state_expired',
        ),
      ]) {
        expect(
          authLinkNoticeFor(codeLink, error, resetPending: false),
          AuthLinkNotice.emailConfirmed,
          reason: '$error',
        );
      }
    });

    test('a reset that timed out where it was asked for says so', () {
      const expired = AuthApiException(
        'invalid flow state, flow state has expired',
        statusCode: '422',
        code: 'flow_state_expired',
      );
      expect(
        authLinkNoticeFor(codeLink, expired, resetPending: true),
        AuthLinkNotice.resetLinkTimedOut,
      );
    });

    test('the verifier GoTrue saves for a reset is recognised', () async {
      // The real client, so an upgrade that changes the format is caught here.
      final storage = _EmptyStorage();
      await GoTrueClient(
        url: 'http://localhost:1',
        asyncStorage: storage,
        flowType: AuthFlowType.pkce,
        httpClient: MockClient((_) async => Response('{}', 200)),
      ).resetPasswordForEmail('a@b.co');
      expect(
        storage.saved.keys,
        [pkceVerifierStorageKey],
      );
      expect(isPasswordResetVerifier(storage.saved.values.single), isTrue);

      expect(isPasswordResetVerifier('plain-verifier'), isFalse);
      expect(isPasswordResetVerifier(null), isFalse);
    });

    test('an expired or used link never says confirmed', () {
      // What Supabase sent an old link back with, both halves of it.
      const expired = AuthException(
        'Email link is invalid or has expired',
        statusCode: 'otp_expired',
        code: 'access_denied',
      );
      for (final link in [
        'https://beta.icarusstrats.com/?error=access_denied'
            '&error_code=otp_expired'
            '&error_description=Email+link+is+invalid+or+has+expired'
            '#error=access_denied&error_code=otp_expired'
            '&error_description=Email+link+is+invalid+or+has+expired&sb=',
        'https://beta.icarusstrats.com/#error=access_denied'
            '&error_code=otp_expired',
      ]) {
        expect(
          authLinkNoticeFor(Uri.parse(link), expired, resetPending: false),
          AuthLinkNotice.linkExpired,
          reason: link,
        );
      }
      expect(AuthLinkNotice.linkExpired.message, isNot(contains('confirmed.')));
    });

    test('anything else is a real failure', () {
      for (final (link, error) in <(String, Object)>[
        // The email was confirmed, but the exchange never got an answer.
        (
          'https://beta.icarusstrats.com/?code=abc',
          AuthRetryableFetchException(statusCode: '503'),
        ),
        ('https://beta.icarusstrats.com/?code=abc', Exception('offline')),
        // A second Discord tab replaced the verifier: no email involved.
        (
          'https://beta.icarusstrats.com/?code=abc',
          const AuthApiException(
            'code challenge does not match',
            statusCode: '400',
            code: 'bad_code_verifier',
          ),
        ),
        (
          'https://beta.icarusstrats.com/?code=spent',
          const AuthApiException(
            'invalid flow state, no valid flow state found',
            statusCode: '404',
            code: 'flow_state_not_found',
          ),
        ),
        (
          'https://beta.icarusstrats.com/?error=server_error'
              '&error_description=Something+broke',
          const AuthException('Something broke', code: 'server_error'),
        ),
      ]) {
        expect(
          authLinkNoticeFor(Uri.parse(link), error, resetPending: false),
          isNull,
          reason: link,
        );
      }
    });
  });

  group('webAuthRedirectUri', () {
    test('is the root of the page origin, whatever page is open', () {
      expect(
        webAuthRedirectUri(
          Uri.parse('https://beta.icarusstrats.com/share/ICR-2345?x=1#/'),
        ).toString(),
        'https://beta.icarusstrats.com/',
      );
      expect(
        webAuthRedirectUri(Uri.parse('https://icarus-web-a50.pages.dev/'))
            .toString(),
        'https://icarus-web-a50.pages.dev/',
      );
      expect(
        webAuthRedirectUri(Uri.parse('http://localhost:5000/#/')).toString(),
        'http://localhost:5000/',
      );
    });
  });

  group('classifyAuthCallbackUri', () {
    final webRedirect = webAuthRedirectUri(
      Uri.parse('https://beta.icarusstrats.com/'),
    );

    AuthCallback web(String link) =>
        classifyAuthCallbackUri(Uri.parse(link), redirectUri: webRedirect);
    AuthCallback native(String link) => classifyAuthCallbackUri(
          Uri.parse(link),
          redirectUri: nativeAuthRedirectUri,
        );

    test('a PKCE code or an error is a sign-in result', () {
      for (final link in [
        'https://beta.icarusstrats.com/?code=abc',
        'https://beta.icarusstrats.com?code=abc',
        'https://beta.icarusstrats.com/?code=abc#/',
        'https://beta.icarusstrats.com/?error=server_error'
            '&error_description=Something+broke',
        'https://beta.icarusstrats.com/#error=access_denied'
            '&error_description=Denied',
      ]) {
        expect(web(link), AuthCallback.signInResult, reason: link);
      }
      for (final link in [
        'icarus://auth/callback?code=abc',
        'icarus://auth/callback?error=access_denied&error_description=Denied',
      ]) {
        expect(native(link), AuthCallback.signInResult, reason: link);
      }
    });

    test('session tokens are rejected on web and native, even beside a code',
        () {
      for (final link in [
        'https://beta.icarusstrats.com/#access_token=a&refresh_token=b'
            '&expires_in=3600&token_type=bearer',
        'https://beta.icarusstrats.com/?access_token=a&refresh_token=b',
        'https://beta.icarusstrats.com/?code=abc#access_token=a',
        'https://beta.icarusstrats.com/#provider_token=a',
      ]) {
        expect(web(link), AuthCallback.injectedTokens, reason: link);
      }
      expect(
        native('icarus://auth/callback#access_token=a&refresh_token=b'),
        AuthCallback.injectedTokens,
      );
    });

    test('token names are matched in any case', () {
      for (final link in [
        'https://beta.icarusstrats.com/?code=c&ACCESS_TOKEN=secret',
        'https://beta.icarusstrats.com/?Refresh_Token=secret',
        'https://beta.icarusstrats.com/#Access_Token=secret&token_type=bearer',
        'https://beta.icarusstrats.com/?code=c#PROVIDER_TOKEN=secret',
      ]) {
        expect(web(link), AuthCallback.injectedTokens, reason: link);
      }
      expect(
        native('icarus://auth/callback?code=c#Refresh_Token=secret'),
        AuthCallback.injectedTokens,
      );
    });

    test('undecodable escapes fail closed', () {
      expect(
        web('https://beta.icarusstrats.com/#access_token=%E0%A4%A'),
        AuthCallback.injectedTokens,
      );
      expect(
        web('https://beta.icarusstrats.com/?code=%E0%A4%A'),
        AuthCallback.injectedTokens,
      );
    });

    test('the web origin without a sign-in result is not a callback', () {
      expect(web('https://beta.icarusstrats.com/'), AuthCallback.none);
      expect(web('https://beta.icarusstrats.com/#/'), AuthCallback.none);
    });

    test('a share link that carries ?code= is not a callback', () {
      expect(
        web('https://beta.icarusstrats.com/share?code=ICR-2345-6789-ABCD-EFGH'),
        AuthCallback.none,
      );
    });

    test('anything aimed at a different origin is not a callback', () {
      for (final link in [
        'https://icarusstrats.com/?code=abc',
        'https://other.icarus-web-a50.pages.dev/?code=abc',
        'http://beta.icarusstrats.com/?code=abc',
        'https://beta.icarusstrats.com:8443/?code=abc',
        'https://icarusstrats.com/#access_token=a',
        'icarus://auth/callback?code=abc',
      ]) {
        expect(web(link), AuthCallback.none, reason: link);
      }
      expect(
        native('https://beta.icarusstrats.com/?code=abc'),
        AuthCallback.none,
        reason: 'native builds only accept their own deep link',
      );
    });
  });

  group('withoutAuthCallbackParameters', () {
    test('strips the PKCE code and keeps the page', () {
      expect(
        withoutAuthCallbackParameters(
          Uri.parse('https://beta.icarusstrats.com/?code=abc'),
        ).toString(),
        'https://beta.icarusstrats.com/',
      );
    });

    test('keeps unrelated query parameters and the Flutter route fragment', () {
      expect(
        withoutAuthCallbackParameters(
          Uri.parse('https://beta.icarusstrats.com/?code=abc&utm=discord#/'),
        ).toString(),
        'https://beta.icarusstrats.com/?utm=discord#/',
      );
    });

    test('strips errors and implicit-flow tokens from the fragment', () {
      expect(
        withoutAuthCallbackParameters(
          Uri.parse(
            'https://beta.icarusstrats.com/?error=access_denied'
            '&error_code=403&error_description=Denied'
            '#access_token=a&refresh_token=b&expires_in=3600&token_type=bearer',
          ),
        ).toString(),
        'https://beta.icarusstrats.com/',
      );
    });

    test('scrubs an injected token link, even an undecodable one', () {
      expect(
        withoutAuthCallbackParameters(
          Uri.parse(
            'https://beta.icarusstrats.com/#access_token=attacker'
            '&refresh_token=attacker&expires_in=3600&token_type=bearer',
          ),
        ).toString(),
        'https://beta.icarusstrats.com/',
      );
      expect(
        withoutAuthCallbackParameters(
          Uri.parse(
            'https://beta.icarusstrats.com/?access_token=%E0%A4%A'
            '#refresh_token=%E0%A4%A',
          ),
        ).toString(),
        'https://beta.icarusstrats.com/',
      );
    });

    test('scrubs sign-in parameters whatever their case', () {
      expect(
        withoutAuthCallbackParameters(
          Uri.parse(
            'https://beta.icarusstrats.com/?code=c&ACCESS_TOKEN=secret'
            '&utm=discord#Refresh_Token=secret&Token_Type=bearer',
          ),
        ).toString(),
        'https://beta.icarusstrats.com/?utm=discord',
      );
    });

    test('keeps a non-default port', () {
      expect(
        withoutAuthCallbackParameters(
          Uri.parse('http://localhost:5000/?code=abc'),
        ).toString(),
        'http://localhost:5000/',
      );
    });
  });
}

class _EmptyStorage implements GotrueAsyncStorage {
  final saved = <String, String>{};

  @override
  Future<String?> getItem({required String key}) async => saved[key];

  @override
  Future<void> removeItem({required String key}) async {
    saved.remove(key);
  }

  @override
  Future<void> setItem({required String key, required String value}) async {
    saved[key] = value;
  }
}
