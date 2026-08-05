import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:feiniu_music/app/services/login_pair_server.dart';
import 'package:feiniu_music/pages/login/widgets/login_qr_card.dart';

/// 测试用假服务：即时完成、可驱动凭据回调，避开 widget test 的 fake-async
/// zone 无法完成真实 socket bind/IO 的问题（真实 socket 由 QR2 的纯 dart 测试覆盖）。
/// URL 用与真实服务一致的长度（32 位 token），避免 qr_flutter 对极短数据的边界问题。
final String _fakeTokenUrl = 'http://192.168.1.5:12345/f/'
    '0123456789abcdef0123456789abcdef';

LoginPairSession _fakeSession(String url) => LoginPairSession([url]);

void main() {
  tearDown(() => LoginPairServer.stop());

  testWidgets('二维码卡片：显示二维码与地址，提交后回调凭据', (tester) async {
    LoginCredentials? received;
    var waitCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginQrCard(
            onCredentials: (c) => received = c,
            startServer: () async => _fakeSession(_fakeTokenUrl),
            waitLogin: () async {
              waitCount++;
              if (waitCount == 1) {
                return const LoginCredentials(
                  serverInput: '192.168.1.5',
                  username: 'u',
                  password: 'p',
                  name: '客厅',
                );
              }
              return null; // 后续轮询不再触发
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('http://'), findsWidgets);
    expect(find.text('刷新'), findsOneWidget);

    // 假 waitLogin 首轮即返回凭据 → 回调触发。
    await tester.pump();
    expect(received, isNotNull);
    expect(received!.username, 'u');
    expect(received!.serverInput, '192.168.1.5');
  });

  testWidgets('二维码卡片刷新按钮重新生成 token', (tester) async {
    var urlIndex = 0;
    final urls = [
      'http://192.168.1.5:1/f/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'http://192.168.1.5:2/f/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginQrCard(
            onCredentials: (_) {},
            startServer: () async => _fakeSession(urls[urlIndex++]),
            waitLogin: () async => null,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 刷新 → startServer 再次调用 → 拿到新 URL（新 token）。
    await tester.tap(find.text('刷新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(urlIndex, 2);
    expect(find.textContaining('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'), findsWidgets);
  });
}
