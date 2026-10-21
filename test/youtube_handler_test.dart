import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/youtube_handler.dart';

void main() {
  group('YoutubeHandler.parse', () {
    const id = 'dQw4w9WgXcQ';

    test('reads every common link form', () {
      const links = {
        id: (id: id, startSeconds: null),
        'https://youtu.be/$id': (id: id, startSeconds: null),
        'https://youtu.be/$id?t=42': (id: id, startSeconds: 42),
        'https://www.youtube.com/watch?v=$id': (id: id, startSeconds: null),
        'https://www.youtube.com/watch?v=$id&t=1m30s': (
          id: id,
          startSeconds: 90
        ),
        'https://youtube.com/watch?feature=share&v=$id': (
          id: id,
          startSeconds: null
        ),
        'https://m.youtube.com/watch?v=$id': (id: id, startSeconds: null),
        'https://music.youtube.com/watch?v=$id': (id: id, startSeconds: null),
        'https://www.youtube.com/shorts/$id': (id: id, startSeconds: null),
        'https://youtube.com/shorts/$id?feature=share': (
          id: id,
          startSeconds: null
        ),
        'https://www.youtube.com/embed/$id?start=90': (
          id: id,
          startSeconds: 90
        ),
        'https://www.youtube-nocookie.com/embed/$id': (
          id: id,
          startSeconds: null
        ),
        'https://www.youtube.com/live/$id': (id: id, startSeconds: null),
        'https://www.youtube.com/watch?v=$id#t=75': (id: id, startSeconds: 75),
        'youtube.com/watch?v=$id': (id: id, startSeconds: null),
        'www.youtu.be/$id': (id: id, startSeconds: null),
        '  https://youtu.be/$id  ': (id: id, startSeconds: null),
        'HTTPS://WWW.YOUTUBE.COM/watch?v=$id': (id: id, startSeconds: null),
      };
      for (final MapEntry(key: link, value: expected) in links.entries) {
        expect(YoutubeHandler.parse(link), expected, reason: link);
      }
    });

    test('still reads the forms the old parser handled', () {
      expect(YoutubeHandler.parse('//youtu.be/$id?t=42'),
          (id: id, startSeconds: 42));
      expect(YoutubeHandler.parse('$id&t=42'), (id: id, startSeconds: 42));
      expect(YoutubeHandler.parse('$id&t=null'), (id: id, startSeconds: null));
    });

    test('turns every start form into seconds', () {
      for (final MapEntry(key: t, value: seconds) in {
        '90': 90,
        '90s': 90,
        '2m': 120,
        '1m30s': 90,
        '1h2m3s': 3723,
        '0': null,
        'soon': null,
        '': null,
      }.entries) {
        expect(YoutubeHandler.parse('https://youtu.be/$id?t=$t')?.startSeconds,
            seconds,
            reason: t);
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

  test('embedUri sends the id and plain seconds as their own parameters', () {
    final uri = YoutubeHandler.embedUri((id: 'abc_DEF-123', startSeconds: 90));
    expect(uri.host, YoutubeHandler.embedHost);
    expect(uri.queryParameters, {'v': 'abc_DEF-123', 't': '90'});
    expect(
      YoutubeHandler.embedUri((id: 'abc', startSeconds: null)).queryParameters,
      {'v': 'abc'},
    );
  });
}
