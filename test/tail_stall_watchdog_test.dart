import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/player/tail_stall_watchdog.dart';

void main() {
  const timeout = Duration(milliseconds: 40);
  const wait = Duration(milliseconds: 100);

  late bool nearEnd;
  late List<String> stalls;
  late TailStallWatchdog watchdog;

  setUp(() {
    nearEnd = true;
    stalls = [];
    watchdog = TailStallWatchdog(
      isNearEnd: () => nearEnd,
      onStall: stalls.add,
      timeout: timeout,
    );
  });

  tearDown(() => watchdog.cancel());

  test('末尾持续 buffering 超时后按播完处理', () async {
    watchdog.update(stalled: true, trackId: 'a');
    await Future<void>.delayed(wait);
    expect(stalls, ['a']);
  });

  test('超时前恢复 ready 不触发', () async {
    watchdog.update(stalled: true, trackId: 'a');
    watchdog.update(stalled: false, trackId: 'a');
    await Future<void>.delayed(wait);
    expect(stalls, isEmpty);
  });

  test('歌曲中途 buffering 不触发', () async {
    nearEnd = false;
    watchdog.update(stalled: true, trackId: 'a');
    await Future<void>.delayed(wait);
    expect(stalls, isEmpty);
  });

  test('重复 buffering 事件不重置计时，切歌重新计时', () async {
    watchdog.update(stalled: true, trackId: 'a');
    await Future<void>.delayed(const Duration(milliseconds: 25));
    watchdog.update(stalled: true, trackId: 'a');
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(stalls, ['a']);

    watchdog.update(stalled: true, trackId: 'b');
    watchdog.update(stalled: true, trackId: 'c');
    await Future<void>.delayed(wait);
    expect(stalls, ['a', 'c']);
  });

  test('接近末尾判定使用 10 秒窗口，未知时长不判定', () {
    const total = Duration(seconds: 200);
    expect(
      TailStallWatchdog.isPositionNearEnd(const Duration(seconds: 191), total),
      isTrue,
    );
    expect(
      TailStallWatchdog.isPositionNearEnd(const Duration(seconds: 180), total),
      isFalse,
    );
    expect(
      TailStallWatchdog.isPositionNearEnd(const Duration(seconds: 199), null),
      isFalse,
    );
  });
}
