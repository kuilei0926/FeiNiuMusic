import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_cast_dlna/media_cast_dlna.dart';

import 'package:feiniu_music/app/services/cast/dlna_cast_service.dart';
import 'package:feiniu_music/app/services/cast/media_stream_proxy.dart';
import 'package:feiniu_music/app/state/song_state.dart';

class _FakeCastApi extends MediaCastDlnaApi {
  Future<void> Function()? onStop;
  Future<void> Function()? onSetMedia;
  Future<PlaybackInfo> Function()? onPoll;
  final List<String> titles = [];
  int playCalls = 0;
  int pollCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> stop(DeviceUdn deviceUdn) async {
    stopCalls++;
    await onStop?.call();
  }

  @override
  Future<void> setMediaUri(
    DeviceUdn deviceUdn,
    Url uri,
    MediaMetadata metadata,
  ) async {
    titles.add((metadata as AudioMetadata).title!);
    await onSetMedia?.call();
  }

  @override
  Future<void> play(DeviceUdn deviceUdn) async {
    playCalls++;
  }

  @override
  Future<PlaybackInfo> getPlaybackInfo(DeviceUdn deviceUdn) async {
    pollCalls++;
    return await onPoll?.call() ?? _info(TransportState.playing, 10);
  }
}

PlaybackInfo _info(TransportState state, int seconds) => PlaybackInfo(
  state: state,
  position: TimePosition(seconds: seconds),
  duration: TimeDuration(seconds: 200),
);

SongEntity _song(String title) => SongEntity(
  id: title,
  title: title,
  artist: '[]',
  album: '{}',
  format: 'mp3',
  durationMs: 200000,
);

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for cast state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeCastApi api;
  late DlnaCastService service;

  setUp(() async {
    api = _FakeCastApi();
    service = DlnaCastService.forTest(api: api);
    service.currentDevice.value = DlnaDevice(
      udn: DeviceUdn(value: 'renderer'),
      friendlyName: 'MiCast Go',
      deviceType: 'MediaRenderer',
      manufacturerDetails: ManufacturerDetails(manufacturer: 'Xiaomi'),
      modelDetails: ModelDetails(modelName: 'MiCast Go'),
      ipAddress: IpAddress(value: '127.0.0.1'),
      port: NetworkPort(value: 80),
    );
    await MediaStreamProxy.instance.start(advertisedHost: '127.0.0.1');
  });

  tearDown(() async {
    await service.disconnect(silent: true);
  });

  test('慢切歌期间停轮询，播放启动时容忍停止帧，确认播放后仍检测停止', () async {
    var disconnects = 0;
    service.onCastDisconnect = () => disconnects++;
    await service.loadSong(_song('first'));
    await _waitUntil(() => api.pollCalls == 1);

    final stopped = Completer<void>();
    api.onStop = () => stopped.future;
    final pending = service.loadSong(_song('second'));
    try {
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(api.pollCalls, 1);
      expect(service.isCasting, isTrue);
    } finally {
      stopped.complete();
    }
    await pending;

    api.onPoll = () async => _info(TransportState.stopped, 0);
    await _waitUntil(() => api.pollCalls >= 5);
    expect(service.isCasting, isTrue);
    expect(disconnects, 0);

    api.onPoll = () async => _info(TransportState.playing, 10);
    await _waitUntil(() => service.castPosition.value.inSeconds == 10);
    api.onPoll = () async => _info(TransportState.stopped, 10);
    await _waitUntil(() => disconnects == 1);
    expect(service.isCasting, isFalse);
  });

  test('快速连续切歌串行执行，只播放最新请求', () async {
    final setMedia = Completer<void>();
    api.onSetMedia = () => setMedia.future;
    final first = service.loadSong(_song('first'));
    await _waitUntil(() => api.titles.isNotEmpty);
    final skipped = service.loadSong(_song('skipped'));
    final latest = service.loadSong(_song('latest'));
    try {
      await Future<void>.delayed(Duration.zero);
      expect(api.stopCalls, 1);
    } finally {
      setMedia.complete();
    }
    await Future.wait([first, skipped, latest]);
    expect(api.titles, ['first', 'latest']);
    expect(api.playCalls, 1);
    expect(service.isCasting, isTrue);
  });

  test('轮询不重叠，换歌后丢弃上一首的延迟结果', () async {
    final result = Completer<PlaybackInfo>();
    api.onPoll = () => result.future;
    await service.loadSong(_song('first'));
    await _waitUntil(() => api.pollCalls == 1);
    var progressCalls = 0;
    service.onCastProgress = (_, _) => progressCalls++;
    try {
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(api.pollCalls, 1);
      await service.loadSong(_song('second'));
    } finally {
      result.complete(_info(TransportState.stopped, 199));
    }
    await Future<void>.delayed(Duration.zero);
    expect(progressCalls, 0);
    expect(service.castPosition.value, Duration.zero);
    expect(service.isCasting, isTrue);

    api.onPoll = () async => _info(TransportState.playing, 12);
    await _waitUntil(() => progressCalls == 1);
    expect(service.castPosition.value, const Duration(seconds: 12));
  });

  test('上一首轮询失败不计入新歌的断线次数', () async {
    final result = Completer<PlaybackInfo>();
    api.onPoll = () => result.future;
    await service.loadSong(_song('first'));
    await _waitUntil(() => api.pollCalls == 1);
    await service.loadSong(_song('second'));
    result.completeError(StateError('old request'));
    await Future<void>.delayed(Duration.zero);

    api.onPoll = () async => throw StateError('unreachable');
    await _waitUntil(() => api.pollCalls >= 5);
    expect(service.isCasting, isTrue);
    await _waitUntil(() => !service.isCasting);
  });

  test('断开时取消在途换歌，不再发出播放命令', () async {
    final setMedia = Completer<void>();
    api.onSetMedia = () => setMedia.future;
    final pending = service.loadSong(_song('first'));
    await _waitUntil(() => api.titles.isNotEmpty);
    final disconnect = service.disconnect();
    setMedia.complete();
    await Future.wait([pending, disconnect]);
    expect(api.playCalls, 0);
    expect(service.isCasting, isFalse);
    expect(MediaStreamProxy.instance.isRunning, isFalse);
  });

  test('重连同一设备后丢弃旧会话的轮询结果', () async {
    final device = service.currentDevice.value;
    final result = Completer<PlaybackInfo>();
    api.onPoll = () => result.future;
    await service.loadSong(_song('first'));
    await _waitUntil(() => api.pollCalls == 1);
    await service.disconnect(silent: true);
    await MediaStreamProxy.instance.start(advertisedHost: '127.0.0.1');
    service.currentDevice.value = device;
    await service.loadSong(_song('second'));
    var progressCalls = 0;
    service.onCastProgress = (_, _) => progressCalls++;
    result.complete(_info(TransportState.stopped, 199));
    await Future<void>.delayed(Duration.zero);
    expect(progressCalls, 0);
    expect(service.castPosition.value, Duration.zero);
    api.onPoll = () async => _info(TransportState.playing, 12);
    await _waitUntil(() => progressCalls == 1);
    expect(service.isCasting, isTrue);
  });

  test('播放启动宽限期结束后持续停止仍会断开', () async {
    api.onPoll = () async => _info(TransportState.stopped, 0);
    await service.loadSong(_song('first'));
    await _waitUntil(
      () => !service.isCasting,
      timeout: const Duration(seconds: 20),
    );
  });

  test('自动续播重置歌曲完成状态，每首只触发一次续播', () async {
    await service.loadSong(_song('first'));
    var completions = 0;
    Future<void>? pending;
    service.onCastCompleted = () {
      completions++;
      pending = service.loadSong(_song('next-$completions'));
    };
    api.onPoll = () async => _info(TransportState.playing, 200);
    for (var songIndex = 0; songIndex < 2; songIndex++) {
      await _waitUntil(() => completions == songIndex + 1);
      await pending;
      expect(service.isCasting, isTrue);
    }
    expect(api.titles, ['first', 'next-1', 'next-2']);
  });
}
