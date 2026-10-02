import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

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

  /// The part of a millisecond the clock has run but not yet shown, so
  /// playback speed doesn't depend on frame rate.
  double _carryMs = 0;
  bool _playing = false;
  double _speed = 1;
  ReplayTeam _perspective;

  int get timeMs => _timeMs;
  bool get playing => _playing;
  double get speed => _speed;
  ReplayTeam get perspective => _perspective;

  int get durationMs => document.match.durationMs;
  ReplayRound? get round => document.roundAt(_timeMs);

  /// The moment on screen. While playing, each new frame moves only the
  /// [_movesPerFrame] players whose shown pose is oldest, plus any older
  /// than [_maxPoseAgeMs]: a moved player's view cone is cut against the
  /// walls again, and all ten in one frame is more than a 165 Hz frame
  /// holds. Paused, every player is exact; so is every capture.
  ReplayFrame get frame {
    final cached = _frame;
    if (cached != null &&
        cached.timeMs == _timeMs &&
        _framePerspective == _perspective) {
      return cached;
    }
    _framePerspective = _perspective;
    if (_playing) {
      _staggerPoses();
    } else {
      _poseTimes.clear();
    }
    return _frame = frames.frameAt(
      _timeMs,
      perspective: _perspective,
      poseTimeOf: (player) => _poseTimes[player.subject] ?? _timeMs,
    );
  }

  ReplayFrame? _frame;
  ReplayTeam? _framePerspective;

  static const _movesPerFrame = 3;
  static const _maxPoseAgeMs = 66;

  /// When each player's shown pose was taken, while playing.
  final _poseTimes = <String, int>{};

  void _staggerPoses() {
    final players = document.players;
    if (_poseTimes.length != players.length) {
      for (final player in players) {
        _poseTimes[player.subject] = _timeMs;
      }
      return;
    }
    final oldestFirst = [...players]..sort(
        (a, b) => _poseTimes[a.subject]!.compareTo(_poseTimes[b.subject]!),
      );
    for (var i = 0; i < oldestFirst.length; i++) {
      final subject = oldestFirst[i].subject;
      final age = _timeMs - _poseTimes[subject]!;
      if (i < _movesPerFrame || age > _maxPoseAgeMs || age < 0) {
        _poseTimes[subject] = _timeMs;
      }
    }
  }

  /// The map's height model, for standing each cone on the right level;
  /// it loads after the replay opens.
  set heightModel(SvgHeightVisibility? model) {
    frames.heightModel = model;
    _frame = null;
    notifyListeners();
  }

  void play() {
    if (_playing) return;
    if (_timeMs >= durationMs) _timeMs = round?.playStartMs ?? 0;
    _playing = true;
    notifyListeners();
  }

  void pause() {
    if (!_playing) return;
    _playing = false;
    // Show every player exactly where they are.
    _frame = null;
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
    _carryMs = 0;
    _poseTimes.clear();
    if (clamped == _timeMs) return;
    _timeMs = clamped;
    notifyListeners();
  }

  /// Moves the clock by [elapsed] of wall time at the current speed.
  void advance(Duration elapsed) {
    if (!_playing) return;
    final exact = _carryMs + elapsed.inMicroseconds * _speed / 1000;
    final whole = exact.floor();
    _carryMs = exact - whole;
    _timeMs = math.min(_timeMs + whole, durationMs);
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
