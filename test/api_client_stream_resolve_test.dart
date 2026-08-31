import 'dart:io';

import 'package:feiniu_music/app/services/feiniu/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 网盘音乐 302 反向代理适配：音频流 URL 预解析。
///
/// 覆盖：
/// - [streamRedirectSameOrigin]：同源判定（scheme/host/port）；
/// - [streamRedirectHeaders]：跨源跳转剥离飞牛 Cookie；
/// - [FeiNiuApiClient.resolveStreamUrl]：本地 HttpServer 模拟 302 链，
///   同源保留 Cookie、跨端口剥离 Cookie、重定向循环回退、直接 200、
///   网络错误回退。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('streamRedirectSameOrigin', () {
    test('同 scheme+host+port → true', () {
      expect(
        streamRedirectSameOrigin(
          Uri.parse('http://nas:5666/a'),
          Uri.parse('http://nas:5666/b'),
        ),
        isTrue,
      );
    });

    test('换 host → false', () {
      expect(
        streamRedirectSameOrigin(
          Uri.parse('http://nas:5666/a'),
          Uri.parse('http://cdn.example.com/b'),
        ),
        isFalse,
      );
    });

    test('换 port → false（反向代理跨端口）', () {
      expect(
        streamRedirectSameOrigin(
          Uri.parse('http://nas:5666/a'),
          Uri.parse('http://nas:5667/b'),
        ),
        isFalse,
      );
    });

    test('http → https → false（跨协议）', () {
      expect(
        streamRedirectSameOrigin(
          Uri.parse('http://nas:5666/a'),
          Uri.parse('https://nas:5667/b'),
        ),
        isFalse,
      );
    });
  });

  group('streamRedirectHeaders', () {
    const headers = {
      'Cookie': 'music-token=tok; mode=relay',
      'x-access-code': 'YWNjZXNz',
    };

    test('同源跳转 → 原样保留 headers（反向代理内部转发仍需鉴权）', () {
      expect(
        streamRedirectHeaders(
          Uri.parse('http://nas:5666/a'),
          Uri.parse('http://nas:5666/proxy/b'),
          headers,
        ),
        headers,
      );
    });

    test('跨主机跳转 → 剥离飞牛 Cookie', () {
      expect(
        streamRedirectHeaders(
          Uri.parse('http://nas:5666/a'),
          Uri.parse('http://cdn.example.com/b'),
          headers,
        ),
        isEmpty,
      );
    });
  });

  group('FeiNiuApiClient.resolveStreamUrl', () {
    setUp(() async {
      await FeiNiuApiClient.instance.setAuth(
        'http://127.0.0.1:1',
        'test-token',
      );
    });

    /// 起一个本地 HttpServer：每次请求回调 handler 决定状态码/Location，
    /// 并记录该请求携带的 Cookie（供「保留/剥离」断言）。
    Future<HttpServer> startServer(
      Future<void> Function(
        HttpRequest request,
        List<String?> cookies,
      ) handler,
      List<String?> cookies,
    ) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        cookies.add(request.headers.value(HttpHeaders.cookieHeader));
        try {
          await handler(request, cookies);
        } catch (_) {
          // 客户端 force-close 后服务器写响应会抛 Broken pipe：忽略。
        }
      });
      return server;
    }

    Future<void> respond(
      HttpRequest request, {
      required int status,
      String? location,
    }) async {
      final response = request.response;
      response.statusCode = status;
      if (location != null) {
        response.headers.set(HttpHeaders.locationHeader, location);
      }
      response.headers.contentType = ContentType.binary;
      // await close：确保状态码/头在客户端读到前已发出。
      await response.close();
    }

    test('302 → 同源下一路径：保留 Cookie，返回最终 URL', () async {
      final cookies = <String?>[];
      final server = await startServer((request, _) async {
        if (request.uri.path == '/music/api/v1/track/stream') {
          await respond(request, status: 302, location: '/proxy/real.flac');
        } else {
          await respond(request, status: 200);
        }
      }, cookies);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final original = '$base/music/api/v1/track/stream?guid=x';
      final resolved =
          await FeiNiuApiClient.instance.resolveStreamUrl(original);
      expect(resolved.url, '$base/proxy/real.flac');
      // 同源跳转：最终 URL 仍需飞牛 Cookie 鉴权。
      expect(resolved.headers['Cookie'], contains('music-token=test-token'));
      // 第一跳（原始流）与第二跳（同源代理）都保留 Cookie。
      expect(cookies[0], contains('music-token=test-token'));
      expect(cookies[1], contains('music-token=test-token'));
    });

    test('302 → 跨端口（跨源）：剥离 Cookie，返回最终 URL', () async {
      // 第二个服务器模拟网盘 CDN（不同端口 = 跨源），记录它收到的 Cookie。
      final cdnCookies = <String?>[];
      final cdn = await startServer((request, _) async {
        await respond(request, status: 200);
      }, cdnCookies);
      addTearDown(() => cdn.close(force: true));
      final cdnBase = 'http://127.0.0.1:${cdn.port}';

      final cookies = <String?>[];
      final server = await startServer((request, _) async {
        await respond(request, status: 302, location: '$cdnBase/file.flac');
      }, cookies);
      addTearDown(() => server.close(force: true));

      final base = 'http://127.0.0.1:${server.port}';
      final original = '$base/music/api/v1/track/stream?guid=x';
      final resolved =
          await FeiNiuApiClient.instance.resolveStreamUrl(original);
      expect(resolved.url, '$cdnBase/file.flac');
      // 跨源跳转：返回的 headers 剥离飞牛 Cookie（CDN 用自身签名鉴权）。
      expect(resolved.headers, isEmpty);
      // 原始服务器请求带 Cookie，CDN 请求不带。
      expect(cookies.single, contains('music-token=test-token'));
      expect(cdnCookies.single, isNull);
    });

    test('302 重定向循环 → 回退原始 URL', () async {
      final cookies = <String?>[];
      final server = await startServer((request, _) async {
        respond(
          request,
          status: 302,
          location: '/music/api/v1/track/stream',
        );
      }, cookies);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final original = '$base/music/api/v1/track/stream?guid=x';
      final resolved =
          await FeiNiuApiClient.instance.resolveStreamUrl(original);
      // 超跳数未消化 302：回退原始 URL + 原始 Cookie。
      expect(resolved.url, original);
      expect(resolved.headers['Cookie'], contains('music-token=test-token'));
    });

    test('直接 200（无 302）：原样返回 + 保留 Cookie', () async {
      final cookies = <String?>[];
      final server = await startServer((request, _) async {
        await respond(request, status: 200);
      }, cookies);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final original = '$base/music/api/v1/track/stream?guid=x';
      final resolved =
          await FeiNiuApiClient.instance.resolveStreamUrl(original);
      expect(resolved.url, original);
      expect(resolved.headers['Cookie'], contains('music-token=test-token'));
    });

    test('网络错误 → 回退原始 URL + 原始 Cookie', () async {
      // 不存在的端口 → 连接失败。
      final original = 'http://127.0.0.1:1/music/api/v1/track/stream?guid=x';
      final resolved =
          await FeiNiuApiClient.instance.resolveStreamUrl(original);
      expect(resolved.url, original);
      expect(resolved.headers['Cookie'], contains('music-token=test-token'));
    });
  });
}
