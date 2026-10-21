import 'package:http/http.dart' as http;

/// A YouTube video, and the second to start it at when the link says.
typedef YoutubeVideo = ({String id, int? startSeconds});

class YoutubeHandler {
  /// The page that plays a video inside the app, kept on its own origin.
  static const embedHost = 'embed.icarus-strats.xyz';

  static final RegExp _videoId = RegExp(r'^[A-Za-z0-9_-]+$');

  /// An id with a start time, `<id>&t=42`, as the old parser handed links
  /// to the embed page.
  static final RegExp _idWithStart = RegExp(r'^([A-Za-z0-9_-]+)&t=(.*)$');

  /// A start time in a form YouTube writes: `90`, `90s`, `1m30s`, `1h2m3s`.
  static final RegExp _start = RegExp(r'^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s?)?$');

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
    if (_videoId.hasMatch(link)) return (id: link, startSeconds: null);
    if (_idWithStart.firstMatch(link) case final match?) {
      return (id: match[1]!, startSeconds: _seconds(match[2]));
    }

    final uri = Uri.tryParse(switch (link) {
      _ when link.contains('://') => link,
      _ when link.startsWith('//') => 'https:$link',
      _ => 'https://$link',
    });
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
    return (id: id, startSeconds: _seconds(start));
  }

  /// [start] in whole seconds, or null when it is missing, zero or not a
  /// time. The embed page reads only plain seconds reliably: it turns
  /// `90s` into `start=NaN`.
  static int? _seconds(String? start) {
    final match = start == null ? null : _start.firstMatch(start);
    if (match == null) return null;
    final seconds = int.parse(match[1] ?? '0') * 3600 +
        int.parse(match[2] ?? '0') * 60 +
        int.parse(match[3] ?? '0');
    return seconds > 0 ? seconds : null;
  }

  /// The embed page playing [video].
  static Uri embedUri(YoutubeVideo video) {
    return Uri.https(embedHost, '/', {
      'v': video.id,
      if (video.startSeconds != null) 't': '${video.startSeconds}',
    });
  }
}
