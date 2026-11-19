import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/share/current_share_origin.dart';
import 'package:icarus/share/share_link_format.dart';

/// A Community post's link, e.g. `https://icarusstrats.com/community/<id>`.
/// It opens in the browser for anyone, account or not.
String buildCommunityPostLink(String postPublicId) {
  return currentShareOrigin()
      .replace(pathSegments: ['community', postPublicId]).toString();
}

/// The post [uri] links to: `/community/<id>` on the production host or on
/// [currentOrigin] (the web page's own), or `icarus://community/<id>`.
String? communityPostIdFromUri(Uri uri, {required Uri currentOrigin}) {
  final List<String> segments;
  try {
    segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  } on FormatException {
    return null;
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'icarus') {
    final parts = [
      if (uri.host.isNotEmpty) uri.host.toLowerCase(),
      ...segments,
    ];
    return parts.length == 2 && parts.first == 'community' ? parts[1] : null;
  }
  if (scheme != 'https' && scheme != 'http') return null;
  final host = uri.host.toLowerCase();
  final known = host == icarusShareHost ||
      host == 'www.$icarusShareHost' ||
      (host == currentOrigin.host.toLowerCase() &&
          uri.port == currentOrigin.port &&
          scheme == currentOrigin.scheme.toLowerCase());
  if (!known) return null;
  if (segments.length != 2 || segments.first.toLowerCase() != 'community') {
    return null;
  }
  return RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(segments[1])
      ? segments[1]
      : null;
}

/// A post a link asked to open. The navigation layer (MouseNavigation)
/// opens it and clears this back to null.
final communityPostToOpenProvider = StateProvider<String?>((ref) => null);

Future<void> copyCommunityPostLink(
  BuildContext context,
  CommunityPost post,
) async {
  final l10n = context.l10n;
  await Clipboard.setData(
    ClipboardData(text: buildCommunityPostLink(post.publicId)),
  );
  Settings.showToast(
    message: l10n.communityLinkCopied,
    backgroundColor: Settings.tacticalVioletTheme.secondary,
  );
}
