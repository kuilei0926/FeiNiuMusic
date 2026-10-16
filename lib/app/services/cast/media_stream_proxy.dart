import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// 本地 HTTP 代理：把需要 Cookie 认证的飞牛音频流转成 DLNA 渲染器可直连的匿名 URL。
///
/// 飞牛音频流（`/track/stream`、转码 HLS）都要携带 `Cookie: music-token=...`
/// （+ 中继 `mode=relay`、安全码）才能访问，而 DLNA 渲染器无法发送自定义
/// Cookie。因此本机起一个临时 HTTP 服务，把流 URL「换签」为
/// `http://<本机LAN IP>:<port>/m/<token>...`：
///
/// - 渲染器请求该地址时，代理携带认证头转发到上游；
/// - 上游是 HLS m3u8 时，代理把其中相对分片地址改写成经本代理的绝对地址
///   （渲染器才能拉到分片）；
/// - Range 请求（拖动进度）原样透传。
///
/// 用随机端口（0）启动，与 `LoginPairServer`（同为端口 0）天然并存。
class MediaStreamProxy {
  MediaStreamProxy._();

  static final MediaStreamProxy instance = MediaStreamProxy._();

  static const int _maxRedirects = 5;

  static void _log(String message) {
    // DebugLogService hooks debugPrint when the user enables diagnostics, so
    // these messages remain exportable in release builds as well.
    debugPrint('[MediaStreamProxy] $message');
  }

  static String _safeError(Object error) =>
      error.toString().replaceAll(RegExp(r'https?://[^\s]+'), '<url>');

  HttpServer? _server;
  String? _token;
  String _proxyBase = '';
  String _upstreamUrl = '';
  Map<String, String> _upstreamHeaders = const {};

  /// 额外资源注册表（封面图等）：token → 上游地址 + 认证头。
  /// 与主媒体流分离：主媒体流经 `/m/<token>`，资源经 `/r/<resourceToken>`。
  final Map<String, ({String url, Map<String, String> headers})> _resources =
      {};

  bool get isRunning => _server != null;

  String? get token => _token;

  String? get proxyBase => _proxyBase.isEmpty ? null : _proxyBase;

  /// 当前代理是否已注册了可用的上游媒体流。
  bool get hasMedia => _upstreamUrl.isNotEmpty;

  /// 根据到渲染器的实际路由确定本机 IPv4，不依赖网卡枚举顺序。
  static Future<String> resolveLocalAddress(String host, int port) async {
    if (host.isEmpty || port < 1 || port > 65535) {
      throw ArgumentError('Invalid renderer endpoint');
    }
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 3),
    );
    try {
      final address = socket.address;
      if (address.type != InternetAddressType.IPv4 ||
          address.address == '0.0.0.0' ||
          address.address.startsWith('169.254.')) {
        throw StateError('No usable local IPv4 route to renderer');
      }
      _log('route target=$host:$port local=${address.address}');
      return address.address;
    } finally {
      socket.destroy();
    }
  }

  /// 使用会话选定的本机地址启动代理；地址变化时释放旧会话。
  Future<String?> start({required String advertisedHost}) async {
    final address = InternetAddress.tryParse(advertisedHost);
    if (address == null ||
        address.type != InternetAddressType.IPv4 ||
        address.address == '0.0.0.0') {
      throw ArgumentError('A local IPv4 address is required');
    }
    if (_server != null) {
      if (Uri.parse(_proxyBase).host == advertisedHost) return _proxyBase;
      await stop();
    }
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _server = server;
      _token = _generateToken();
      _proxyBase = 'http://$advertisedHost:${server.port}';
      server.listen(
        _handle,
        onError: (Object e, StackTrace st) {
          _log('server error: ${_safeError(e)}');
        },
      );
      _log('started at $_proxyBase');
      return _proxyBase;
    } catch (e) {
      _log('start failed: ${_safeError(e)}');
      _server = null;
      _token = null;
      _proxyBase = '';
      return null;
    }
  }

  /// 注册一条上游媒体流，返回渲染器可用的代理 URL
  /// （`http://<ip>:<port>/m/<token>/media.<ext>`）。
  ///
  /// DLNA 插件会根据 URL 后缀生成 DIDL `protocolInfo`。保留真实后缀可避免
  /// FLAC/AAC 等直连流被错误声明为 `audio/mpeg`，部分严格渲染器会因此拒播。
  ///
  /// 同一时刻只代理一条流（单投屏会话）：注册新流会替换旧流。
  Future<String?> registerMedia(
    String upstreamUrl, {
    Map<String, String> headers = const {},
    String fileExtension = 'mp3',
  }) async {
    final base = proxyBase;
    if (base == null || _token == null) return null;
    _upstreamUrl = upstreamUrl;
    _upstreamHeaders = headers;
    final safeExtension = _sanitizeExtension(fileExtension);
    _log('registered media extension=$safeExtension');
    return '$base/m/$_token/media.$safeExtension';
  }

  /// 清空当前注册的媒体流（断开投屏时调用）。代理服务本身保留。
  void unregisterMedia() {
    _upstreamUrl = '';
    _upstreamHeaders = const {};
  }

  /// 注册一条额外资源（封面图等），返回渲染器可用的匿名 URL（`/r/<resToken>`）。
  Future<String?> registerResource(
    String upstreamUrl, {
    Map<String, String> headers = const {},
  }) async {
    final base = proxyBase;
    if (base == null || _token == null) return null;
    final resToken = _generateToken();
    _resources[resToken] = (url: upstreamUrl, headers: headers);
    return '$base/r/$resToken';
  }

  /// 清空全部额外资源（断开投屏时调用）。
  void unregisterResources() {
    _resources.clear();
  }

  /// 停止代理服务（幂等）。断开投屏并释放端口。
  Future<void> stop() async {
    final server = _server;
    _server = null;
    _token = null;
    _proxyBase = '';
    _upstreamUrl = '';
    _upstreamHeaders = const {};
    _resources.clear();
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final pathSegments = request.uri.pathSegments;
      // 路由 /r/<resToken>：额外资源（封面图等），按注册的认证头转发。
      if (pathSegments.isNotEmpty && pathSegments[0] == 'r') {
        if (pathSegments.length < 2) {
          _respondNotFound(request);
          return;
        }
        final res = _resources[pathSegments[1]];
        if (res == null) {
          _respondNotFound(request);
          return;
        }
        await _forward(request, res.url, res.headers);
        return;
      }
      // 路由：/m/<token>[/...]?u=<目标URL>
      if (pathSegments.length < 2 ||
          pathSegments[0] != 'm' ||
          pathSegments[1] != _token) {
        _respondNotFound(request);
        return;
      }
      final upstream = _upstreamUrl;
      if (upstream.isEmpty) {
        _respondNotFound(request);
        return;
      }

      // 分片/变体播放列表转发：/m/<token>?u=<urlencoded 绝对地址>
      final queryU = request.uri.queryParameters['u'];
      final target = (queryU != null && queryU.isNotEmpty)
          ? Uri.decodeComponent(queryU)
          : upstream;

      final isPrimaryMediaRequest = queryU == null;
      if (isPrimaryMediaRequest) {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        _log(
          'renderer request method=${request.method} resource=media '
          'range=${range == null ? 'none' : 'present'}',
        );
      }
      await _forward(
        request,
        target,
        _upstreamHeaders,
        logResponse: isPrimaryMediaRequest,
      );
    } catch (e) {
      _log('handle error: ${_safeError(e)}');
      _respondInternalError(request);
    }
  }

  /// 手动跟随重定向地把请求转发到 [target]，保持认证头；支持 Range 透传。
  ///
  /// 上游是 HLS m3u8（`application/vnd.apple.mpegurl`）时，读取全文并把相对
  /// 分片地址改写成经本代理的绝对地址后返回。
  Future<void> _forward(
    HttpRequest request,
    String target,
    Map<String, String> headers, {
    bool logResponse = true,
  }) async {
    final client = HttpClient();
    try {
      var uri = Uri.parse(target);
      for (var hop = 0; hop < _maxRedirects; hop++) {
        final upReq = await client.openUrl(request.method, uri);
        // 注入认证头（Cookie / 安全码）
        for (final entry in headers.entries) {
          upReq.headers.set(entry.key, entry.value);
        }
        // 透传 Range（拖动进度）/ If-None-Match 等
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null && range.isNotEmpty) {
          upReq.headers.set(HttpHeaders.rangeHeader, range);
        }

        final upResp = await upReq.close();

        // 手动跟随重定向（保持 Cookie）
        if (upResp.statusCode >= 300 && upResp.statusCode < 400) {
          final location = upResp.headers.value(HttpHeaders.locationHeader);
          if (location != null && location.isNotEmpty) {
            final next = uri.resolve(location);
            await upResp.drain<void>();
            uri = next;
            continue;
          }
        }

        final isM3u8 = _isM3u8(upResp, uri);
        final contentType = upResp.headers.value(HttpHeaders.contentTypeHeader);
        final contentLength = upResp.headers.value(
          HttpHeaders.contentLengthHeader,
        );
        if (logResponse || upResp.statusCode >= HttpStatus.badRequest) {
          _log(
            'upstream response status=${upResp.statusCode} '
            'type=${contentType ?? 'unknown'} '
            'length=${contentLength ?? 'unknown'} '
            'hls=$isM3u8',
          );
        }
        if (isM3u8 && request.method != 'HEAD') {
          // HLS：读取 m3u8 文本，改写分片地址后整体返回
          final text = await upResp.transform(utf8.decoder).join();
          final rewritten = _rewriteM3u8(text, uri);
          final response = request.response;
          response.statusCode = HttpStatus.ok;
          response.headers.set(
            HttpHeaders.contentTypeHeader,
            'application/vnd.apple.mpegurl; charset=utf-8',
          );
          response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
          response.write(rewritten);
          await response.close();
          return;
        }

        // 普通媒体流 / Range：透传状态、关键响应头，流式转发 body
        final response = request.response;
        response.statusCode = upResp.statusCode;
        _copyResponseHeaders(upResp, response);
        if (request.method == 'HEAD') {
          await response.close();
        } else {
          await response.addStream(upResp);
          await response.close();
        }
        return;
      }
      _respondInternalError(request);
    } finally {
      client.close(force: true);
    }
  }

  /// 判断上游响应是否为 HLS m3u8（按 Content-Type 或 URL 后缀）。
  bool _isM3u8(HttpClientResponse upResp, Uri uri) {
    final contentType = upResp.headers.value(HttpHeaders.contentTypeHeader);
    if (contentType != null) {
      final mime = contentType.split(';').first.trim().toLowerCase();
      if (mime == 'application/vnd.apple.mpegurl' ||
          mime == 'application/x-mpegurl') {
        return true;
      }
    }
    final path = uri.path.toLowerCase();
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }

  /// 把 m3u8 里的分片/变体/init 段地址改写成经本代理的绝对地址。
  ///
  /// - 非 `#` 开头的行（分片、变体播放列表地址）：相对地址先按 m3u8 所在 URL
  ///   解析成绝对地址，再编码进 `?u=`；
  /// - 标签行里的 `URI="..."`（`#EXT-X-MAP` 的 init 段、`#EXT-X-KEY`、变体
  ///   `#EXT-X-MEDIA` 等）：同样改写，保证渲染器能拉到所有子资源。
  String _rewriteM3u8(String text, Uri baseUri) {
    final token = _token;
    if (token == null || _proxyBase.isEmpty) return text;
    String proxyUrl(String abs) =>
        '$_proxyBase/m/$token?u=${Uri.encodeComponent(abs)}';
    final lines = text.split('\n');
    final buffer = StringBuffer();
    for (final rawLine in lines) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      if (trimmed.startsWith('#')) {
        // 标签行：改写其中 URI="..." 引号内的资源地址
        buffer.writeln(_rewriteTagUris(rawLine, baseUri, proxyUrl));
        continue;
      }
      // 分片/变体：相对地址解析为绝对地址后走代理
      final abs = baseUri.resolve(trimmed).toString();
      buffer.writeln(proxyUrl(abs));
    }
    return buffer.toString();
  }

  /// 改写 m3u8 标签行里 `URI="..."` 引号内的资源地址（相对 → 经代理）。
  String _rewriteTagUris(
    String line,
    Uri baseUri,
    String Function(String abs) proxyUrl,
  ) {
    const marker = 'URI="';
    final idx = line.indexOf(marker);
    if (idx < 0) return line;
    final start = idx + marker.length;
    final end = line.indexOf('"', start);
    if (end <= start) return line;
    final raw = line.substring(start, end);
    if (raw.isEmpty) return line;
    final abs = baseUri.resolve(raw).toString();
    return line.replaceRange(start, end, proxyUrl(abs));
  }

  /// 复制上游响应头里与媒体投递相关的字段到代理响应。
  void _copyResponseHeaders(HttpClientResponse from, HttpResponse to) {
    const allowlist = <String>{
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentLengthHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.lastModifiedHeader,
      HttpHeaders.etagHeader,
      HttpHeaders.cacheControlHeader,
    };
    for (final allow in allowlist) {
      final value = from.headers.value(allow);
      if (value != null && value.isNotEmpty) {
        to.headers.set(allow, value);
      }
    }
  }

  void _respondNotFound(HttpRequest request) {
    final response = request.response;
    response.statusCode = HttpStatus.notFound;
    response.write('Not found');
    response.close();
  }

  void _respondInternalError(HttpRequest request) {
    final response = request.response;
    response.statusCode = HttpStatus.internalServerError;
    response.write('Proxy error');
    response.close();
  }

  String _generateToken() {
    final rnd = Random.secure();
    return List.generate(24, (_) => rnd.nextInt(16).toRadixString(16)).join();
  }

  static String _sanitizeExtension(String raw) {
    final normalized = raw.trim().toLowerCase().replaceFirst('.', '');
    if (RegExp(r'^[a-z0-9]{1,8}$').hasMatch(normalized)) {
      return normalized;
    }
    return 'mp3';
  }
}
