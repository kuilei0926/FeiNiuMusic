import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// 用户通过手机网页提交的登录凭据。
class LoginCredentials {
  const LoginCredentials({
    required this.serverInput,
    required this.username,
    required this.password,
    this.name = '',
    this.accessCode,
  });

  final String serverInput;
  final String username;
  final String password;
  final String name;
  final String? accessCode;
}

/// 配对会话：包含供二维码/展示使用的局域网 URL 列表。
class LoginPairSession {
  const LoginPairSession(this.urls);
  final List<String> urls;
}

/// TV 登录扫码配对服务：局域网 HTTP 服务器 + 一次性 token。
///
/// 由登录页在 TV 模式下 start()，dispose 时 stop()。URL 形如
/// `http://<ip>:<port>/f/<token>`，token 为随机 32 字符 hex，URL 即密钥。
class LoginPairServer {
  LoginPairServer._();

  static HttpServer? _server;
  static String? _token;
  static List<String>? _urls;
  static Completer<LoginCredentials>? _pending;
  static bool _consumed = false;

  /// 启动服务（幂等）。返回带随机 token 的局域网 URL 列表。
  static Future<LoginPairSession> start() async {
    if (_server != null) {
      return LoginPairSession(List.of(_urls!));
    }
    _consumed = false;
    _pending = Completer<LoginCredentials>();
    _token = _generateToken();

    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler(_handle);
    final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, 0);
    _server = server;

    final port = server.port;
    final addresses = await _localIpv4s();
    _urls = [
      for (final ip in addresses) 'http://$ip:$port/f/$_token',
    ];
    if (_urls!.isEmpty) {
      _urls = ['http://127.0.0.1:$port/f/$_token'];
    }
    return LoginPairSession(List.of(_urls!));
  }

  static Future<Response> _handle(Request request) async {
    final path = request.url.pathSegments;
    // 路径必须是 /f/<token>（网页）或 /f/<token>/submit（提交）。
    if (path.length < 2 || path[0] != 'f' || path[1] != _token) {
      return Response.notFound('Not found');
    }
    final isSubmit = path.length == 3 && path[2] == 'submit';
    if (request.method == 'GET' && path.length == 2) {
      return Response.ok(_webHtml, headers: {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
      });
    }
    if (request.method == 'POST' && isSubmit) {
      if (_consumed) {
        return Response(410, body: '已消费，请重新生成二维码');
      }
      final raw = await request.readAsString();
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final creds = LoginCredentials(
          serverInput: (map['serverInput'] as String? ?? '').trim(),
          username: (map['username'] as String? ?? '').trim(),
          password: map['password'] as String? ?? '',
          name: (map['name'] as String? ?? '').trim(),
          accessCode: (map['accessCode'] as String?)?.trim(),
        );
        if (creds.serverInput.isEmpty ||
            creds.username.isEmpty ||
            creds.password.isEmpty) {
          return Response.badRequest(body: '服务器地址、用户名与密码为必填项');
        }
        _consumed = true;
        if (!_pending!.isCompleted) _pending!.complete(creds);
        return Response.ok('ok');
      } catch (_) {
        return Response.badRequest(body: '请求格式错误');
      }
    }
    return Response(405, body: 'Method not allowed');
  }

  /// 等待用户提交一次登录凭据（一次性：完成后需重新 start 才有新 token）。
  static Future<LoginCredentials?> waitForLogin() {
    return _pending?.future ?? Future<LoginCredentials?>.value();
  }

  /// 停止服务（幂等）。页面 dispose 时调用。
  static void stop() {
    _server?.close(force: true);
    _server = null;
    _token = null;
    _urls = null;
    _pending = null;
    _consumed = false;
  }

  static String _generateToken() {
    final rnd = Random.secure();
    return List.generate(32, (_) => rnd.nextInt(16).toRadixString(16)).join();
  }

  static Future<List<String>> _localIpv4s() async {
    final result = <String>[];
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        // 跳过 APIPA / 链路本地
        if (ip.startsWith('169.254.')) continue;
        result.add(ip);
      }
    }
    return result;
  }
}

/// 内嵌网页（纯 HTML + 原生 JS，无外链）。
const String _webHtml = '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>飞牛音乐 · TV 扫码登录</title>
<style>
  body { font-family: -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif;
         background: #f4f5f7; margin: 0; padding: 24px 16px; color: #1f2937; }
  .card { max-width: 420px; margin: 0 auto; background: #fff;
          border-radius: 16px; padding: 24px; box-shadow: 0 4px 20px rgba(0,0,0,.06); }
  h1 { font-size: 20px; margin: 0 0 4px; }
  p.sub { color: #6b7280; font-size: 13px; margin: 0 0 20px; }
  label { display: block; font-size: 13px; color: #374151; margin: 14px 0 4px; }
  input { width: 100%; box-sizing: border-box; padding: 10px 12px; font-size: 15px;
          border: 1px solid #d1d5db; border-radius: 10px; outline: none; }
  input:focus { border-color: #3b82f6; box-shadow: 0 0 0 3px rgba(59,130,246,.15); }
  button { width: 100%; margin-top: 22px; padding: 12px; font-size: 16px; font-weight: 600;
           color: #fff; background: #3b82f6; border: 0; border-radius: 10px; cursor: pointer; }
  button:disabled { opacity: .6; }
  .err { color: #dc2626; font-size: 13px; margin-top: 12px; display: none; }
</style>
</head>
<body>
  <div class="card">
    <h1>飞牛音乐 · TV 扫码登录</h1>
    <p class="sub">请在电视上确认配对信息后填写以下内容</p>
    <label>服务器地址或 FNID</label>
    <input id="serverInput" placeholder="https://ip:port 或 FNID" autocomplete="off">
    <label>用户名</label>
    <input id="username" autocomplete="off">
    <label>密码</label>
    <input id="password" type="password" autocomplete="off">
    <label>备注名称（可选）</label>
    <input id="name" placeholder="如：客厅 NAS" autocomplete="off">
    <label>安全码（可选）</label>
    <input id="accessCode" placeholder="服务器要求时才填" autocomplete="off">
    <button id="submit">提交并登录</button>
    <div class="err" id="err"></div>
  </div>
  <script>
    const path = location.pathname;
    function fail(msg) {
      const el = document.getElementById('err');
      el.textContent = msg;
      el.style.display = 'block';
    }
    document.getElementById('submit').addEventListener('click', async () => {
      const payload = {
        serverInput: document.getElementById('serverInput').value,
        username: document.getElementById('username').value,
        password: document.getElementById('password').value,
        name: document.getElementById('name').value,
        accessCode: document.getElementById('accessCode').value || null,
      };
      const btn = document.getElementById('submit');
      btn.disabled = true;
      try {
        const resp = await fetch(path + '/submit', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        });
        if (resp.status === 200) {
          document.querySelector('.card').innerHTML =
            '<h1>已提交</h1><p class="sub">信息已发送到电视，正在自动登录…</p>';
        } else if (resp.status === 410) {
          fail('电视端已关闭配对，请重新打开登录页生成新二维码');
        } else {
          const text = await resp.text();
          fail(text || '提交失败，请重试');
        }
      } catch (e) {
        fail('网络错误，请检查与电视是否同一局域网');
      } finally {
        btn.disabled = false;
      }
    });
  </script>
</body>
</html>
''';
