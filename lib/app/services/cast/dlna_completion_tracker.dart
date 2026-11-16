import 'package:media_cast_dlna/media_cast_dlna.dart';

/// Keeps the last usable playback sample when a renderer loses its position at EOF.
class DlnaCompletionTracker {
  int _position = -1;
  int _duration = 0;
  Duration? _sampleAt;
  bool _playing = false;
  int? _seekTarget;
  Duration? _seekDeadline;

  void reset() {
    _position = -1;
    _duration = 0;
    _sampleAt = null;
    _playing = false;
    _seekTarget = null;
    _seekDeadline = null;
  }

  void seek(int target, Duration now) {
    reset();
    _seekTarget = target;
    _seekDeadline = now + const Duration(seconds: 5);
  }

  bool observe({
    required TransportState state,
    required Duration now,
    required int duration,
    int? position,
  }) {
    if (duration > 0) _duration = duration;
    if (_seekTarget != null) {
      if ((position != null && (position - _seekTarget!).abs() <= 2) ||
          now >= _seekDeadline!) {
        _seekTarget = null;
        _seekDeadline = null;
        _record(state, position, now);
      }
      return false;
    }
    final stopped =
        state == TransportState.stopped ||
        state == TransportState.noMediaPresent;
    final canComplete = state == TransportState.playing || stopped;
    final nearEnd = _duration > 0 && _position >= _duration * 0.9;
    final elapsed = _sampleAt == null ? Duration.zero : now - _sampleAt!;
    // Infer a missed EOF only after a playing sample and a gap long enough to
    // consume the remaining media. A paused/buffering sample cancels inference.
    final missedEnd =
        _playing &&
        _position > 0 &&
        _duration > 0 &&
        elapsed > const Duration(seconds: 3) &&
        _position + elapsed.inSeconds >= _duration;
    final completed =
        canComplete &&
        _playing &&
        ((stopped && (nearEnd || missedEnd)) ||
            (position != null &&
                _duration > 0 &&
                position >= _duration &&
                _position >= _duration) ||
            (position != null &&
                position <= 5 &&
                nearEnd &&
                _position > position + 30));
    _record(state, position, now);
    return completed;
  }

  void _record(TransportState state, int? position, Duration now) {
    if (position != null && position >= 0) {
      _position = position;
      _sampleAt = now;
    }
    if (state != TransportState.playing) {
      _playing = false;
    } else {
      if (!_playing) _sampleAt = now;
      _playing = true;
    }
  }
}
