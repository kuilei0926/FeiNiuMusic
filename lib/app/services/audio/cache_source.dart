// ignore_for_file: experimental_member_use
// just_audio 的 StreamAudioSource/StreamAudioResponse 为实验性 API，
// 自研缓存源必须扩展它，此警告无法避免，文件级抑制。

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:just_audio/just_audio.dart';

/// 自研音频流缓存源 —— 扩展 [StreamAudioSource]
///
/// 播放/预缓存时把远端音频流完整下载到本地文件，同时在下载过程中服务 just_audio
/// 的字节区间请求：
/// - **已缓存区域命中** → 直接从本地文件 [openRead] 秒播，不重新下载；
/// - 部分覆盖 → 本地已缓存部分 + 进行中下载流拼接；
/// - 超出当前已下载进度 → 另发上游 `Range:` 请求（服务器支持 206）。
///
/// 设计镜像 just_audio 内置 `LockCachingAudioSource`（just_audio.dart:3373-3689）的
/// 成熟下载循环，但接收具体缓存文件、暴露 [precache] 入口、以 [downloadDone] 报告完成，
/// 便于缓存管理服务做链式预缓存与上限淘汰。
///
/// 一个缓存文件只有一个下载循环（[StreamCacheService] 注册表保证每首歌共享同一实例）；
/// 循环由首次 [request] 或 [precache] 触发，期间所有并发字节请求由同一循环服务。
class StreamAudioCacheSource extends StreamAudioSource {
  final String songId;

  /// 流 URL（无 token 参数，cookie 认证）
  final Uri uri;

  /// 认证请求头（FeiNiuApiClient.imageAuthHeaders()）
  final Map<String, String> headers;

  /// 下载完成后的最终文件
  final File cacheFile;

  /// 下载中的临时文件（下载成功后被原子改名成 [cacheFile]）
  final File partFile;

  /// 记录原始 Content-Type 的旁路文件
  final File mimeFile;

  final List<_ByteRangeRequest> _requests = [];
  final List<_InProgressCacheResponse> _inProgressResponses = [];
  final Completer<void> _downloadCompleter = Completer<void>();

  Future<void>? _downloadFuture;
  int _progress = 0;
  int? _sourceLength;
  String _contentType = 'audio/mpeg';
  bool _downloading = false;
  bool _completed = false;

  StreamAudioCacheSource({
    required this.songId,
    required this.uri,
    required this.headers,
    required this.cacheFile,
    super.tag,
  })  : partFile = File('${cacheFile.path}.part'),
        mimeFile = File('${cacheFile.path}.mime');

  bool get isDownloading => _downloading;
  bool get isComplete => _completed || cacheFile.existsSync();

  /// 下载完成信号（成功或失败都会完成；失败时 Future 带错误）
  Future<void> get downloadDone => _downloadCompleter.future;

  /// 触发下载并等待完成 —— 供预缓存调用。
  /// 若播放器已在下载同一首歌，则 join 同一循环；文件已完整则立即返回。
  Future<void> precache() async {
    if (isComplete) return;
    _ensureDownload();
    await _downloadCompleter.future;
  }

  void _ensureDownload() {
    _downloadFuture ??= _runDownload();
  }

  Future<void> _runDownload() async {
    _downloading = true;
    try {
      await _downloadToFile();
    } catch (e, st) {
      // 下载失败：清理临时文件、fail 所有在途请求、报告失败并允许重试
      try {
        if (partFile.existsSync()) partFile.deleteSync();
      } catch (_) {}
      for (final req in _requests) {
        req.fail(e, st);
      }
      _requests.clear();
      if (!_downloadCompleter.isCompleted) {
        _downloadCompleter.completeError(e, st);
      }
      _downloadFuture = null; // 允许后续重试
    } finally {
      _downloading = false;
    }
  }

  /// 单一顺序下载循环：完整 GET 流式写 `.part`，同时服务所有在途字节请求。
  Future<void> _downloadToFile() async {
    final client = _createHttpClient();
    try {
      final httpRequest = await client.getUrl(uri);
      for (final entry in headers.entries) {
        httpRequest.headers.set(entry.key, entry.value);
      }
      final response = await httpRequest.close();
      if (response.statusCode != 200) {
        throw Exception('HTTP Status Error: ${response.statusCode}');
      }
      partFile.createSync(recursive: true);
      final sink = partFile.openWrite();
      _sourceLength = response.contentLength == -1 ? null : response.contentLength;
      _contentType = response.headers.contentType.toString();
      await mimeFile.writeAsString(_contentType);
      _progress = 0;

      await for (final data in response) {
        _progress += data.length;
        sink.add(data);

        // 先把本次数据喂给已建立的进行中响应
        for (var cacheResponse in _inProgressResponses) {
          final end = cacheResponse.end;
          if (end != null && _progress >= end) {
            final subEnd =
                min(data.length, max(0, data.length - (_progress - end)));
            cacheResponse.controller.add(data.sublist(0, subEnd));
            cacheResponse.controller.close();
          } else {
            cacheResponse.controller.add(data);
          }
        }
        _inProgressResponses
            .removeWhere((element) => element.controller.isClosed);

        if (_requests.isEmpty) continue;

        // 请求已覆盖范围前的数据必须已落盘，openRead 才能读到
        await sink.flush();

        final readyRequests = _requests
            .where((r) => r.start == null || r.start! < _progress)
            .toList();
        final notReadyRequests = _requests
            .where((r) => r.start != null && r.start! >= _progress)
            .toList();

        for (final request in readyRequests) {
          _requests.remove(request);
          final effectiveStart = request.start ?? 0;
          final effectiveEnd = request.end ?? _sourceLength;
          Stream<List<int>> responseStream;
          if (effectiveEnd != null && effectiveEnd <= _progress) {
            // 完全在已缓存区域 → 本地文件读取（秒播）
            responseStream = partFile.openRead(effectiveStart, effectiveEnd);
          } else {
            // 部分覆盖 → 已缓存部分 + 进行中下载流拼接
            final cacheResponse =
                _InProgressCacheResponse(end: effectiveEnd);
            _inProgressResponses.add(cacheResponse);
            responseStream = _concatStreams([
              partFile.openRead(effectiveStart, _progress),
              cacheResponse.controller.stream,
            ]);
          }
          request.complete(StreamAudioResponse(
            rangeRequestsSupported: true,
            sourceLength: request.start != null ? _sourceLength : null,
            contentLength:
                effectiveEnd != null ? effectiveEnd - effectiveStart : null,
            offset: request.start,
            contentType: _contentType,
            stream: responseStream.asBroadcastStream(),
          ));
        }

        for (final request in notReadyRequests) {
          _requests.remove(request);
          final start = request.start!;
          final end = request.end ?? _sourceLength;
          unawaited(_issueRangeRequest(request, start, end));
        }
      }

      // 下载完成：关闭进行中响应、原子改名、报告完成
      for (var cacheResponse in _inProgressResponses) {
        if (!cacheResponse.controller.isClosed) {
          cacheResponse.controller.close();
        }
      }
      _inProgressResponses.clear();
      await sink.close();
      partFile.renameSync(cacheFile.path);
      _completed = true;
      if (!_downloadCompleter.isCompleted) {
        _downloadCompleter.complete();
      }
    } finally {
      client.close(force: true);
    }
  }

  /// 超出当前下载进度的区间请求：另发上游 `Range:` 请求（服务器支持 206）。
  Future<void> _issueRangeRequest(
    _ByteRangeRequest request,
    int start,
    int? end,
  ) async {
    final client = _createHttpClient();
    try {
      final httpRequest = await client.getUrl(uri);
      for (final entry in headers.entries) {
        httpRequest.headers.set(entry.key, entry.value);
      }
      httpRequest.headers.set(
        HttpHeaders.rangeHeader,
        end != null ? 'bytes=$start-${end - 1}' : 'bytes=$start-',
      );
      final response = await httpRequest.close();
      if (response.statusCode != 206) {
        throw Exception('HTTP Status Error: ${response.statusCode}');
      }
      request.complete(StreamAudioResponse(
        rangeRequestsSupported: true,
        sourceLength: _sourceLength,
        contentLength: end != null ? end - start : null,
        offset: start,
        contentType: _contentType,
        stream: response.asBroadcastStream(),
      ));
    } catch (e, st) {
      request.fail(e, st);
    } finally {
      client.close(force: true);
    }
  }

  HttpClient _createHttpClient() {
    // 继承 main.dart 的 HttpOverrides.global（SSL 忽略开关全局生效）
    final client = HttpClient();
    // 不自动解压，保证缓存字节与线上字节一致，sourceLength/contentLength 与文件相符
    client.autoUncompress = false;
    return client;
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    // 缓存文件已完整 → 直接从本地文件服务（秒播，无网络）
    if (cacheFile.existsSync()) {
      final length = cacheFile.lengthSync();
      return StreamAudioResponse(
        rangeRequestsSupported: true,
        sourceLength: start != null ? length : null,
        contentLength: (end ?? length) - (start ?? 0),
        offset: start,
        contentType: _readCachedMime(),
        stream: cacheFile.openRead(start, end).asBroadcastStream(),
      );
    }

    final req = _ByteRangeRequest(start, end);
    _requests.add(req);
    _ensureDownload();
    final resp = await req.future;
    // 保持一个监听者使广播流保持活跃；流出错时 fail 在途请求避免悬挂
    resp.stream.listen((_) {}, onError: (Object e, StackTrace st) {
      for (final r in _requests) {
        r.fail(e, st);
      }
    });
    return resp;
  }

  String _readCachedMime() {
    try {
      if (mimeFile.existsSync()) return mimeFile.readAsStringSync();
    } catch (_) {}
    return 'audio/mpeg';
  }

  /// 本地实现 `Rx.concatEager` 语义（避免引入 rxdart 依赖）
  static Stream<List<int>> _concatStreams(
    List<Stream<List<int>>> streams,
  ) async* {
    for (final stream in streams) {
      yield* stream;
    }
  }
}

/// 一次字节区间请求（completer + fail 防重）
class _ByteRangeRequest {
  final int? start;
  final int? end;
  final Completer<StreamAudioResponse> completer =
      Completer<StreamAudioResponse>();

  _ByteRangeRequest(this.start, this.end);

  Future<StreamAudioResponse> get future => completer.future;

  void complete(StreamAudioResponse response) {
    if (!completer.isCompleted) completer.complete(response);
  }

  void fail(Object error, StackTrace? stackTrace) {
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace ?? StackTrace.current);
    }
  }
}

/// 部分覆盖请求的进行中下载缓冲（缓存读到 [_InProgressCacheResponse.end] 为止）
class _InProgressCacheResponse {
  final StreamController<List<int>> controller = StreamController<List<int>>();
  final int? end;

  _InProgressCacheResponse({this.end});
}
