import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/player_service.dart';
import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/app/tv/tv_ui_scale.dart';
import 'package:feiniu_music/pages/player/player_page.dart';
import 'package:feiniu_music/pages/player/lyrics/lyric_view.dart';
import 'package:feiniu_music/pages/player/widgets/player_bottom_panel.dart';
import 'package:feiniu_music/pages/player/widgets/player_header.dart';

/// 平板横屏播放页布局回归测试。
///
/// 1.2.9 之后平板横屏布局会重复渲染外层全宽 PlayerHeader（外层 + 平板布局
/// 内部各一份），把右侧歌词块推到下方留出大片空白。修复后外层 header
/// 在平板横屏时隐藏，歌词块从布局顶部铺满。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });
  tearDown(() => AppLayoutSettings.resetForTest());

  for (final size in [const Size(1280, 720), const Size(1920, 1080)]) {
    testWidgets('车机播放页：${size.width} 宽屏跟随 200% 缩放且无溢出', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      AppLayoutSettings.tvMode.value = true;
      await AppLayoutSettings.setTvUiScaleOverride(1.0);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => TvUiScale(child: child!),
          home: const PlayerPage(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final lyrics = find.byType(PlayerLyricsView);
      final initialContext = tester.element(lyrics);
      expect(MediaQuery.sizeOf(initialContext), size);
      expect(tester.takeException(), isNull);

      await AppLayoutSettings.setTvUiScaleOverride(2.0);
      await tester.pump();
      expect(MediaQuery.sizeOf(tester.element(lyrics)), size / 2);
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      final playRect = tester.getRect(find.byIcon(Icons.play_arrow_rounded));
      expect(playRect.overlaps(Offset.zero & size), isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('平板横屏：歌词块从顶部铺满（无重复 header 留白）', (tester) async {
    // 10 英寸平板横屏：逻辑 1280×800。
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    AppLayoutSettings.tabletMode.value = true;

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // 平板横屏布局应渲染歌词视图
    expect(find.byType(PlayerLyricsView), findsOneWidget);
    final lyricsColumn = tester
        .element(find.byType(PlayerLyricsView))
        .findAncestorWidgetOfExactType<Expanded>()!;
    expect(lyricsColumn.flex, 6);
    expect(
      lyricsColumn.child,
      isA<PlayerLyricsView>(),
      reason: '歌词区域应直接透出播放背景，不包裹带底色或圆角边框的容器',
    );

    final rect = tester.getRect(find.byType(PlayerLyricsView));
    // 歌词块应从布局顶部开始（仅留外层布局 Padding 8px），
    // 而不是被外层重复 header 推到 93px 处。
    expect(
      rect.top,
      lessThan(30),
      reason: '歌词块顶部不应有重复 header 留白，实际 top=${rect.top}',
    );
    // 歌词块应铺满到接近底部
    expect(
      rect.height,
      greaterThan(700),
      reason: '歌词块应铺满整列高度，实际 height=${rect.height}',
    );
  });

  testWidgets('手机竖屏：仍渲染外层 header（非平板不隐藏）', (tester) async {
    // 手机竖屏 390×844（最短边 390 < 600，非平板）。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // 手机走 _MobilePlayerLayout，首屏是封面页，不渲染 PlayerLyricsView；
    // 外层 header 仍渲染（非平板不隐藏），布局不崩溃。
    expect(tester.takeException(), isNull);
    expect(find.byType(PlayerLyricsView), findsNothing);
  });

  testWidgets('手机横屏：封面与完整歌词共用横屏布局且不溢出', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('landscape-player-layout')),
      findsOneWidget,
    );
    expect(find.byType(PlayerLyricsView), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-favorite-button')),
      findsNothing,
      reason: '矮屏横屏已隐藏左栏标题，标题内的收藏按钮不应单独残留',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机横屏：封面与完整歌词共用横屏布局且不溢出', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('landscape-player-layout')),
      findsOneWidget,
    );
    expect(find.byType(PlayerLyricsView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机横屏：播放控制按钮完整落在屏幕内', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    const screenHeight = 390.0;
    for (final icon in <IconData>[
      Icons.skip_previous_rounded,
      Icons.play_arrow_rounded,
      Icons.skip_next_rounded,
    ]) {
      final finder = find.byIcon(icon);
      expect(finder, findsOneWidget, reason: '缺少控制按钮 $icon');
      final rect = tester.getRect(finder);
      expect(
        rect.bottom,
        lessThanOrEqualTo(screenHeight),
        reason: '$icon 底部超出屏幕：${rect.bottom} > $screenHeight',
      );
    }

    // 底部功能按钮（队列/更多）同样要落在屏幕内。
    for (final icon in <IconData>[
      Icons.format_list_bulleted,
      Icons.more_horiz,
    ]) {
      final finder = find.byIcon(icon);
      if (finder.evaluate().isEmpty) continue;
      final rect = tester.getRect(finder);
      expect(
        rect.bottom,
        lessThanOrEqualTo(screenHeight),
        reason: '$icon 底部超出屏幕：${rect.bottom} > $screenHeight',
      );
    }
  });

  testWidgets('手机横屏：封面铺满整列（不再被控制区挤小）', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    final artwork = find.byKey(const ValueKey('landscape-player-artwork'));
    expect(artwork, findsOneWidget);
    final box = tester.getSize(artwork);
    // _PlayerArtwork 自身铺满可用空间，内部正方形封面取短边。
    final disc = box.height < box.width ? box.height : box.width;
    // 修复前控制区优先后封面只剩 ~104；现在应接近可用高度（~290）。
    expect(
      disc,
      greaterThan(200),
      reason: '横屏封面过小：外框 ${box.width}×${box.height}',
    );
  });

  testWidgets('手机横屏：隐藏左栏标题并让旋转封面相对整列垂直居中', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.byType(PlayerHeader), findsNothing);
    final layoutRect = tester.getRect(
      find.byKey(const ValueKey('landscape-player-layout')),
    );
    final artworkAreaRect = tester.getRect(
      find.byKey(const ValueKey('short-landscape-artwork-area')),
    );
    expect(
      artworkAreaRect.center.dy,
      closeTo(layoutRect.center.dy, 0.1),
      reason: '封面区域应以横屏左栏整列为中心，不再被顶部标题向下推',
    );
  });

  testWidgets('手机横屏：点击封面切换控制浮层显隐', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => PlayerService.instance.isPlaying.value = false);

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // 进入时控制浮层可见（用户不需要先盲点一下才能操作）。
    expect(_panelOpacity(tester), 1.0);

    await _tapArtworkTop(tester);
    expect(_panelOpacity(tester), 0.0, reason: '点击封面后控制浮层应隐藏');

    await _tapArtworkTop(tester);
    expect(_panelOpacity(tester), 1.0, reason: '再次点击应重新显示控制浮层');
  });

  testWidgets('手机横屏：播放中静置后浮层自动隐藏，暂停时保持常驻', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => PlayerService.instance.isPlaying.value = false);

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(_panelOpacity(tester), 1.0);

    PlayerService.instance.isPlaying.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(_panelOpacity(tester), 0.0, reason: '播放中静置后浮层应自动隐藏');

    PlayerService.instance.isPlaying.value = false;
    await _tapArtworkTop(tester);
    expect(_panelOpacity(tester), 1.0);

    await tester.pump(const Duration(seconds: 6));
    expect(_panelOpacity(tester), 1.0, reason: '暂停时浮层不应自动隐藏');
  });

  testWidgets('平板横屏：封面同样完整可见（沿用常驻布局）', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    AppLayoutSettings.tabletMode.value = true;

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    final box = tester.getSize(
      find.byKey(const ValueKey('landscape-player-artwork')),
    );
    final disc = box.height < box.width ? box.height : box.width;
    expect(disc, greaterThan(300), reason: '平板横屏封面应保持大尺寸');
  });
}

/// 控制浮层（AnimatedOpacity）当前是否可见。
double _panelOpacity(WidgetTester tester) {
  final finder = find.ancestor(
    of: find.byType(PlayerControls),
    matching: find.byType(AnimatedOpacity),
  );
  expect(finder, findsWidgets, reason: '未找到控制浮层');
  return tester.widget<AnimatedOpacity>(finder.first).opacity;
}

/// 点击封面顶部区域（浮层可见时它压在封面下半部分，点中间会落在浮层上）。
Future<void> _tapArtworkTop(WidgetTester tester) async {
  final rect = tester.getRect(
    find.byKey(const ValueKey('landscape-player-artwork')),
  );
  await tester.tapAt(Offset(rect.center.dx, rect.top + 20));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}
