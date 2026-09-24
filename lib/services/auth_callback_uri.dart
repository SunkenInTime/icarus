/// Where Supabase sends desktop builds back after Discord sign-in.
final Uri nativeAuthRedirectUri = Uri(
  scheme: 'icarus',
  host: 'auth',
  path: '/callback',
);

/// Where Supabase sends a browser back after Discord sign-in: the root of the
/// page's own origin.
///
/// The root, not the page's current path, so each origin needs exactly one
/// entry in the Supabase redirect allowlist.
Uri webAuthRedirectUri(Uri pageUri) => Uri.parse('${pageUri.origin}/');

/// Whether [uri] is Supabase returning to [redirectUri] with a sign-in
/// result (a PKCE code, tokens, or an error) to exchange for a session.
bool isAuthCallbackUri(Uri uri, {required Uri redirectUri}) {
  final landsOnRedirect =
      uri.scheme.toLowerCase() == redirectUri.scheme.toLowerCase() &&
          uri.host.toLowerCase() == redirectUri.host.toLowerCase() &&
          uri.port == redirectUri.port &&
          _rootedPath(uri) == _rootedPath(redirectUri);
  if (!landsOnRedirect) {
    return false;
  }

  return uri.fragment.contains('access_token') ||
      uri.queryParameters.containsKey('code') ||
      uri.fragment.contains('error_description') ||
      uri.queryParameters.containsKey('error_description');
}

String _rootedPath(Uri uri) {
  final path = uri.path.toLowerCase();
  return path.isEmpty ? '/' : path;
}

/// The parameters Supabase adds to the redirect URI. Mirrors the list
/// supabase_flutter strips when it detects sessions itself.
const _authCallbackParameters = {
  'code',
  'access_token',
  'expires_in',
  'expires_at',
  'refresh_token',
  'token_type',
  'provider_token',
  'provider_refresh_token',
  'error',
  'error_code',
  'error_description',
  'type',
};

/// [uri] without the sign-in result Supabase added, keeping everything else
/// (including a Flutter `#/route` fragment). Once handled, the code is spent;
/// leaving it in the address bar would re-run the callback on refresh.
Uri withoutAuthCallbackParameters(Uri uri) {
  final query = Map<String, List<String>>.of(uri.queryParametersAll)
    ..removeWhere((key, _) => _authCallbackParameters.contains(key));

  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    queryParameters: query.isEmpty ? null : query,
    fragment: _withoutAuthFragmentParameters(uri.fragment),
  );
}

String? _withoutAuthFragmentParameters(String fragment) {
  if (fragment.isEmpty) {
    return null;
  }

  final parameters = Uri(query: fragment).queryParametersAll;
  final kept = {
    for (final entry in parameters.entries)
      if (!_authCallbackParameters.contains(entry.key)) entry.key: entry.value,
  };
  if (kept.length == parameters.length) {
    return fragment;
  }
  return kept.isEmpty ? null : Uri(queryParameters: kept).query;
}
