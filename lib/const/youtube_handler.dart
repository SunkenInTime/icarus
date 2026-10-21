import 'package:http/http.dart' as http;

/// A YouTube video, and where to start it when the link says (`t` or
/// `start`, in any form YouTube writes: `90`, `90s`, `1m30s`).
typedef YoutubeVideo = ({String id, String? start});

class YoutubeHandler {
  /// The page that plays a video inside the app, kept on its own origin.
  static const embedHost = 'embed.icarus-strats.xyz';

  static final RegExp _videoId = RegExp(r'^[A-Za-z0-9_-]+$');
  static const _youtubeHosts = {
    'youtube.com',
    'm.youtube.com',
    'music.youtube.com',
    'youtube-nocookie.com',
  };

  /// Paths whose second segment is the video id, as in `/shorts/<id>`.
  static const _idPaths = {'shorts', 'embed', 'live', 'v'};

  static Future<bool> validateYoutubeLink(String youtubeLink) async {
    final response = await http.get(Uri.parse(youtubeLink));
    if (response.statusCode == 200) {
      return true;
    } else {
      return false;
    }
  }

  /// The video a lineup's YouTube link points at: a bare video id, or a
  /// youtu.be, watch, shorts, embed or live link, with or without the
  /// scheme. Null when the link names no video.
  static YoutubeVideo? parse(String youtubeLink) {
    final link = youtubeLink.trim();
    if (_videoId.hasMatch(link)) return (id: link, start: null);

    final uri = Uri.tryParse(link.contains('://') ? link : 'https://$link');
    if (uri == null) return null;
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

    String? id;
    if (host == 'youtu.be') {
      id = segments.firstOrNull;
    } else if (_youtubeHosts.contains(host)) {
      id = uri.queryParameters['v'];
      if (id == null &&
          segments.length >= 2 &&
          _idPaths.contains(segments[0])) {
        id = segments[1];
      }
    }
    if (id == null || !_videoId.hasMatch(id)) return null;

    final fragmentStart =
        uri.fragment.startsWith('t=') ? uri.fragment.substring(2) : null;
    final start = uri.queryParameters['t'] ??
        uri.queryParameters['start'] ??
        fragmentStart;
    return (id: id, start: start == null || start.isEmpty ? null : start);
  }

  /// The embed page playing [video].
  static Uri embedUri(YoutubeVideo video) {
    return Uri.https(embedHost, '/', {
      'v': video.id,
      if (video.start != null) 't': video.start!,
    });
  }
}
