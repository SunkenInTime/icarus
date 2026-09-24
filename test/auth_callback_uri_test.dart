import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/auth_callback_uri.dart';

void main() {
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

  group('isAuthCallbackUri', () {
    final webRedirect = webAuthRedirectUri(
      Uri.parse('https://beta.icarusstrats.com/'),
    );

    test('accepts the native deep link with a sign-in result', () {
      for (final link in [
        'icarus://auth/callback?code=abc',
        'icarus://auth/callback#access_token=abc&refresh_token=def',
        'icarus://auth/callback?error=access_denied&error_description=Denied',
      ]) {
        expect(
          isAuthCallbackUri(
            Uri.parse(link),
            redirectUri: nativeAuthRedirectUri,
          ),
          isTrue,
          reason: link,
        );
      }
    });

    test('accepts Supabase returning to the web origin', () {
      for (final link in [
        'https://beta.icarusstrats.com/?code=abc',
        'https://beta.icarusstrats.com?code=abc',
        'https://beta.icarusstrats.com/?code=abc#/',
        'https://beta.icarusstrats.com/#access_token=abc&refresh_token=def',
        'https://beta.icarusstrats.com/?error=server_error'
            '&error_description=Something+broke',
      ]) {
        expect(
          isAuthCallbackUri(Uri.parse(link), redirectUri: webRedirect),
          isTrue,
          reason: link,
        );
      }
    });

    test('rejects the web origin without a sign-in result', () {
      expect(
        isAuthCallbackUri(
          Uri.parse('https://beta.icarusstrats.com/'),
          redirectUri: webRedirect,
        ),
        isFalse,
      );
      expect(
        isAuthCallbackUri(
          Uri.parse('https://beta.icarusstrats.com/#/'),
          redirectUri: webRedirect,
        ),
        isFalse,
      );
    });

    test('rejects a share link that carries ?code=', () {
      expect(
        isAuthCallbackUri(
          Uri.parse(
            'https://beta.icarusstrats.com/share?code=ICR-2345-6789-ABCD-EFGH',
          ),
          redirectUri: webRedirect,
        ),
        isFalse,
      );
    });

    test('rejects a sign-in result aimed at a different origin', () {
      for (final link in [
        'https://icarusstrats.com/?code=abc',
        'https://other.icarus-web-a50.pages.dev/?code=abc',
        'http://beta.icarusstrats.com/?code=abc',
        'https://beta.icarusstrats.com:8443/?code=abc',
        'icarus://auth/callback?code=abc',
      ]) {
        expect(
          isAuthCallbackUri(Uri.parse(link), redirectUri: webRedirect),
          isFalse,
          reason: link,
        );
      }
      expect(
        isAuthCallbackUri(
          Uri.parse('https://beta.icarusstrats.com/?code=abc'),
          redirectUri: nativeAuthRedirectUri,
        ),
        isFalse,
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
