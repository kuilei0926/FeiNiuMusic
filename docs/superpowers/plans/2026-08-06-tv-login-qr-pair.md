# TV 登录扫码配对（Login QR Pair）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 TV 模式登录页自动启动局域网 HTTP 服务并展示二维码，用户手机扫码在网页填写/修改登录信息，提交后自动填充回 App 并登录。

**Architecture:** shelf 本地 HTTP 服务器（绑定 `0.0.0.0` 随机端口）服务一次性的内嵌网页 + POST 提交端点；URL 携带随机 token（URL 即密钥、一次一密）。登录页拿到凭据后走与手输完全一致的 `_fnLogin` / `_performLogin` 流程自动登录。TV 登录页左侧二维码卡片、右侧原表单；非 TV 模式逐字节不变。

**Tech Stack:** Dart/Flutter、`shelf`（已有 1.4.2）、`shelf_io`（新增）、`qr_flutter`（新增，二维码渲染）、`shared_preferences`。

## Global Constraints

- 手机端（非 TV）登录页行为**逐字节不变**：所有新增 UI/逻辑必须包在 `AppLayoutSettings.tvMode.value` 门控内。
- TV 登录页是门控根页面：返回键需「按两次才退出」（已有 `_armedToExit` / `PopScope`），新增逻辑不得破坏。
- 字段与手输登录完全一致：服务器地址/FNID、用户名、密码、备注名称、安全码。
- 服务仅 TV 模式且登录页存活期间监听；`dispose` 必须 `stop()`。
- 服务失败绝不抛到 UI 顶层：`AppToast` 提示 + 二维码区错误态。
- 新增依赖：`shelf_io: ^1.2.0`、`qr_flutter: ^4.1.0`（`shelf` 已有）。
- 测试沿用现有约定：`TestWidgetsFlutterBinding.ensureInitialized()`、`SharedPreferences.setMockInitialValues({})`、`AppLayoutSettings.resetForTest()`、`tester.pump()`（不用 `pumpAndSettle`）。

---

### Task 1: 新增依赖（shelf_io + qr_flutter）

**Files:**
- Modify: `pubspec.yaml:55`（`shelf: ^1.4.1` 已有，无需改）

- [ ] **Step 1: 添加依赖**

在 `pubspec.yaml` 的 `dependencies:` 中 `shelf: ^1.4.1` 下方新增两行：
```yaml
  shelf_io: ^1.2.0
  qr_flutter: ^4.1.0
```

- [ ] **Step 2: 安装依赖并验证**

```bash
flutter pub get
```
Expected: 成功解析，`flutter pub deps | grep -E "shelf_io|qr_flutter"` 出现两行。

- [ ] **Step 3: Commit**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "deps: 新增 shelf_io 与 qr_flutter（TV 登录扫码配对）"
```

---

### Task 2: LoginPairServer —— 局域网配对 HTTP 服务

**Files:**
- Create: `lib/app/services/login_pair_server.dart`
- Test: `test/login_pair_server_test.dart`

**Interfaces:**
- Consumes: `shelf`、`shelf_io`（Task 1）
- Produces:
  - `class LoginCredentials { final String serverInput; final String username; final String password; final String name; final String? accessCode; }`
  - `class LoginPairServer { static Future<LoginPairSession> start(); static Future<LoginCredentials?> waitForLogin(); static void stop(); }`
  - `class LoginPairSession { final List<String> urls; }` —— `urls[0]` 为首选 URL，全部形如 `http://<ip>:<port>/f/<token>`

- [ ] **Step 1: 写失败测试**

```dart
// test/login_pair_server_test.dart
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
    req.write('{"serverInput":"192.168.1.5","username":"u","password":"p","name":"客厅","accessCode":"ac"}');
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
    req.write('{"serverInput":"a","username":"b","password":"c","name":"","accessCode":null}');
    final resp = await req.close();
    await resp.drain<void>();
    await future;
    // 同一 token 再提交 → 已消费，返回 410（服务仍运行）
    final req2 = await client.postUrl(Uri.parse('$url/submit'));
    req2.headers.contentType = ContentType.json;
    req2.write('{"serverInput":"a","username":"b","password":"c","name":"","accessCode":null}');
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
```

- [ ] **Step 2: 运行测试确认失败**

```bash
flutter test test/login_pair_server_test.dart
```
Expected: FAIL（`LoginPairServer` 未定义，编译错误）。

- [ ] **Step 3: 实现 `lib/app/services/login_pair_server.dart`**

```dart
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
    if (path.length != 2 || path[0] != 'f' || path[1] != _token) {
      return Response.notFound('Not found');
    }
    if (request.method == 'GET') {
      return Response.ok(_webHtml, headers: {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
      });
    }
    if (request.method == 'POST' && request.url.path.endsWith('/submit')) {
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
```

- [ ] **Step 4: 运行测试确认通过**

```bash
flutter test test/login_pair_server_test.dart
```
Expected: PASS（5 个测试）。

- [ ] **Step 5: Commit**

```bash
git add lib/app/services/login_pair_server.dart test/login_pair_server_test.dart
git commit -m "feat: LoginPairServer 局域网配对 HTTP 服务（一次性 token + 内嵌网页）"
```

---

### Task 3: TV 登录页二维码卡片（双栏布局）

**Files:**
- Create: `lib/pages/login/widgets/login_qr_card.dart`
- Modify: `lib/pages/login/login_page.dart`（TV 模式双栏包裹）
- Test: `test/login_qr_card_test.dart`

**Interfaces:**
- Consumes: `LoginPairServer.start()` / `stop()` / `waitForLogin()`（Task 2）、`qr_flutter` `QrImageView`
- Produces:
  - `class LoginQrCard extends StatefulWidget { final ValueChanged<LoginCredentials>? onCredentials; }`
  - `LoginCredentials`（来自 Task 2）

- [ ] **Step 1: 写失败测试**

```dart
// test/login_qr_card_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/login_pair_server.dart';
import 'package:feiniu_music/pages/login/widgets/login_qr_card.dart';

void main() {
  tearDown(() => LoginPairServer.stop());

  testWidgets('TV 登录页二维码卡片：显示二维码与地址，提交后回调凭据', (tester) async {
    LoginCredentials? received;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginQrCard(onCredentials: (c) => received = c),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('http://'), findsWidgets);
    expect(find.text('刷新'), findsOneWidget);

    // 通过服务提交凭据，模拟手机网页 POST。
    final session = await LoginPairServer.start();
    final url = session.urls.first;
    final client = HttpClient();
    addTearDown(client.close);
    final req = await client.postUrl(Uri.parse('$url/submit'));
    req.headers.contentType = ContentType.json;
    req.write('{"serverInput":"x","username":"u","password":"p","name":"","accessCode":null}');
    final resp = await req.close();
    await resp.drain<void>();
    await tester.pump();
    expect(received, isNotNull);
    expect(received!.username, 'u');
  });

  testWidgets('二维码卡片刷新按钮重新生成 token', (tester) async {
    final before = (await LoginPairServer.start()).urls.first;
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: LoginQrCard(onCredentials: (_) {}))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('刷新'));
    await tester.pump();
    final after = (await LoginPairServer.start()).urls.first;
    expect(after, isNot(before));
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
flutter test test/login_qr_card_test.dart
```
Expected: FAIL（`LoginQrCard` / `QrImageView` 未定义）。

- [ ] **Step 3: 实现 `lib/pages/login/widgets/login_qr_card.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/services/login_pair_server.dart';

/// TV 登录页二维码配对卡片。
///
/// 启动 [LoginPairServer]，展示局域网二维码；手机扫码填表提交后通过
/// [onCredentials] 回调凭据。dispose 时停止服务。
class LoginQrCard extends StatefulWidget {
  final ValueChanged<LoginCredentials>? onCredentials;

  const LoginQrCard({super.key, this.onCredentials});

  @override
  State<LoginQrCard> createState() => _LoginQrCardState();
}

class _LoginQrCardState extends State<LoginQrCard> {
  String? _qrUrl;
  bool _starting = true;
  String? _error;
  String? _pendingToken; // 防重复回调

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final session = await LoginPairServer.start();
      if (!mounted) return;
      setState(() {
        _qrUrl = session.urls.first;
        _starting = false;
      });
      _listen();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = '无法启动配对服务';
      });
    }
  }

  Future<void> _listen() async {
    try {
      final creds = await LoginPairServer.waitForLogin();
      if (creds == null || !mounted) return;
      if (_pendingToken != null) return; // 已回调过
      _pendingToken = 'done';
      widget.onCredentials?.call(creds);
    } catch (_) {
      // 服务停止等，忽略
    }
  }

  void _refresh() {
    _pendingToken = null;
    LoginPairServer.stop();
    _start();
  }

  @override
  void dispose() {
    LoginPairServer.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 300,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('扫码配对', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            '手机扫码填写登录信息，提交后自动登录',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          if (_starting)
            const SizedBox(
              height: 180,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            _ErrorState(message: _error!, onRetry: _refresh)
          else if (_qrUrl != null)
            _QrView(url: _qrUrl!, qrSize: 180, scheme: scheme),
          if (_qrUrl != null) ...[
            const SizedBox(height: 12),
            Text(
              '请用同一局域网内的手机扫码',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('刷新'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _QrView extends StatelessWidget {
  const _QrView({required this.url, required this.qrSize, required this.scheme});
  final String url;
  final double qrSize;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: QrImageView(
        data: url,
        version: QrVersions.auto,
        size: qrSize,
        eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Color(0xFF000000),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.wifi_off_rounded, size: 36, color: Colors.grey),
        const SizedBox(height: 8),
        Text(message, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: onRetry,
          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
          child: const Text('重试'),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
flutter test test/login_qr_card_test.dart
```
Expected: PASS（2 个测试）。若 `QrImageView` 渲染报 overflow，把 `_QrView` 外包一层 `Center`/`Flexible`。

- [ ] **Step 5: Commit**

```bash
git add lib/pages/login/widgets/login_qr_card.dart test/login_qr_card_test.dart
git commit -m "feat: TV 登录页二维码配对卡片（LoginQrCard）"
```

---

### Task 4: 登录页 TV 双栏布局 + 自动登录接线

**Files:**
- Modify: `lib/pages/login/login_page.dart`（TV 模式双栏；`_handleQrCredentials` 接线）
- Test: `test/login_page_tv_qr_test.dart`

**Interfaces:**
- Consumes: `LoginQrCard`（Task 3）、`LoginCredentials`（Task 2）、现有 `_fnLogin` / `_performLogin`、`_ensureAccessCodeIfNeeded`
- Produces: 无（集成接线）

- [ ] **Step 1: 写失败测试**

```dart
// test/login_page_tv_qr_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/pages/login/login_page.dart';
import 'package:feiniu_music/pages/login/widgets/login_qr_card.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });
  tearDown(() {
    AppLayoutSettings.resetForTest();
    LoginPairServer.stop();
  });

  testWidgets('非 TV：无二维码卡片（原样渲染）', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pump();
    expect(find.byType(LoginQrCard), findsNothing);
    expect(find.text('登录'), findsOneWidget);
  });

  testWidgets('TV 模式：显示二维码卡片', (tester) async {
    AppLayoutSettings.tvMode.value = true;
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(LoginQrCard), findsOneWidget);
    expect(find.text('扫码配对'), findsOneWidget);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
flutter test test/login_page_tv_qr_test.dart
```
Expected: FAIL（TV 模式无 `LoginQrCard`）。

- [ ] **Step 3: 修改 `login_page.dart`**

3a. **新增 import**（`import '../../app/services/login_pair_server.dart';` 和 `import 'widgets/login_qr_card.dart';`）。

3b. **新增回调方法**（放在 `_canLogin` 附近）：
```dart
/// 手机扫码提交的凭据 → 填充表单并自动登录（与手输一致）。
Future<void> _handleQrCredentials(LoginCredentials creds) async {
  if (!mounted) return;
  setState(() {
    _serverUrlController.text = creds.serverInput;
    _usernameController.text = creds.username;
    _passwordController.text = creds.password;
    _nameController.text = creds.name;
    _errorMessage = null;
  });
  // 网页表单自带安全码 → 直接写入本地，登录时不再询问。
  if (creds.accessCode != null && creds.accessCode!.isNotEmpty) {
    await AppFnConnectionSettings.setAccessCode(creds.accessCode);
  }
  if (!mounted) return;
  if (_isFnId(creds.serverInput)) {
    await _fnLogin(creds.serverInput, creds.username, creds.password,
        name: creds.name);
  } else {
    await _performLogin(creds.serverInput, creds.username, creds.password,
        name: creds.name);
  }
}
```

3c. **修改 `build` 返回**：在 `if (!isTv) return page;` 前，把 TV 分支从「只包 PopScope」改为「双栏 + PopScope」：

当前（第 746 行起）：
```dart
    if (!isTv) return page;
    // TV 模式：拦截返回键，第一次提示「再按一次退出」，2 秒内再按才真正退出。
    return PopScope(
```
改为：
```dart
    if (!isTv) return page;
    // TV 模式：左码右表单双栏；右侧原登录表单。返回键拦截逻辑保留。
    final Widget tvPage = SafeArea(
      child: Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            LoginQrCard(onCredentials: _handleQrCredentials),
            const SizedBox(width: 40),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                child: _buildForm(),
              ),
            ),
          ],
        ),
      ),
    );
    return PopScope(
```
> 注：`_buildForm()` 是从原 `page` 的 `SingleChildScrollView` 内容里提取出的、包在 `Form` 内的 `Column`。实现时把原 `Scaffold(body: SafeArea(child: Center(child: SingleChildScrollView(...))))` 中 `SingleChildScrollView` 的内容抽成 `Widget _buildForm() { return Form(key: _formKey, child: Column(...)); }`，让手机分支与 TV 右栏复用同一表单。抽取出错时保持手机分支行为逐字节不变即可。

（PopScope 的 `child: tvPage` 与后半段逻辑保持不变。）

- [ ] **Step 4: 运行测试确认通过**

```bash
flutter test test/login_page_tv_qr_test.dart
```
Expected: PASS（2 个测试）。

- [ ] **Step 5: 全量回归**

```bash
flutter analyze && flutter test
```
Expected: analyze 仅 4 个既有 info；**全部测试通过**（登录页双栏抽取未改变非 TV 行为）。

- [ ] **Step 6: Commit**

```bash
git add lib/pages/login/login_page.dart test/login_page_tv_qr_test.dart
git commit -m "feat: TV 登录页双栏布局 + 扫码自动登录接线"
```

---

## Self-Review 记录

- **Spec 覆盖**：
  - HTTP 服务 + 一次性 token → Task 2 ✅
  - 内嵌 HTML（5 字段、无外链、JS 校验/预填）→ Task 2（`_webHtml`）✅
  - 二维码渲染 → Task 3（`LoginQrCard` + `QrImageView`）✅
  - 填充 + 自动登录 → Task 4（`_handleQrCredentials` 复用 `_fnLogin`/`_performLogin`）✅
  - 左码右表单 → Task 4（`Row` 双栏）✅
  - 所有登录页实例（首登/回退/添加/编辑）→ 均由 `LoginPage` 统一接线，`isAddMode`/`editAccount` 走既有 `_performLogin` 分支 ✅
  - 生命周期（initState start / dispose stop）→ Task 3（`LoginQrCard`）✅
  - 错误处理（绑定失败重试、410、404、字段 400）→ Task 2/3 ✅
  - 非 TV 逐字节不变 → Task 1/4 断言 ✅
- **占位符扫描**：无 TBD/TODO；每个代码步骤含完整实现。
- **类型一致性**：`LoginCredentials` 字段（`serverInput/username/password/name/accessCode`）在 Task 2/3/4 一致；`LoginPairServer.start()` 返回 `LoginPairSession.urls` 在 Task 2/3/4 一致；`_webHtml` 的 `#/submit` 与 Task 2 `_handle` 的 `endsWith('/submit')` 一致。
