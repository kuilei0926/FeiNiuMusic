import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/navigator_key.dart';
import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/app/services/track_change_toast_service.dart';
import 'package:feiniu_music/components/feedback/track_change_toast.dart';

const _songA = SongEntity(
  id: 'song-a',
  title: '第一首',
  artist: '[{"guid":"ar-1","name":"歌手A"}]',
);
const _songB = SongEntity(
  id: 'song-b',
  title: '第二首',
  artist: '[{"guid":"ar-2","name":"歌手B"}]',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
    TrackChangeToast.hide();
    TrackChangeToastService.resetForTest();
  });

  tearDown(() {
    TrackChangeToast.hide();
    TrackChangeToastService.resetForTest();
    AppLayoutSettings.resetForTest();
  });

  testWidgets('真实切歌时经全局 Overlay 弹出「正在播放」卡片', (tester) async {
    // 通知开关打开
    await AppLayoutSettings.setTrackChangeNotify(true);

    // 根 Navigator 就绪（MaterialApp 已挂载，appNavigatorKey 可用）
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigatorKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    await tester.pump();

    // 注入可控的 currentSong 数据源，启动服务监听。
    final currentSong = ValueNotifier<SongEntity?>(null);
    TrackChangeToastService.start(currentSong: currentSong);
    // 种子：首曲不弹（previousId == null）
    currentSong.value = _songA;
    // 真实切歌：A → B
    currentSong.value = _songB;
    await tester.pump();

    expect(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('第二首')), findsOneWidget, reason: '切歌后应弹出新歌卡片');
    expect(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('第二首')), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget, reason: '卡片应有关闭按钮');

    // 显式关闭并推进一帧，让 OverlayEntry 的 State dispose 取消内部计时器，
    // 避免测试结束时有 pending timer。
    TrackChangeToast.hide();
    await tester.pump();
  });
}
