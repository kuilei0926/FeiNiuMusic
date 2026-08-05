import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/services/login_pair_server.dart';

/// TV 登录页二维码配对卡片。
///
/// 启动 [LoginPairServer]，展示局域网二维码；手机扫码填表提交后通过
/// [onCredentials] 回调凭据。dispose 时停止服务。
class LoginQrCard extends StatefulWidget {
  final ValueChanged<LoginCredentials>? onCredentials;

  /// 测试注入：启动配对服务的函数（默认用真实 LoginPairServer）。
  /// widget test 的 fake-async zone 无法完成真实 socket bind，
  /// 因此这里留一个替换口，测试注入即时完成的假实现。
  final Future<LoginPairSession> Function()? startServer;

  /// 测试注入：等待登录凭据的函数（默认用真实 LoginPairServer.waitForLogin）。
  final Future<LoginCredentials?> Function()? waitLogin;

  const LoginQrCard({
    super.key,
    this.onCredentials,
    this.startServer,
    this.waitLogin,
  });

  @override
  State<LoginQrCard> createState() => _LoginQrCardState();
}

class _LoginQrCardState extends State<LoginQrCard> {
  String? _qrUrl;
  bool _starting = true;
  String? _error;
  bool _consumed = false; // 防重复回调

  Future<LoginPairSession> _startServer() =>
      widget.startServer?.call() ?? LoginPairServer.start();

  Future<LoginCredentials?> _waitLogin() =>
      widget.waitLogin?.call() ?? LoginPairServer.waitForLogin();

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
      final session = await _startServer();
      if (!mounted) return;
      setState(() {
        _qrUrl = session.urls.first;
        _starting = false;
      });
      _listen();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = '无法启动配对服务';
      });
    }
  }

  Future<void> _listen() async {
    try {
      final creds = await _waitLogin();
      if (creds == null || !mounted) return;
      if (_consumed) return; // 已回调过
      _consumed = true;
      widget.onCredentials?.call(creds);
    } catch (_) {
      // 服务停止等，忽略
    }
  }

  void _refresh() {
    _consumed = false;
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
            // 局域网地址提示：二维码内容即此地址，便于无法扫码时手动输入。
            Text(
              _qrUrl!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 8),
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
        // 注意：不要传 eyeStyle/dataModuleStyle —— qr_flutter 4.1.0 在
        // QrEyeShape.square 下渲染时会对 finder 图案做 null 解包崩溃
        // （_drawFinderPatternItem），默认圆形样式正常。
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
