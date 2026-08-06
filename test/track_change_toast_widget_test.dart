import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/components/common/artwork_widget.dart';
import 'package:feiniu_music/components/focus/tv_focusable.dart';
import 'package:feiniu_music/components/feedback/track_change_toast.dart';

const _testSong = SongEntity(
  id: 'song-1',
  title: '夜曲',
  artist: '[{"guid":"ar-1","name":"周杰伦"}]',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
    TrackChangeToast.hide();
  });

  tearDown(() {
    TrackChangeToast.hide();
    AppLayoutSettings.resetForTest();
  });

  testWidgets('弹窗卡片展示封面、歌名、播放条与关闭按钮', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TrackChangeToastView(song: _testSong))),
    );
    await tester.pump();

    expect(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('夜曲')), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('夜曲')), findsOneWidget);
    expect(find.byType(ArtworkWidget), findsOneWidget, reason: '应有封面');
    expect(find.byIcon(Icons.close_rounded), findsOneWidget, reason: '应有手动关闭按钮');
  });

  testWidgets('渐变强调风格：左侧有主题色渐变光带', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TrackChangeToastView(song: _testSong))),
    );
    await tester.pump();

    // 干净的纯色卡片：无彩色渐变光带（去掉了丑的紫色竖条）
    final gradientBoxes = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) =>
            c.decoration is BoxDecoration &&
            (c.decoration! as BoxDecoration).gradient != null)
        .toList();
    expect(gradientBoxes, isEmpty, reason: '不应有彩色渐变光带');
  });

  testWidgets('渐变强调风格：封面带柔光晕', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TrackChangeToastView(song: _testSong))),
    );
    await tester.pump();

    // 封面外层有柔光晕（阴影）
    final artworkWrap = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) =>
            c.decoration is BoxDecoration &&
            (c.decoration! as BoxDecoration).boxShadow != null &&
            (c.decoration! as BoxDecoration).boxShadow!.isNotEmpty)
        .toList();
    expect(artworkWrap, isNotEmpty, reason: '封面应有带阴影的外层（柔光晕）');
  });

  testWidgets('点击关闭按钮立即消失', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: const Scaffold(body: SizedBox())),
    );
    // 用 Scaffold 的 context：它在 Overlay 之下，Overlay.of 才能找到。
    final context = tester.element(find.byType(Scaffold));
    TrackChangeToast.show(
      context,
      _testSong,
      duration: const Duration(seconds: 2),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('夜曲')), findsOneWidget, reason: '弹出后应显示歌名');

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('夜曲')), findsNothing, reason: '点击关闭按钮后应立即消失');
  });

  testWidgets('show 插入 Overlay 后自动消失', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: const Scaffold(body: SizedBox())),
    );
    // 用 Scaffold 的 context：它在 Overlay 之下，Overlay.of 才能找到。
    final context = tester.element(find.byType(Scaffold));
    TrackChangeToast.show(
      context,
      _testSong,
      duration: const Duration(seconds: 2),
    );
    await tester.pump();

    expect(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('夜曲')), findsOneWidget, reason: '弹出后应显示歌名');

    // 入场动画完成，卡片可见
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('夜曲')), findsOneWidget);

    // 超过展示时长 + 退场动画后应消失
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('夜曲')), findsNothing, reason: '到点应自动消失');
  });

  testWidgets('TV 模式下卡片封面更大（大屏醒目）', (tester) async {
    double? artworkSizeOf(WidgetTester t) =>
        t.widget<ArtworkWidget>(find.byType(ArtworkWidget)).size;

    // 手机（默认）尺寸
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TrackChangeToastView(song: _testSong))),
    );
    await tester.pump();
    expect(artworkSizeOf(tester), 44);

    // TV 尺寸（大屏 1.5 倍）
    AppLayoutSettings.tvMode.value = true;
    await tester.pumpWidget(Container());
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TrackChangeToastView(song: _testSong))),
    );
    await tester.pump();
    expect(artworkSizeOf(tester), 144);
  });

  testWidgets('平板模式下卡片同样大屏醒目', (tester) async {
    double? artworkSizeOf(WidgetTester t) =>
        t.widget<ArtworkWidget>(find.byType(ArtworkWidget)).size;

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TrackChangeToastView(song: _testSong))),
    );
    await tester.pump();
    expect(artworkSizeOf(tester), 44);

    AppLayoutSettings.tabletMode.value = true;
    await tester.pumpWidget(Container());
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TrackChangeToastView(song: _testSong))),
    );
    await tester.pump();
    expect(artworkSizeOf(tester), 144);
  });

  testWidgets('卡片大小倍数放大 TV 卡片', (tester) async {
    double? artworkSizeOf(WidgetTester t) =>
        t.widget<ArtworkWidget>(find.byType(ArtworkWidget)).size;

    AppLayoutSettings.tvMode.value = true;
    AppLayoutSettings.trackChangeToastScale.value = 1.0;
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TrackChangeToastView(song: _testSong))),
    );
    await tester.pump();
    expect(artworkSizeOf(tester), 144, reason: '倍数 1.0 时封面为基准 144');

    // 调大到 2.0 → 封面翻倍
    AppLayoutSettings.trackChangeToastScale.value = 2.0;
    await tester.pumpWidget(Container());
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TrackChangeToastView(song: _testSong))),
    );
    await tester.pump();
    expect(artworkSizeOf(tester), closeTo(288, 0.1), reason: '倍数 2.0 时封面应为 288');
  });

  testWidgets('TV 模式下整卡可聚焦，确认键触发关闭', (tester) async {
    var closed = false;
    AppLayoutSettings.tvMode.value = true;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TrackChangeToastView(
              song: _testSong,
              onClose: () => closed = true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // TV 卡片被 TvFocusable 包裹，autofocus 让初始焦点落在这张卡片。
    expect(find.byType(TvFocusable), findsOneWidget);
    expect(closed, isFalse);

    // 焦点已在卡片上，按 Enter → 触发关闭回调。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(closed, isTrue, reason: 'TV 聚焦卡片按 Enter 应关闭');
  });
}
