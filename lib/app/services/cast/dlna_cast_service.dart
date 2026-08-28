import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_cast_dlna/media_cast_dlna.dart';

import '../../state/settings_cast_state.dart';
import '../../state/song_state.dart';
import '../feiniu/api_client.dart';
import '../feiniu/transcode_service.dart';
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
/// 故经本地代理注入认证头；无损/高码率格式优先走服务器转码的 MP3 HLS，
/// 保证渲染器可解码（详见 [MediaStreamProxy] 与 [FeiNiuTranscodeService]）。
class DlnaCastService {
  DlnaCastService._();

  static final DlnaCastService instance = DlnaCastService._();

  final MediaCastDlnaApi _api = MediaCastDlnaApi();

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
  final ValueNotifier<DlnaCastState> state =
      ValueNotifier(DlnaCastState.idle);

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
      if (kDebugMode) debugPrint('[DlnaCastService] UPnP initialized');
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] UPnP init failed: $e');
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
  }

  void _handleDeviceLost(DeviceUdn udn) {
    final list = List<DlnaDevice>.from(devices.value)
      ..removeWhere((d) => d.udn.value == udn.value);
    devices.value = List.unmodifiable(list);
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
      if (kDebugMode) {
        debugPrint('[DlnaCastService] discovery started');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DlnaCastService] startDiscovery failed: $e');
      }
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
  /// 本机短暂出声）。播放 URL 解析规则：
  /// - 需转码 / media_kit 专属格式（DSF/APE/WMA/FLAC 帧超限…）→ 优先转码 MP3
  ///   HLS（渲染器可解码）；失败退直连；
  /// - 其余（MP3/AAC/…）→ 直连流。
  /// 统一经 [MediaStreamProxy] 换签为匿名 URL。
  Future<bool> castTo(
    DlnaDevice device,
    SongEntity song,
  ) async {
    if (!DlnaCastSettings.enabled.value) return false;
    try {
      await _ensureInitialized();
      if (currentDevice.value != null) {
        await disconnect(reason: null, silent: true);
      }
      final proxyUrl = await _resolveCastUrl(song);
      if (proxyUrl == null) {
        if (kDebugMode) {
          debugPrint('[DlnaCastService] no castable url for ${song.title}');
        }
        return false;
      }
      // 封面图经代理换签为匿名 URL（渲染器直接拉取展示）
      final coverProxyUrl = await _resolveCastCover(song);

      final metadata = AudioMetadata(
        title: song.title.trim().isEmpty ? '未知歌曲' : song.title.trim(),
        artist: song.artistDisplayName.trim().isEmpty
            ? null
            : song.artistDisplayName.trim(),
        album: song.albumDisplayName.trim().isEmpty
            ? null
            : song.albumDisplayName.trim(),
        albumArtUri: coverProxyUrl == null
            ? null
            : Url(value: coverProxyUrl),
        duration: song.durationMs != null && song.durationMs! > 0
            ? TimeDuration(seconds: (song.durationMs! / 1000).round())
            : null,
      );

      await _api.setMediaUri(
        device.udn,
        Url(value: proxyUrl),
        metadata,
      );
      await _api.play(device.udn);

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
      if (kDebugMode) {
        debugPrint('[DlnaCastService] cast ${song.title} -> ${device.friendlyName}');
      }
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] castTo failed: $e');
      return false;
    }
  }

  /// 解析可投屏的音频地址（转码 MP3 HLS 优先 / 直连兜底），经代理换签。
  Future<String?> _resolveCastUrl(SongEntity song) async {
    // 1) 需转码（DSF/APE/WMA… 或超过阈值的大文件）→ 转码 MP3 HLS
    //    （渲染器通用性最好）。失败则回退直连。
    final needsTranscode =
        FeiNiuTranscodeService.isMediaKitFormat(song.format ?? '') ||
        await FeiNiuTranscodeService.instance.shouldTranscode(
          song,
          respectWifiPolicy: false,
        );
    if (needsTranscode) {
      final hls = await FeiNiuTranscodeService.instance.transcodeMp3UrlFor(
        song,
      );
      if (hls != null) {
        return MediaStreamProxy.instance.registerMedia(
          hls,
          headers: FeiNiuApiClient.imageAuthHeaders(),
        );
      }
    }

    // 2) 直连流兜底。
    final stream = FeiNiuApiClient.instance.streamUrl(song.id);
    return MediaStreamProxy.instance.registerMedia(
      stream,
      headers: FeiNiuApiClient.imageAuthHeaders(),
    );
  }

  /// 解析歌曲封面图经代理换签的匿名 URL（DLNA 渲染器直接拉取展示）。
  /// 封面 URL 同样需要 Cookie 认证，故经代理注入。无封面返回 null。
  Future<String?> _resolveCastCover(SongEntity song) async {
    final coverId = song.coverId;
    if (coverId == null || coverId.isEmpty) return null;
    final coverUrl = FeiNiuApiClient.instance.coverUrl(coverId, size: FeiNiuApiClient.coverRequestSize);
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
    try {
      await _api.pause(device.udn);
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] pause failed: $e');
    }
  }

  Future<void> stop() async {
    final device = currentDevice.value;
    if (device == null) return;
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
      await _api.seek(
        device.udn,
        TimePosition(seconds: position.inSeconds),
      );
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
  Future<void> loadSong(SongEntity song) async {
    final device = currentDevice.value;
    if (device == null) return;
    // 上一首的封面资源已不再需要，先清空避免泄漏（媒体流走 registerMedia，
    // 不受 _resources 影响）。
    MediaStreamProxy.instance.unregisterResources();
    final proxyUrl = await _resolveCastUrl(song);
    if (proxyUrl == null) return;
    final coverProxyUrl = await _resolveCastCover(song);
    try {
      await _api.setMediaUri(
        device.udn,
        Url(value: proxyUrl),
        AudioMetadata(
          title: song.title.trim().isEmpty ? '未知歌曲' : song.title.trim(),
          artist: song.artistDisplayName.trim().isEmpty
              ? null
              : song.artistDisplayName.trim(),
          albumArtUri: coverProxyUrl == null
              ? null
              : Url(value: coverProxyUrl),
        ),
      );
      await _api.play(device.udn);
      // 更新投屏歌曲预期时长与播完检测状态
      _castExpectedDurationSec =
          (song.durationMs != null && song.durationMs! > 0)
          ? (song.durationMs! / 1000).round()
          : 0;
      _lastPollPositionSeconds = -1;
      _castCompletedNotified = false;
      _castPollFailures = 0;
      castPosition.value = Duration.zero;
    } catch (e) {
      if (kDebugMode) debugPrint('[DlnaCastService] loadSong failed: $e');
    }
  }

  /// 断开投屏：停止设备播放、停代理、恢复本机播放。
  ///
  /// [reason] 非空时向 UI 提示（设备离线等）。[silent] 为 true 时不触发
  /// `onCastDisconnect`（切换投屏设备时用，避免本机短暂恢复出声）。
  Future<void> disconnect({String? reason, bool silent = false}) async {
    final wasCasting = isCasting;
    await stopDiscovery();
    _stopPositionPoll();
    castPosition.value = Duration.zero;
    castPlaying.value = false;
    _castVolumeLevel = -1;
    _castExpectedDurationSec = 0;
    _lastPollPositionSeconds = -1;
    _castCompletedNotified = false;
    _castPollFailures = 0;
    _consecutiveStoppedFrames = 0;
    unawaited(_setNativeVolumeCapture(false));
    try {
      await stop();
    } catch (_) {}
    currentDevice.value = null;
    state.value = DlnaCastState.idle;
    MediaStreamProxy.instance.stop();
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
    _positionPollTimer?.cancel();
    _positionPollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final device = currentDevice.value;
      if (device == null) return;
      try {
        final info = await _api.getPlaybackInfo(device.udn);
        if (currentDevice.value == null) return; // 已断开
        final posSec = info.position.seconds;
        // 渲染器对 HLS 常报 duration=0/占位，退化为歌曲自身已知时长。
        final effectiveDur = info.duration.seconds > 0
            ? info.duration.seconds
            : _castExpectedDurationSec;

        castPosition.value = Duration(seconds: posSec);
        switch (info.state) {
          case TransportState.playing:
            castPlaying.value = true;
          case TransportState.paused:
            castPlaying.value = false;
          case TransportState.stopped:
          case TransportState.transitioning:
          case TransportState.noMediaPresent:
            // 状态具体含义在下方播完/停止检测里处理
            break;
        }
        onCastProgress?.call(castPosition.value, castPlaying.value);

        final prevPos = _lastPollPositionSeconds;
        _lastPollPositionSeconds = posSec;

        // ---- 播完 / 停止检测 ----
        final reachedEnd = effectiveDur > 0 && posSec >= effectiveDur;
        final wasNearEnd =
            effectiveDur > 0 && prevPos >= effectiveDur * 0.9;

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
        // 轮询成功：重置连续失败计数
        _castPollFailures = 0;
      } catch (_) {
        // 轮询失败（设备短暂不可达）。连续失败超过阈值视为电视端退出/关机，
        // 断开投屏让手机端回到本机播放。
        _castPollFailures++;
        if (_castPollFailures >= _castPollFailureThreshold) {
          if (kDebugMode) {
            debugPrint(
              '[DlnaCastService] renderer unreachable after '
              '$_castPollFailures polls -> disconnect',
            );
          }
          unawaited(disconnect(reason: null));
        }
      }
    });
  }

  /// 渲染器在歌曲中途停止（用户停止/退出电视端）→ 断开投屏。
  /// 触发 `onCastDisconnect` 恢复本机、清 `isCasting`，手机端不再显示投屏。
  void _handleCastStopped() {
    if (kDebugMode) debugPrint('[DlnaCastService] renderer stopped mid-song');
    unawaited(disconnect(reason: null));
  }

  void _stopPositionPoll() {
    _positionPollTimer?.cancel();
    _positionPollTimer = null;
  }
}
