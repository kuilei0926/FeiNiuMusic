import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_cast_dlna/media_cast_dlna.dart';

import '../../state/settings_cast_state.dart';
import '../../state/song_state.dart';
import '../feiniu/api_client.dart';
import '../feiniu/transcode_service.dart';
import 'dlna_action_failure.dart';
import 'media_stream_proxy.dart';

/// DLNA 投屏状态。
enum DlnaCastState {
  /// 未投屏、未在搜索。
  idle,

  /// 正在搜索局域网设备。
  discovering,

  /// 已连接设备并投屏中（遥控模式）。
  casting,
}

/// DLNA 投屏服务（单例）。基于 [media_cast_dlna]（jUPnP）。
///
/// 职责：
/// - **发现**：SSDP 搜索局域网 DLNA 渲染器，维护设备列表与状态；
/// - **投屏**：把当前歌曲的音频流经 [MediaStreamProxy] 换签为匿名 URL 后
///   推送到目标设备（`setMediaUri` + `play`）；
/// - **遥控**：投屏期间 play/pause/seek/setVolume 转发到投屏设备；
/// - **断开**：停止投屏、停代理，回调让 [PlayerService] 恢复本机续播。
///
/// 音频流 Cookie 认证问题：飞牛流地址要 `Cookie: music-token`，渲染器发不了，
/// 故经本地代理注入认证头；默认转发原始流，确认加载失败后最多尝试一次
/// 服务器 MP3 HLS 转码（详见 [MediaStreamProxy] 与 [FeiNiuTranscodeService]）。
class DlnaCastService {
  DlnaCastService._()
    : _api = MediaCastDlnaApi(),
      _positionPollInterval = const Duration(seconds: 1),
      _playbackStartGrace = const Duration(seconds: 15);

  @visibleForTesting
  DlnaCastService.forTest({
    required MediaCastDlnaApi api,
    Duration positionPollInterval = const Duration(seconds: 1),
    Duration playbackStartGrace = const Duration(seconds: 15),
  }) : _api = api,
       _positionPollInterval = positionPollInterval,
       _playbackStartGrace = playbackStartGrace;

  static final DlnaCastService instance = DlnaCastService._();

  static void _log(String message) {
    // DebugLogService hooks debugPrint when diagnostics are enabled, including
    // release builds. Never include stream URLs or authentication headers here.
    debugPrint('[DlnaCastService] $message');
  }

  static String _safeError(Object error) =>
      DlnaActionFailure.from(error)?.diagnostic ??
      error.toString().replaceAll(RegExp(r'https?://[^\s]+'), '<url>');

  final MediaCastDlnaApi _api;
  final Duration _positionPollInterval;
  final Duration _playbackStartGrace;

  /// Android 原生音量键透传通道：投屏时原生层拦截物理音量键，回调
  /// `volumeDelta(+1/-1)`，这里遥控投屏设备音量；Dart 侧通过 `setActive`
  /// 通知原生层「投屏中，音量键应拦截」。
  static const MethodChannel _volumeChannel = MethodChannel(
    'com.feiniu.music/cast_volume',
  );
  bool _volumeHandlerRegistered = false;

  /// 当前投屏设备的音量（0-100，投屏遥控用）。-1 表示未知。
  int _castVolumeLevel = -1;
  static const int _volumeStep = 5;

  MediaCastDlnaDiscoveryEvents? _events;

  /// 最近一次发现的设备快照（按 UDN 去重）。
  final ValueNotifier<List<DlnaDevice>> devices = ValueNotifier(const []);

  /// 投屏状态（idle / discovering / casting）。
  final ValueNotifier<DlnaCastState> state = ValueNotifier(DlnaCastState.idle);

  /// 最近一次投送失败时可向用户展示的原因。
  String? lastCastError;

  /// 当前投屏目标设备。
  final ValueNotifier<DlnaDevice?> currentDevice = ValueNotifier(null);

  /// 投屏后由 [PlayerService] 注册：开始投屏时暂停本机、断开时恢复本机。
  void Function()? onCastStart;
  void Function()? onCastDisconnect;

  /// 投屏位置/状态轮询回调（由 [PlayerService] 注册，把投屏设备进度同步到
  /// 播放页 UI）。参数为（position, playing）。
  void Function(Duration position, bool playing)? onCastProgress;

  /// 投屏设备播完当前歌曲的回调（由 [PlayerService] 注册，推进逻辑队列并
  /// 推送下一首到投屏设备）。投屏设备播完本机引擎不会收到 completed 事件，
  /// 由位置轮询检测位置到达末尾后触发。
  void Function()? onCastCompleted;

  /// 投屏会话是否已建立。以「已连接设备」为准，不依赖 [state]——
  /// 投屏期间打开面板搜索其他设备会把 state 切到 discovering，但投屏会话
  /// 仍在继续，遥控逻辑必须保持生效。
  bool get isCasting => currentDevice.value != null;

  /// 是否正在发现设备。
  bool get isDiscovering => state.value == DlnaCastState.discovering;

  /// 设备列表（只读视图，供 UI 直接使用）。
  List<DlnaDevice> get knownDevices => devices.value;

  /// 投屏设备的播放位置（秒），供播放页进度条展示；投屏期间周期轮询。
  final ValueNotifier<Duration> castPosition = ValueNotifier(Duration.zero);

  /// 投屏设备的播放/暂停状态（供 UI 展示，不同于本机引擎状态）。
  final ValueNotifier<bool> castPlaying = ValueNotifier(false);

  Timer? _positionPollTimer;
  int _playbackRevision = 0;
  int _pollRevision = 0;
  bool _pollInFlight = false;
  Future<void> _mediaOperation = Future<void>.value();
  DateTime? _playbackStartDeadline;
  SongEntity? _castSong;
  bool _transcodeAttempted = false;
  bool _usingTranscode = false;
  bool _startupFallbackSuppressed = false;

  /// 上一帧轮询的投屏设备位置（秒）。用于播完检测（位置到达时长且不再前进）。
  int _lastPollPositionSeconds = -1;
  bool _castCompletedNotified = false;

  /// 当前投屏歌曲的预期时长（秒）。很多渲染器对 HLS 报 duration 为 0 或占位值，
  /// 用歌曲自身已知时长兜底做播完检测。
  int _castExpectedDurationSec = 0;

  /// 连续轮询失败次数。电视端退出/关机后渲染器可能完全不可达（getPlaybackInfo
  /// 抛异常），连续失败 N 次后视为投屏失效并断开（手机端不再显示投屏）。
  int _castPollFailures = 0;
  static const int _castPollFailureThreshold = 5;

  /// 连续观察到「stopped/noMediaPresent」的帧数。用户中途停止电视端时渲染器
  /// 会停在 stopped；但换源/缓冲等瞬态也可能出现 stopped 帧，连续 N 帧才
  /// 判定为用户停止并断开，避免误断。
  int _consecutiveStoppedFrames = 0;
  static const int _stopConfirmFrames = 3;

  StreamSubscription<DlnaDevice>? _foundSub;
  StreamSubscription<DeviceUdn>? _lostSub;
  StreamSubscription<DeviceUdn>? _offlineSub;
  bool _serviceInitialized = false;
  Future<void>? _initFuture;

  /// 初始化 jUPnP 服务（幂等）。失败时置 false 让下次重试。
  Future<void> _ensureInitialized() async {
    if (_serviceInitialized) return;
    final init = _initFuture ??= _doInit();
    try {
      await init;
    } finally {
      // 允许失败后重试
    }
  }

  Future<void> _doInit() async {
    try {
      await _api.initializeUpnpService();
      _serviceInitialized = true;
      _initFuture = null;
      _log('UPnP initialized');
    } catch (e) {
      _log('UPnP init failed: ${_safeError(e)}');
      _serviceInitialized = false;
      _initFuture = null;
      rethrow;
    }
  }

  /// 注册音量键透传通道处理器（幂等）。原生 onKeyDown 拦截音量键后回调
  /// `volumeDelta(+1/-1)`，这里把音量调节转发到投屏设备。
  void _ensureVolumeChannel() {
    if (_volumeHandlerRegistered) return;
    _volumeHandlerRegistered = true;
    _volumeChannel.setMethodCallHandler((call) async {
      if (call.method == 'volumeDelta') {
        final delta = (call.arguments as num?)?.toInt() ?? 0;
        if (delta != 0) {
          await _adjustCastVolume(delta);
        }
      }
      return null;
    });
  }

  /// 通知原生层「投屏中，物理音量键应拦截并回调」。投屏结束时置 false，
  /// 让音量键恢复控制本机媒体音量。
  Future<void> _setNativeVolumeCapture(bool active) async {
    if (!kIsWeb) {
      try {
        await _volumeChannel.invokeMethod('setActive', {'active': active});
      } catch (_) {
        // 非 Android 或通道不可用时静默忽略
      }
    }
  }

  /// 按步进调节投屏设备音量（音量键回调）。
  Future<void> _adjustCastVolume(int delta) async {
    final device = currentDevice.value;
    if (device == null) return;
    final step = delta * _volumeStep;
    if (_castVolumeLevel < 0) {
      // 尚未同步过设备音量：先查询一次
      try {
        final info = await _api.getVolumeInfo(device.udn);
        _castVolumeLevel = info.level.percentage;
      } catch (_) {
        return;
      }
    }
    final next = (_castVolumeLevel + step).clamp(0, 100);
    if (next == _castVolumeLevel) return;
    _castVolumeLevel = next;
    try {
      await _api.setVolume(device.udn, VolumeLevel(percentage: next));
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] volume adjust failed: $e');
    }
  }

  /// 订阅发现事件流（幂等）。首次调用时创建事件接收器。
  void _ensureEvents() {
    if (_events != null) return;
    final events = MediaCastDlnaDiscoveryEvents();
    _events = events;
    _foundSub = events.onDeviceFound.listen(_handleDeviceFound);
    _lostSub = events.onDeviceLost.listen(_handleDeviceLost);
    _offlineSub = events.onRendererOffline.listen(_handleRendererOffline);
  }

  /// 释放事件订阅与投屏会话（应用退出时调用）。
  Future<void> dispose() async {
    await disconnect(reason: null);
    _foundSub?.cancel();
    _lostSub?.cancel();
    _offlineSub?.cancel();
    _foundSub = null;
    _lostSub = null;
    _offlineSub = null;
    try {
      await _events?.dispose();
    } catch (_) {}
    _events = null;
    try {
      await _api.shutdownUpnpService();
    } catch (_) {}
  }

  void _handleDeviceFound(DlnaDevice device) {
    final list = List<DlnaDevice>.from(devices.value);
    final existing = list.indexWhere((d) => d.udn.value == device.udn.value);
    if (existing >= 0) {
      list[existing] = device;
    } else {
      list.add(device);
    }
    devices.value = List.unmodifiable(list);
    _log('device found name=${device.friendlyName}');
  }

  void _handleDeviceLost(DeviceUdn udn) {
    final list = List<DlnaDevice>.from(devices.value)
      ..removeWhere((d) => d.udn.value == udn.value);
    devices.value = List.unmodifiable(list);
    _log('device lost');
  }

  void _handleRendererOffline(DeviceUdn udn) {
    // 当前投屏设备掉线 → 自动断开并恢复本机
    final current = currentDevice.value;
    if (current != null && current.udn.value == udn.value) {
      unawaited(disconnect(reason: '投屏设备已离线'));
    }
  }

  /// 开始搜索局域网 DLNA 设备。总开关关闭时直接返回。
  Future<void> startDiscovery() async {
    if (!DlnaCastSettings.enabled.value) return;
    if (isDiscovering) return;
    try {
      await _ensureInitialized();
      _ensureEvents();
      state.value = DlnaCastState.discovering;
      await _api.startDiscovery(
        DiscoveryOptions(
          searchTarget: SearchTarget(
            target: 'urn:schemas-upnp-org:device:MediaRenderer:1',
          ),
          timeout: DiscoveryTimeout(seconds: 5),
        ),
      );
      _log('discovery started timeout=5s');
    } catch (e) {
      _log('discovery failed: ${_safeError(e)}');
      state.value = DlnaCastState.idle;
    }
  }

  /// 停止搜索（不中断已建立的投屏会话）。
  Future<void> stopDiscovery() async {
    if (state.value == DlnaCastState.idle) return;
    try {
      await _api.stopDiscovery();
    } catch (_) {}
    if (state.value == DlnaCastState.discovering) {
      state.value = DlnaCastState.idle;
    }
  }

  /// 选择一台设备并投屏当前歌曲。
  ///
  /// 若已在投屏则先断开旧设备（静默：不触发本机恢复，避免切设备时
  /// 本机短暂出声）。默认使用原始流，不受本机解码引擎或转码阈值影响；
  /// 明确的格式错误或确认启动失败时最多尝试一次服务器 MP3 HLS 转码。
  /// 统一经 [MediaStreamProxy] 换签为匿名 URL。
  Future<bool> castTo(DlnaDevice device, SongEntity song) async {
    lastCastError = null;
    if (!DlnaCastSettings.enabled.value) return false;
    var revision = ++_playbackRevision;
    bool isCurrent() => revision == _playbackRevision;
    try {
      await _ensureInitialized();
      if (!isCurrent()) return false;
      if (currentDevice.value != null) {
        final disconnectedRevision = revision + 1;
        await disconnect(reason: null, silent: true);
        if (_playbackRevision != disconnectedRevision) return false;
        revision = disconnectedRevision;
      }
      _stopPositionPoll();
      await _mediaOperation;
      if (!isCurrent()) return false;
      _prepareSong(song);
      _log(
        'cast requested device=${device.friendlyName} '
        'format=${(song.format ?? song.codec ?? 'unknown').toLowerCase()}',
      );
      // 每次投送重新选址，包含上次投送失败后遗留的代理会话。
      await MediaStreamProxy.instance.stop();
      if (!isCurrent()) return false;
      final String localAddress;
      try {
        localAddress = await MediaStreamProxy.resolveLocalAddress(
          device.ipAddress.value,
          // 插件透传 URL.port；HTTP 描述地址省略端口时其值为 -1。
          device.port.value == -1 ? 80 : device.port.value,
        );
      } catch (e) {
        if (!isCurrent()) return false;
        lastCastError = '无法确定到投屏设备的本机网络地址，请检查网络后重试';
        _log('route selection failed: ${_safeError(e)}');
        return false;
      }
      if (!isCurrent()) return false;
      final base = await MediaStreamProxy.instance.start(
        advertisedHost: localAddress,
      );
      if (!isCurrent()) return false;
      if (base == null) {
        lastCastError = '无法启动投屏媒体代理，请重试';
        _log('cast aborted: media proxy unavailable');
        return false;
      }
      final accepted = await _sendSong(song, device, isCurrent: isCurrent);
      if (!isCurrent()) return false;
      if (!accepted) {
        _log('cast aborted: no castable URL');
        await MediaStreamProxy.instance.stop();
        return false;
      }
      currentDevice.value = device;
      state.value = DlnaCastState.casting;
      castPosition.value = Duration.zero;
      castPlaying.value = true;
      _castVolumeLevel = -1; // 下次音量键先查询设备当前音量
      _castExpectedDurationSec =
          (song.durationMs != null && song.durationMs! > 0)
          ? (song.durationMs! / 1000).round()
          : 0;
      _lastPollPositionSeconds = -1;
      _castCompletedNotified = false;
      _castPollFailures = 0;
      _consecutiveStoppedFrames = 0;
      _startPositionPoll();
      _ensureVolumeChannel();
      unawaited(_setNativeVolumeCapture(true));
      onCastStart?.call();
      _log('play accepted device=${device.friendlyName}');
      return true;
    } catch (e) {
      if (!isCurrent()) return false;
      lastCastError =
          DlnaActionFailure.from(e)?.userMessage ?? '投屏加载失败，请检查设备和网络后重试';
      _log('cast failed: ${_safeError(e)}');
      await MediaStreamProxy.instance.stop();
      return false;
    }
  }

  /// 解析原始流或一次性备用转码流，经代理换签。
  Future<String?> _resolveCastUrl(
    SongEntity song, {
    required bool transcode,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return null;
    if (transcode) {
      final hls = await FeiNiuTranscodeService.instance.transcodeMp3UrlFor(
        song,
      );
      if (!isCurrent()) return null;
      if (hls != null) {
        _log('media route=transcoded-hls codec=mp3 extension=m3u8');
        return MediaStreamProxy.instance.registerMedia(
          hls,
          headers: FeiNiuApiClient.imageAuthHeaders(),
          fileExtension: 'm3u8',
        );
      }
      _log('media route=transcoded-hls unavailable; no further retry');
      lastCastError = '无法获取备用转码流，请尝试其他歌曲';
      return null;
    }
    final stream = FeiNiuApiClient.instance.streamUrl(song.id);
    final extension = _audioFileExtension(song);
    _log('media route=direct extension=$extension');
    return MediaStreamProxy.instance.registerMedia(
      stream,
      headers: FeiNiuApiClient.imageAuthHeaders(),
      fileExtension: extension,
    );
  }

  void _prepareSong(SongEntity song) {
    _castSong = song;
    _transcodeAttempted = false;
    _usingTranscode = false;
    _startupFallbackSuppressed = false;
    lastCastError = null;
  }

  Future<bool> _sendSong(
    SongEntity song,
    DlnaDevice device, {
    required bool Function() isCurrent,
    bool transcode = false,
  }) async {
    if (!isCurrent()) return false;
    if (transcode) _transcodeAttempted = true;
    final proxyUrl = await _resolveCastUrl(
      song,
      transcode: transcode,
      isCurrent: isCurrent,
    );
    if (!isCurrent() || proxyUrl == null) return false;
    final coverProxyUrl = await _resolveCastCover(song);
    if (!isCurrent()) return false;
    try {
      await _stopBeforeSetMediaUri(device);
      if (!isCurrent()) return false;
      await _api.setMediaUri(
        device.udn,
        Url(value: proxyUrl),
        AudioMetadata(
          title: song.title.trim().isEmpty ? '未知歌曲' : song.title.trim(),
          artist: song.artistDisplayName.trim().isEmpty
              ? null
              : song.artistDisplayName.trim(),
          album: song.albumDisplayName.trim().isEmpty
              ? null
              : song.albumDisplayName.trim(),
          albumArtUri: coverProxyUrl == null ? null : Url(value: coverProxyUrl),
          duration: song.durationMs != null && song.durationMs! > 0
              ? TimeDuration(seconds: (song.durationMs! / 1000).round())
              : null,
        ),
      );
      if (!isCurrent()) return false;
      await _api.play(device.udn);
      if (!isCurrent()) return false;
      _usingTranscode = transcode;
      _log('play accepted route=${transcode ? 'transcoded-hls' : 'direct'}');
      return true;
    } catch (error) {
      if (isCurrent()) {
        _log(
          'media command failed route=${transcode ? 'transcoded-hls' : 'direct'} ${_safeError(error)}',
        );
      }
      if (isCurrent() &&
          !transcode &&
          !_transcodeAttempted &&
          !_startupFallbackSuppressed &&
          _isFormatError(error)) {
        _log(
          'direct playback rejected: format unsupported; retry transcoded-hls',
        );
        return _sendSong(song, device, isCurrent: isCurrent, transcode: true);
      }
      rethrow;
    }
  }

  static bool _isFormatError(Object error) {
    final failure = DlnaActionFailure.from(error);
    if (failure != null) return failure.isFormatError;
    if (error is! PlatformException) return false;
    if (const {'704', '714'}.contains(error.code)) return true;
    final message = '${error.message ?? ''} ${error.details ?? ''}'
        .toLowerCase();
    return RegExp(
      r'unsupported (?:audio )?(?:format|codec|mime)|'
      r'(?:format|codec|mime[- ]?type) (?:is )?not supported|'
      r'illegal mime[- ]?type|(?:error(?: code)?|code)[:= ]+(?:704|714)\b',
    ).hasMatch(message);
  }

  /// 某些严格渲染器在 PLAYING/PAUSED 状态下拒绝 SetAVTransportURI（705）。
  /// 换源前 best-effort Stop；无媒体时部分设备会返回错误，忽略后继续换源。
  Future<void> _stopBeforeSetMediaUri(DlnaDevice device) async {
    try {
      await _api.stop(device.udn);
      _log('preflight stop completed');
      await Future<void>.delayed(const Duration(milliseconds: 150));
    } catch (e) {
      _log('preflight stop ignored: ${_safeError(e)}');
    }
  }

  static String _audioFileExtension(SongEntity song) {
    final raw = (song.format ?? song.codec ?? '').trim().toLowerCase();
    return switch (raw) {
      'mpeg' || 'mp3' => 'mp3',
      'm4a' || 'mp4a' => 'm4a',
      'aac' => 'aac',
      'flac' => 'flac',
      'wav' || 'wave' => 'wav',
      'ogg' || 'vorbis' => 'ogg',
      'opus' => 'opus',
      'wma' || 'wmav1' || 'wmav2' => 'wma',
      'alac' => 'm4a',
      'aiff' || 'aif' => 'aiff',
      _ => RegExp(r'^[a-z0-9]{1,8}$').hasMatch(raw) ? raw : 'bin',
    };
  }

  /// 解析歌曲封面图经代理换签的匿名 URL（DLNA 渲染器直接拉取展示）。
  /// 封面 URL 同样需要 Cookie 认证，故经代理注入。无封面返回 null。
  Future<String?> _resolveCastCover(SongEntity song) async {
    final coverId = song.coverId;
    if (coverId == null || coverId.isEmpty) return null;
    final coverUrl = FeiNiuApiClient.instance.coverUrl(
      coverId,
      size: FeiNiuApiClient.coverRequestSize,
    );
    return MediaStreamProxy.instance.registerResource(
      coverUrl,
      headers: FeiNiuApiClient.imageAuthHeaders(),
    );
  }

  // ---- 遥控 ----

  Future<void> play() async {
    final device = currentDevice.value;
    if (device == null) return;
    try {
      await _api.play(device.udn);
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] play failed: $e');
    }
  }

  Future<void> pause() async {
    final device = currentDevice.value;
    if (device == null) return;
    _startupFallbackSuppressed = true;
    try {
      await _api.pause(device.udn);
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] pause failed: $e');
    }
  }

  Future<void> stop() async {
    final device = currentDevice.value;
    if (device == null) return;
    _startupFallbackSuppressed = true;
    try {
      await _api.stop(device.udn);
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] stop failed: $e');
    }
  }

  Future<void> seek(Duration position) async {
    final device = currentDevice.value;
    if (device == null) return;
    try {
      await _api.seek(device.udn, TimePosition(seconds: position.inSeconds));
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] seek failed: $e');
    }
  }

  /// 设置投屏设备音量（0.0–1.0）。
  Future<void> setVolume(double volume) async {
    final device = currentDevice.value;
    if (device == null) return;
    try {
      await _api.setVolume(
        device.udn,
        VolumeLevel(percentage: (volume.clamp(0.0, 1.0) * 100).round()),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] setVolume failed: $e');
    }
  }

  /// 在投屏设备上切换歌曲（换一条媒体流继续播）。
  Future<void> loadSong(SongEntity song) {
    final device = currentDevice.value;
    if (device == null) return Future<void>.value();
    _prepareSong(song);
    return _queueSong(song, device);
  }

  Future<void> _queueSong(
    SongEntity song,
    DlnaDevice device, {
    bool transcode = false,
  }) {
    final revision = ++_playbackRevision;
    _stopPositionPoll();
    if (transcode) _transcodeAttempted = true;
    final operation = _mediaOperation.then(
      (_) => _loadSong(song, device, revision, transcode: transcode),
    );
    _mediaOperation = operation;
    return operation;
  }

  Future<void> _loadSong(
    SongEntity song,
    DlnaDevice device,
    int revision, {
    required bool transcode,
  }) async {
    bool isCurrent() =>
        revision == _playbackRevision && currentDevice.value == device;
    if (!isCurrent()) return;
    try {
      MediaStreamProxy.instance.unregisterResources();
      final accepted = await _sendSong(
        song,
        device,
        isCurrent: isCurrent,
        transcode: transcode,
      );
      if (!isCurrent()) return;
      if (!accepted) {
        unawaited(disconnect(reason: lastCastError));
        return;
      }
      // 更新投屏歌曲预期时长与播完检测状态
      _castExpectedDurationSec =
          (song.durationMs != null && song.durationMs! > 0)
          ? (song.durationMs! / 1000).round()
          : 0;
      _lastPollPositionSeconds = -1;
      _castCompletedNotified = false;
      _castPollFailures = 0;
      _consecutiveStoppedFrames = 0;
      castPosition.value = Duration.zero;
      castPlaying.value = true;
    } catch (e) {
      if (isCurrent()) {
        lastCastError =
            DlnaActionFailure.from(e)?.userMessage ?? '投屏加载失败，请检查设备和网络后重试';
        _log('loadSong failed: ${_safeError(e)}; no further retry');
        unawaited(disconnect(reason: lastCastError));
      }
    } finally {
      if (isCurrent()) _startPositionPoll();
    }
  }

  /// 断开投屏：停止设备播放、停代理、恢复本机播放。
  ///
  /// [reason] 非空时向 UI 提示（设备离线等）。[silent] 为 true 时不触发
  /// `onCastDisconnect`（切换投屏设备时用，避免本机短暂恢复出声）。
  Future<void> disconnect({String? reason, bool silent = false}) async {
    final wasCasting = isCasting;
    final device = currentDevice.value;
    final revision = ++_playbackRevision;
    _stopPositionPoll();
    _castSong = null;
    _startupFallbackSuppressed = true;
    final discoveryStop = stopDiscovery();
    currentDevice.value = null;
    castPosition.value = Duration.zero;
    castPlaying.value = false;
    _castVolumeLevel = -1;
    _castExpectedDurationSec = 0;
    _lastPollPositionSeconds = -1;
    _castCompletedNotified = false;
    _castPollFailures = 0;
    _consecutiveStoppedFrames = 0;
    unawaited(_setNativeVolumeCapture(false));
    await discoveryStop;
    await _mediaOperation;
    if (revision != _playbackRevision) return;
    try {
      if (device != null) await _api.stop(device.udn);
    } catch (_) {}
    if (revision != _playbackRevision) return;
    state.value = DlnaCastState.idle;
    await MediaStreamProxy.instance.stop();
    if (revision != _playbackRevision) return;
    if (wasCasting && !silent) {
      onCastDisconnect?.call();
      if (reason != null && kDebugMode) {
        debugPrint('[DlnaCastService] disconnected: $reason');
      }
    }
  }

  /// 投屏期间周期轮询设备播放位置与状态，驱动播放页进度条。
  ///
  /// 同时承担**播完/停止检测**——投屏是本机推单曲，渲染器播完会停住或归零，
  /// 本机引擎不在播（无 completed 事件），只能靠轮询感知：
  /// - 位置连续两帧到达末尾 → 播完 → 续播下一首；
  /// - 位置从接近末尾骤降到 0 附近 → 渲染器播完归零 → 续播下一首；
  /// - 渲染器 `stopped`/`noMediaPresent` 且上次位置接近末尾 → 自然播完 → 续播；
  /// - 渲染器 `stopped`/`noMediaPresent` 且上次位置在歌曲中途 → 用户停止/退出
  ///   → 断开投屏（手机端不再显示投屏）。
  void _startPositionPoll() {
    _stopPositionPoll();
    final revision = _pollRevision;
    final device = currentDevice.value;
    if (device == null) return;
    _playbackStartDeadline = DateTime.now().add(_playbackStartGrace);
    bool isCurrent() =>
        revision == _pollRevision && currentDevice.value == device;
    _positionPollTimer = Timer.periodic(_positionPollInterval, (_) async {
      if (!isCurrent() || _pollInFlight) return;
      _pollInFlight = true;
      try {
        final info = await _api
            .getPlaybackInfo(device.udn)
            .timeout(const Duration(seconds: 6));
        if (!isCurrent()) return;
        _castPollFailures = 0;
        final posSec = info.position.seconds;
        // 渲染器对 HLS 常报 duration=0/占位，退化为歌曲自身已知时长。
        final effectiveDur = info.duration.seconds > 0
            ? info.duration.seconds
            : _castExpectedDurationSec;

        castPosition.value = Duration(seconds: posSec);
        switch (info.state) {
          case TransportState.playing:
            if (_playbackStartDeadline != null) {
              _log(
                'playback confirmed route=${_usingTranscode ? 'transcoded-hls' : 'direct'}',
              );
            }
            _playbackStartDeadline = null;
            castPlaying.value = true;
          case TransportState.paused:
            _playbackStartDeadline = null;
            castPlaying.value = false;
          case TransportState.stopped:
          case TransportState.transitioning:
          case TransportState.noMediaPresent:
            // 状态具体含义在下方播完/停止检测里处理
            break;
        }
        onCastProgress?.call(castPosition.value, castPlaying.value);
        if (!isCurrent()) return;

        if (_playbackStartDeadline != null &&
            DateTime.now().isBefore(_playbackStartDeadline!) &&
            (info.state == TransportState.stopped ||
                info.state == TransportState.noMediaPresent ||
                info.state == TransportState.transitioning)) {
          return;
        }

        final prevPos = _lastPollPositionSeconds;
        _lastPollPositionSeconds = posSec;

        // ---- 播完 / 停止检测 ----
        final reachedEnd = effectiveDur > 0 && posSec >= effectiveDur;
        final wasNearEnd = effectiveDur > 0 && prevPos >= effectiveDur * 0.9;

        var completed = false;
        if (reachedEnd) {
          // 1) 位置连续两帧到达末尾 → 播完
          if (!_castCompletedNotified && prevPos >= effectiveDur) {
            completed = true;
          }
        } else if (posSec <= 5 &&
            wasNearEnd &&
            prevPos > posSec + 30 &&
            effectiveDur > 0) {
          // 2) 位置从接近末尾骤降到 0 附近 → 渲染器播完归零
          completed = true;
        } else if (info.state == TransportState.stopped ||
            info.state == TransportState.noMediaPresent) {
          // 3) 渲染器停止/无媒体：
          //    - 上次位置接近末尾 → 自然播完 → 续播下一首；
          //    - 上次位置中途 → 用户停止/退出电视端 → 连续 N 帧确认后断开
          //      （换源/缓冲等瞬态 stopped 帧不误断）。
          if (wasNearEnd && prevPos >= 0) {
            completed = true;
          } else if (prevPos >= 0) {
            _consecutiveStoppedFrames++;
            if (_consecutiveStoppedFrames >= _stopConfirmFrames) {
              final song = _castSong;
              if (_playbackStartDeadline != null &&
                  !_startupFallbackSuppressed &&
                  !_transcodeAttempted &&
                  song != null &&
                  MediaStreamProxy.instance.hasMediaData &&
                  !MediaStreamProxy.instance.hasMediaFailure) {
                _log(
                  'direct playback failed to start after media delivery; retry transcoded-hls',
                );
                unawaited(_queueSong(song, device, transcode: true));
                return;
              }
              _log(
                'playback stopped route=${_usingTranscode ? 'transcoded-hls' : 'direct'} '
                'started=${_playbackStartDeadline == null} '
                'mediaData=${MediaStreamProxy.instance.hasMediaData} '
                'mediaFailure=${MediaStreamProxy.instance.hasMediaFailure}',
              );
              _handleCastStopped();
              return;
            }
          } else {
            _consecutiveStoppedFrames = 0;
          }
        }

        // 非 stopped 状态帧清零连续停止计数
        if (info.state != TransportState.stopped &&
            info.state != TransportState.noMediaPresent) {
          _consecutiveStoppedFrames = 0;
        }

        if (completed) {
          if (!_castCompletedNotified) {
            _castCompletedNotified = true;
            onCastCompleted?.call();
          }
        } else {
          _castCompletedNotified = false;
        }
      } catch (e) {
        if (!isCurrent()) return;
        // 轮询失败（设备短暂不可达）。连续失败超过阈值视为电视端退出/关机，
        // 断开投屏让手机端回到本机播放。
        _castPollFailures++;
        if (_castPollFailures == 1) {
          _log('playback polling failed: ${_safeError(e)}');
        }
        if (_castPollFailures >= _castPollFailureThreshold) {
          _log(
            'renderer unreachable after $_castPollFailures polls; disconnect',
          );
          unawaited(disconnect(reason: null));
        }
      } finally {
        _pollInFlight = false;
      }
    });
  }

  /// 渲染器在歌曲中途停止（用户停止/退出电视端）→ 断开投屏。
  /// 触发 `onCastDisconnect` 恢复本机、清 `isCasting`，手机端不再显示投屏。
  void _handleCastStopped() {
    _log('renderer stopped mid-song');
    unawaited(disconnect(reason: null));
  }

  void _stopPositionPoll() {
    _pollRevision++;
    _positionPollTimer?.cancel();
    _positionPollTimer = null;
  }
}
