import 'dart:math';

/// The production host. Native builds put it in every share link they make,
/// and every build recognizes it.
const icarusShareHost = 'icarusstrats.com';
final Uri icarusProductionShareOrigin = Uri.https(icarusShareHost);

const _shareCodePrefix = 'ICR';
const _shareCodeAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
final _shareCodePattern = RegExp(
  r'^ICR-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}$',
);

/// The link for [code] on [origin], e.g. `https://icarusstrats.com/share/ICR-…`.
String buildIcarusShareLink(String code, {required Uri origin}) {
  return origin.replace(pathSegments: ['share', code]).toString();
}

/// Whether [uri] is a share link: the `icarus://share` scheme, or a `/share/`
/// path on the production host or on [currentOrigin] (the web page's own
/// origin, so links made in the beta open in the beta).
bool isIcarusShareUri(Uri uri, {required Uri currentOrigin}) {
  final bool hasSharePath;
  try {
    hasSharePath =
        uri.pathSegments.any((segment) => segment.toLowerCase() == 'share');
  } on FormatException {
    return false; // A path that does not decode is not a link we made.
  }

  if (uri.scheme.toLowerCase() == 'icarus') {
    return uri.host.toLowerCase() == 'share' || hasSharePath;
  }
  if (!hasSharePath) {
    return false;
  }
  return _isProductionShareHost(uri) || _hasOrigin(uri, currentOrigin);
}

bool _isProductionShareHost(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  return (scheme == 'https' || scheme == 'http') &&
      (host == icarusShareHost || host == 'www.$icarusShareHost');
}

bool _hasOrigin(Uri uri, Uri origin) {
  return uri.host.isNotEmpty &&
      uri.scheme.toLowerCase() == origin.scheme.toLowerCase() &&
      uri.host.toLowerCase() == origin.host.toLowerCase() &&
      uri.port == origin.port;
}

String generateIcarusShareCode({Random? random}) {
  final source = random ?? Random.secure();
  final characters = List<String>.generate(
    16,
    (_) => _shareCodeAlphabet[source.nextInt(_shareCodeAlphabet.length)],
  );

  final grouped = <String>[];
  for (var index = 0; index < characters.length; index += 4) {
    grouped.add(characters.sublist(index, index + 4).join());
  }

  return '$_shareCodePrefix-${grouped.join('-')}';
}

/// The share code in [value], which is a share link (see [isIcarusShareUri])
/// or a bare code. A link to any other site gives null.
String? extractIcarusShareCode(String value, {required Uri currentOrigin}) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final uri = Uri.tryParse(trimmed);
  if (uri != null) {
    if (isIcarusShareUri(uri, currentOrigin: currentOrigin)) {
      try {
        final token =
            uri.queryParameters['token'] ?? uri.queryParameters['code'];
        if (token != null && token.isNotEmpty) {
          return _normalizeCodeOrLegacyToken(token);
        }

        final shareIndex = uri.pathSegments.indexWhere(
          (segment) => segment.toLowerCase() == 'share',
        );
        if (shareIndex >= 0 && shareIndex + 1 < uri.pathSegments.length) {
          return _normalizeCodeOrLegacyToken(uri.pathSegments[shareIndex + 1]);
        }
      } on FormatException {
        return null; // A query that does not decode holds no usable code.
      }
    }

    if (uri.hasScheme && (uri.host.isNotEmpty || uri.scheme == 'icarus')) {
      return null;
    }
  }

  return _normalizeCodeOrLegacyToken(trimmed);
}

String _normalizeCodeOrLegacyToken(String value) {
  final trimmed = value.trim();
  final upper = trimmed.toUpperCase();
  if (_shareCodePattern.hasMatch(upper)) {
    return upper;
  }
  return trimmed;
}
