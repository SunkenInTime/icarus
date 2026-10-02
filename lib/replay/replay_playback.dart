import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/replay/replay_map_projection.dart';

/// Playback state for one open replay: the clock, the speed, and whose eyes
/// the match is seen through. The view drives [advance] from a ticker.
class ReplayPlayback extends ChangeNotifier {
  ReplayPlayback({
    required this.document,
    required ReplayMapProjection projection,
    required ReplayTeam perspective,
  })  : frames = ReplayFrameBuilder(document, projection),
        _perspective = perspective {
    final first = document.rounds.isEmpty ? null : document.rounds.first;
    _timeMs = first?.playStartMs ?? 0;
  }

  static const speeds = [0.5, 1.0, 2.0, 4.0];

  final ReplayDocument document;
  final ReplayFrameBuilder frames;

  int _timeMs = 0;
  bool _playing = false;
  double _speed = 1;
  ReplayTeam _perspective;

  int get timeMs => _timeMs;
  bool get playing => _playing;
  double get speed => _speed;
  ReplayTeam get perspective => _perspective;

  int get durationMs => document.match.durationMs;
  ReplayRound? get round => document.roundAt(_timeMs);

  ReplayFrame? _frame;
  ReplayFrame get frame {
    final cached = _frame;
    if (cached != null &&
        cached.timeMs == _timeMs &&
        _framePerspective == _perspective) {
      return cached;
    }
    _framePerspective = _perspective;
    return _frame = frames.frameAt(_timeMs, perspective: _perspective);
  }

  ReplayTeam? _framePerspective;

  void play() {
    if (_playing) return;
    if (_timeMs >= durationMs) _timeMs = round?.playStartMs ?? 0;
    _playing = true;
    notifyListeners();
  }

  void pause() {
    if (!_playing) return;
    _playing = false;
    notifyListeners();
  }

  void togglePlaying() => _playing ? pause() : play();

  set speed(double value) {
    if (_speed == value) return;
    _speed = value;
    notifyListeners();
  }

  set perspective(ReplayTeam value) {
    if (_perspective == value) return;
    _perspective = value;
    notifyListeners();
  }

  void seek(int timeMs) {
    final clamped = timeMs.clamp(0, durationMs);
    if (clamped == _timeMs) return;
    _timeMs = clamped;
    notifyListeners();
  }

  /// Moves the clock by [elapsed] of wall time at the current speed.
  void advance(Duration elapsed) {
    if (!_playing) return;
    final next = _timeMs + (elapsed.inMicroseconds * _speed / 1000).round();
    _timeMs = math.min(next, durationMs);
    if (_timeMs >= durationMs) _playing = false;
    notifyListeners();
  }

  /// Jumps to where play starts in round [index].
  void seekRound(int index) {
    if (index < 0 || index >= document.rounds.length) return;
    seek(document.rounds[index].playStartMs);
  }

  void nextRound() => seekRound((round?.index ?? -1) + 1);

  /// The start of this round, or the previous round when already near its
  /// start, like a music player's back button.
  void previousRound() {
    final current = round;
    if (current == null) return;
    if (_timeMs - current.playStartMs > 2000) {
      seekRound(current.index);
    } else {
      seekRound(current.index - 1);
    }
  }
}
