import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/share/current_share_origin.dart';
import 'package:icarus/share/share_link_format.dart';
import 'package:icarus/strategy/open_seen.dart';

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

/// A post asked to open. The navigation layer (MouseNavigation) opens it
/// and clears this back to null.
final communityPostToOpenProvider = StateProvider<PostToOpen?>((ref) => null);

sealed class PostToOpen {
  const PostToOpen(this.postPublicId);

  final String postPublicId;
}

/// A link from outside the app: it asks about what is open once its post
/// is ready.
final class PostLinkArrived extends PostToOpen {
  const PostLinkArrived(super.postPublicId);
}

/// A tap in the app: it carries what was open when the user tapped, and
/// gives way once that is no longer open, like a Community card.
final class PostTapped extends PostToOpen {
  const PostTapped(super.postPublicId, this.asked);

  final OpenSeen asked;
}

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
