import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:feiniu_music/app/services/login_pair_server.dart';

void main() {
  tearDown(() => LoginPairServer.stop());

  test('start 返回含 token 的局域网 URL', () async {
    final session = await LoginPairServer.start();
    expect(session.urls, isNotEmpty);
    final url = Uri.parse(session.urls.first);
    expect(url.scheme, 'http');
    expect(url.port, greaterThan(0));
    expect(url.pathSegments, isNotEmpty);
    expect(url.pathSegments.first, 'f');
    expect(url.pathSegments[1].length, greaterThanOrEqualTo(16));
  });

  test('waitForLogin 在正确 token 提交后返回凭据', () async {
    final session = await LoginPairServer.start();
    final url = session.urls.first;
    final client = HttpClient();
    addTearDown(client.close);
    final future = LoginPairServer.waitForLogin();
    final req = await client.postUrl(Uri.parse('$url/submit'));
    req.headers.contentType = ContentType.json;
    req.write(
      '{"serverInput":"192.168.1.5","username":"u","password":"p","name":"客厅","accessCode":"ac"}',
    );
    final resp = await req.close();
    await resp.drain<void>();
    expect(resp.statusCode, 200);
    final creds = await future;
    expect(creds!.serverInput, '192.168.1.5');
    expect(creds.username, 'u');
    expect(creds.accessCode, 'ac');
  });

  test('错误 token → 404', () async {
    final session = await LoginPairServer.start();
    final client = HttpClient();
    addTearDown(client.close);
    // 用真实服务器端口但换掉 token 路径 → 404
    final uri = Uri.parse(session.urls.first);
    final wrong = Uri(
      scheme: 'http',
      host: uri.host,
      port: uri.port,
      path: '/f/notthetoken/submit',
    );
    final req = await client.postUrl(wrong);
    final resp = await req.close();
    await resp.drain<void>();
    expect(resp.statusCode, 404);
  });

  test('waitForLogin 一次消费后失效', () async {
    final session = await LoginPairServer.start();
    final url = session.urls.first;
    final client = HttpClient();
    addTearDown(client.close);
    final future = LoginPairServer.waitForLogin();
    final req = await client.postUrl(Uri.parse('$url/submit'));
    req.headers.contentType = ContentType.json;
    req.write(
      '{"serverInput":"a","username":"b","password":"c","name":"","accessCode":null}',
    );
    final resp = await req.close();
    await resp.drain<void>();
    await future;
    // 同一 token 再提交 → 已消费，返回 410（服务仍运行）
    final req2 = await client.postUrl(Uri.parse('$url/submit'));
    req2.headers.contentType = ContentType.json;
    req2.write(
      '{"serverInput":"a","username":"b","password":"c","name":"","accessCode":null}',
    );
    final resp2 = await req2.close();
    await resp2.drain<void>();
    expect(resp2.statusCode, 410);
  });

  test('stop 幂等', () async {
    await LoginPairServer.start();
    LoginPairServer.stop();
    LoginPairServer.stop(); // 不抛
  });
}
