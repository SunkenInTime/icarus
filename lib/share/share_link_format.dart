import 'dart:math';

const icarusShareHost = 'icarusstrats.com';
const _shareCodePrefix = 'ICR';
const _shareCodeAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
final _shareCodePattern = RegExp(
  r'^ICR-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}$',
);

String buildIcarusShareLink(String code) {
  return 'https://$icarusShareHost/share/${Uri.encodeComponent(code)}';
}

bool isIcarusShareUri(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final hasSharePath =
      uri.pathSegments.any((segment) => segment.toLowerCase() == 'share');

  final isCustomShareLink =
      scheme == 'icarus' && (host == 'share' || hasSharePath);
  final isWebShareLink = (scheme == 'https' || scheme == 'http') &&
      (host == icarusShareHost || host == 'www.$icarusShareHost') &&
      hasSharePath;

  return isCustomShareLink || isWebShareLink;
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

String? extractIcarusShareCode(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final uri = Uri.tryParse(trimmed);
  if (uri != null) {
    if (isIcarusShareUri(uri)) {
      final token = uri.queryParameters['token'] ?? uri.queryParameters['code'];
      if (token != null && token.isNotEmpty) {
        return _normalizeCodeOrLegacyToken(token);
      }

      final shareIndex = uri.pathSegments.indexWhere(
        (segment) => segment.toLowerCase() == 'share',
      );
      if (shareIndex >= 0 && shareIndex + 1 < uri.pathSegments.length) {
        return _normalizeCodeOrLegacyToken(uri.pathSegments[shareIndex + 1]);
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
