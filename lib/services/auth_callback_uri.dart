import 'package:icarus/l10n/l10n.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthException, ErrorCode;

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

  // Parameter names compared in lowercase, so `ACCESS_TOKEN=` is rejected too.
  final Set<String> query;
  final Set<String> fragment;
  try {
    query = _lowercaseKeys(uri.queryParameters.keys);
    fragment = _lowercaseKeys(Uri.splitQueryString(uri.fragment).keys);
  } on FormatException {
    // Undecodable escapes: nothing Supabase sends. Fail closed.
    return AuthCallback.injectedTokens;
  }
  bool has(String key) => query.contains(key) || fragment.contains(key);

  if (_sessionTokenParameters.any(has)) {
    return AuthCallback.injectedTokens;
  }
  if (query.contains('code') ||
      has('error') ||
      has('error_code') ||
      has('error_description')) {
    return AuthCallback.signInResult;
  }
  return AuthCallback.none;
}

/// Why a link from an auth email can't finish here, in the words the sign-in
/// dialog opens with.
enum AuthLinkNotice {
  emailConfirmed(isInfo: true),
  linkExpired(isInfo: false),
  resetLinkTimedOut(isInfo: false);

  const AuthLinkNotice({required this.isInfo});

  String message(AppLocalizations l10n) => switch (this) {
        emailConfirmed => l10n.serviceMsgAuthEmailConfirmed,
        linkExpired => l10n.serviceMsgAuthLinkExpired,
        resetLinkTimedOut => l10n.serviceMsgAuthResetLinkTimedOut,
      };

  final bool isInfo;
}

/// What the person holding [uri] should be told when `getSessionFromUrl`
/// failed with [error], or null when this is a real failure to report.
/// [resetPending] is whether this device last asked for a password reset.
///
/// Supabase checks an email link before it comes back here, so a `code` proves
/// the email is confirmed even when the code can't become a session. It can't
/// say which email link this was: a password reset opened in another browser
/// lands the same way, and it confirmed the address too. A marker on the
/// redirect can't say either, because the allowlist turns a redirect with a
/// query into the Site URL. Only a reset that timed out where it was asked
/// for can be told apart. `otp_expired` proves nothing about the email: it is
/// the same answer for a link never used and one used a minute ago.
AuthLinkNotice? authLinkNoticeFor(
  Uri uri,
  Object error, {
  required bool resetPending,
}) {
  final Map<String, String> query;
  final Map<String, String> fragment;
  try {
    query = uri.queryParameters;
    fragment = Uri.splitQueryString(uri.fragment);
  } on FormatException {
    return null;
  }

  if ((query['error_code'] ?? fragment['error_code']) == 'otp_expired') {
    return AuthLinkNotice.linkExpired;
  }
  if (query.containsKey('code') && _codeCannotFinishHere(error)) {
    return resetPending && _isCode(error, ErrorCode.flowStateExpired)
        ? AuthLinkNotice.resetLinkTimedOut
        : AuthLinkNotice.emailConfirmed;
  }
  return null;
}

/// Supabase issued the code, but this browser can't turn it into a session:
/// it isn't the browser that asked, or the request is over five minutes old,
/// which is how long a code lasts counted from the sign-up. A verifier that
/// doesn't match isn't here: a second Discord tab causes that too, and there
/// a code proves nothing about an email.
bool _codeCannotFinishHere(Object error) {
  return _isCode(error, ErrorCode.flowStateExpired) ||
      (error is AuthException && error.message.contains(_noVerifierMessage));
}

bool _isCode(Object error, ErrorCode code) =>
    error is AuthException && error.code == code.code;

/// GoTrue throws this before calling the server, so it has no error code.
const _noVerifierMessage = 'Code verifier could not be found';

/// Where GoTrue keeps the verifier for the last link this device asked for.
const pkceVerifierStorageKey = 'supabase.auth.token-code-verifier';

/// Whether [stored], the value at [pkceVerifierStorageKey], belongs to a
/// password reset. GoTrue keeps which request it was after a slash.
bool isPasswordResetVerifier(String? stored) =>
    stored?.endsWith('/${AuthChangeEvent.passwordRecovery.name}') ?? false;

const _sessionTokenParameters = {
  'access_token',
  'refresh_token',
  'provider_token',
  'provider_refresh_token',
};

Set<String> _lowercaseKeys(Iterable<String> keys) =>
    {for (final key in keys) key.toLowerCase()};

bool _isAuthCallbackParameter(String key) =>
    _authCallbackParameters.contains(key.toLowerCase());

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
      ..removeWhere((key, _) => _isAuthCallbackParameter(key));
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
      if (!_isAuthCallbackParameter(entry.key)) entry.key: entry.value,
  };
  if (kept.length == parameters.length) {
    return fragment;
  }
  return kept.isEmpty ? null : Uri(queryParameters: kept).query;
}
