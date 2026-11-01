/// One run of a caption's text: plain, or a link to [uri] shown as written.
typedef CaptionRun = ({String text, Uri? uri});

/// Anything that could be a link: a web address, or the bare forms someone is
/// likely to paste. What it ends at is decided by [_withoutTrailing].
final _candidate = RegExp(
  r'(?:https?://|www\.|youtu\.be/|youtube\.com/)[^\s<>"]+',
  caseSensitive: false,
);

/// Characters that end a sentence around a link and aren't part of it.
const _trailing = '.,;:!?\'"';

String _withoutTrailing(String link) {
  var end = link.length;
  while (end > 0) {
    final last = link[end - 1];
    if (_trailing.contains(last)) {
      end--;
    } else if (last == ')' && !link.substring(0, end).contains('(')) {
      end--;
    } else {
      break;
    }
  }
  return link.substring(0, end);
}

/// Where [text] goes, or null when it shouldn't be clickable: what a caption
/// shows is where it goes, so an address built to mislead stays plain text.
Uri? _linkTarget(String text) {
  final scheme = text.toLowerCase().startsWith('http') ? '' : 'https://';
  final uri = Uri.tryParse('$scheme$text');
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      text.contains('@') && uri.host.contains('@')) {
    return null;
  }
  if (text.runes.any((code) => code < 0x20 || code == 0x7f)) return null;
  return uri;
}

/// [caption] as runs, in order, that join back to exactly [caption].
List<CaptionRun> captionRuns(String caption) {
  final runs = <CaptionRun>[];
  var at = 0;
  void plain(int end) {
    if (end > at) runs.add((text: caption.substring(at, end), uri: null));
    at = end;
  }

  for (final match in _candidate.allMatches(caption)) {
    if (match.start < at) continue;
    final link = _withoutTrailing(match.group(0)!);
    final uri = _linkTarget(link);
    if (uri == null) continue;
    plain(match.start);
    runs.add((text: link, uri: uri));
    at = match.start + link.length;
  }
  plain(caption.length);
  return runs;
}
