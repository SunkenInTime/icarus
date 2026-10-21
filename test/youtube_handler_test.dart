import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/youtube_handler.dart';

void main() {
  group('YoutubeHandler.parse', () {
    const id = 'dQw4w9WgXcQ';

    test('reads every common link form', () {
      const links = {
        id: (id: id, start: null),
        'https://youtu.be/$id': (id: id, start: null),
        'https://youtu.be/$id?t=42': (id: id, start: '42'),
        'https://www.youtube.com/watch?v=$id': (id: id, start: null),
        'https://www.youtube.com/watch?v=$id&t=1m30s': (id: id, start: '1m30s'),
        'https://youtube.com/watch?feature=share&v=$id': (id: id, start: null),
        'https://m.youtube.com/watch?v=$id': (id: id, start: null),
        'https://music.youtube.com/watch?v=$id': (id: id, start: null),
        'https://www.youtube.com/shorts/$id': (id: id, start: null),
        'https://youtube.com/shorts/$id?feature=share': (id: id, start: null),
        'https://www.youtube.com/embed/$id?start=90': (id: id, start: '90'),
        'https://www.youtube-nocookie.com/embed/$id': (id: id, start: null),
        'https://www.youtube.com/live/$id': (id: id, start: null),
        'https://www.youtube.com/watch?v=$id#t=75': (id: id, start: '75'),
        'youtube.com/watch?v=$id': (id: id, start: null),
        'www.youtu.be/$id': (id: id, start: null),
        '  https://youtu.be/$id  ': (id: id, start: null),
        'HTTPS://WWW.YOUTUBE.COM/watch?v=$id': (id: id, start: null),
      };
      for (final MapEntry(key: link, value: expected) in links.entries) {
        expect(YoutubeHandler.parse(link), expected, reason: link);
      }
    });

    test('names no video for links without one', () {
      for (final link in [
        '',
        'https://youtube.com',
        'https://www.youtube.com/',
        'https://www.youtube.com/watch',
        'https://www.youtube.com/@channel',
        'https://youtu.be/',
        'https://vimeo.com/123456',
        'https://example.com/watch?v=$id',
        'https://www.youtube.com/watch?v=$id%26autoplay%3D0',
        'not a link',
      ]) {
        expect(YoutubeHandler.parse(link), isNull, reason: link);
      }
    });
  });

  test('embedUri keeps the id and start inside their own parameters', () {
    final uri = YoutubeHandler.embedUri((id: 'abc_DEF-123', start: '1m&x=1'));
    expect(uri.host, YoutubeHandler.embedHost);
    expect(uri.queryParameters, {'v': 'abc_DEF-123', 't': '1m&x=1'});
  });
}
