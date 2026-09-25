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

/// What a URI arriving on this build's auth redirect carries.
enum AuthCallback {
  /// Not a sign-in callback. Leave it to other handlers.
  none,

  /// A PKCE `code` or an error from Supabase: safe to hand to
  /// `getSessionFromUrl`. A code only exchanges with the verifier this
  /// device saved when it started sign-in, so a forged code just fails.
  signInResult,

  /// Session tokens in the URL. We only use the PKCE flow, so Supabase never
  /// sends these; anyone can craft such a link, and GoTrue would sign the
  /// user into the account it names. Never exchange it, only scrub it.
  injectedTokens,
}

/// Classifies [uri] against [redirectUri], the redirect this build asked
/// Supabase for.
AuthCallback classifyAuthCallbackUri(Uri uri, {required Uri redirectUri}) {
  final landsOnRedirect =
      uri.scheme.toLowerCase() == redirectUri.scheme.toLowerCase() &&
          uri.host.toLowerCase() == redirectUri.host.toLowerCase() &&
          uri.port == redirectUri.port &&
          _rootedPath(uri) == _rootedPath(redirectUri);
  if (!landsOnRedirect) {
    return AuthCallback.none;
  }

  final Map<String, String> query;
  final Map<String, String> fragment;
  try {
    query = uri.queryParameters;
    fragment = Uri.splitQueryString(uri.fragment);
  } on FormatException {
    // Undecodable escapes: nothing Supabase sends. Fail closed.
    return AuthCallback.injectedTokens;
  }
  bool has(String key) => query.containsKey(key) || fragment.containsKey(key);

  if (_sessionTokenParameters.any(has)) {
    return AuthCallback.injectedTokens;
  }
  if (query.containsKey('code') ||
      has('error') ||
      has('error_code') ||
      has('error_description')) {
    return AuthCallback.signInResult;
  }
  return AuthCallback.none;
}

const _sessionTokenParameters = {
  'access_token',
  'refresh_token',
  'provider_token',
  'provider_refresh_token',
};

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
  Map<String, List<String>> query;
  try {
    query = Map.of(uri.queryParametersAll)
      ..removeWhere((key, _) => _authCallbackParameters.contains(key));
  } on FormatException {
    query = const {}; // Undecodable, so drop it rather than keep a payload.
  }

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

  final Map<String, List<String>> parameters;
  try {
    parameters = Uri(query: fragment).queryParametersAll;
  } on FormatException {
    return null; // Undecodable, so it cannot be a route worth keeping.
  }
  final kept = {
    for (final entry in parameters.entries)
      if (!_authCallbackParameters.contains(entry.key)) entry.key: entry.value,
  };
  if (kept.length == parameters.length) {
    return fragment;
  }
  return kept.isEmpty ? null : Uri(queryParameters: kept).query;
}
