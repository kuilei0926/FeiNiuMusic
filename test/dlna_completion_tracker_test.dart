import 'package:flutter_test/flutter_test.dart';
import 'package:media_cast_dlna/media_cast_dlna.dart';

import 'package:feiniu_music/app/services/cast/dlna_completion_tracker.dart';

void main() {
  late DlnaCompletionTracker tracker;
  setUp(() => tracker = DlnaCompletionTracker());

  bool sample(int time, TransportState state, int? position) => tracker.observe(
    state: state,
    now: Duration(seconds: time),
    duration: 200,
    position: position,
  );

  test('missed tail samples still complete after the remaining time passes', () {
    expect(sample(0, TransportState.playing, 170), isFalse);
    expect(sample(31, TransportState.stopped, 0), isTrue);
    expect(sample(32, TransportState.stopped, 0), isFalse);
  });

  test('mid-song stop before expected EOF does not advance', () {
    sample(0, TransportState.playing, 170);
    expect(sample(2, TransportState.stopped, 0), isFalse);
  });

  test('transport-only EOF uses the last valid near-end position', () {
    sample(0, TransportState.playing, 190);
    expect(sample(1, TransportState.stopped, null), isTrue);
  });

  test('transport-only playback can bridge missing tail samples', () {
    sample(0, TransportState.playing, 170);
    sample(10, TransportState.playing, null);
    expect(sample(31, TransportState.stopped, null), isTrue);
  });

  test('pause and buffering prevent elapsed-time completion inference', () {
    for (final state in [TransportState.paused, TransportState.transitioning]) {
      tracker.reset();
      sample(0, TransportState.playing, 170);
      sample(1, state, 170);
      expect(sample(60, TransportState.stopped, 0), isFalse);
    }
  });

  test('seek discards stale tail positions before accepting the target', () {
    sample(0, TransportState.playing, 190);
    tracker.seek(0, const Duration(seconds: 1));
    expect(sample(2, TransportState.playing, 191), isFalse);
    expect(sample(3, TransportState.playing, 0), isFalse);
    expect(sample(4, TransportState.playing, 1), isFalse);
  });

  test('seek suppression expires if renderer never reports the target', () {
    sample(0, TransportState.playing, 190);
    tracker.seek(0, const Duration(seconds: 1));
    expect(sample(7, TransportState.playing, 198), isFalse);
    expect(sample(9, TransportState.stopped, 0), isTrue);
  });

  test('new song and a stream that never advanced cannot imply completion', () {
    sample(0, TransportState.playing, 199);
    tracker.reset();
    expect(sample(1, TransportState.stopped, 0), isFalse);
    sample(2, TransportState.playing, 0);
    expect(sample(300, TransportState.stopped, 0), isFalse);
  });
}
