import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/player_service.dart';
import 'package:feiniu_music/app/services/lyrics/lyrics_service.dart';
import 'package:feiniu_music/app/state/settings_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/components/layout/tablet_layout_host.dart';
import 'package:feiniu_music/components/layout/base/app_page_scaffold.dart';
import 'package:feiniu_music/components/player/mini_player/desktop_mini_player_style_picker.dart';
import 'package:feiniu_music/components/player/mini_player/mini_player_bar.dart';
import 'package:feiniu_music/components/player/vinyl_disc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DesktopMiniPlayerSettings.resetForTest();
    BottomIslandSettings.resetForTest();
    AppLayoutSettings.resetForTest();
  });

  tearDown(() {
    PlayerService.instance.currentSong.value = null;
    PlayerService.instance.isPlaying.value = false;
    DesktopMiniPlayerSettings.resetForTest();
    BottomIslandSettings.resetForTest();
    AppLayoutSettings.resetForTest();
  });

  test(
    'desktop default does not write preferences or change fresh mobile migration',
    () async {
      await DesktopMiniPlayerSettings.ensureLoaded();
      expect(
        DesktopMiniPlayerSettings.style.value,
        DesktopMiniPlayerStyle.classic,
      );
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
      await BottomIslandSettings.ensureLoaded();
      expect(BottomIslandSettings.style.value, BottomIslandStyle.c1);
    },
  );

  test('desktop selection persists independently across reload', () async {
    await BottomIslandSettings.ensureLoaded();
    await Future.wait([
      DesktopMiniPlayerSettings.setStyle(DesktopMiniPlayerStyle.classic),
      DesktopMiniPlayerSettings.setStyle(DesktopMiniPlayerStyle.vinyl),
    ]);
    DesktopMiniPlayerSettings.resetForTest();
    await DesktopMiniPlayerSettings.ensureLoaded();
    expect(DesktopMiniPlayerSettings.style.value, DesktopMiniPlayerStyle.vinyl);
    expect(BottomIslandSettings.style.value, BottomIslandStyle.c1);
  });

  for (final value in ['unknown', 42, true]) {
    test('invalid desktop style $value falls back to classic', () async {
      SharedPreferences.setMockInitialValues({
        'desktop_mini_player_style': value,
      });
      await DesktopMiniPlayerSettings.ensureLoaded();
      expect(
        DesktopMiniPlayerSettings.style.value,
        DesktopMiniPlayerStyle.classic,
      );
    });
  }

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets('desktop picker visibility on $platform and TV', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DesktopMiniPlayerStylePicker())),
      );
      final desktop = [
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ].contains(platform);
      expect(find.text('桌面播放条'), desktop ? findsOneWidget : findsNothing);
      AppLayoutSettings.tvMode.value = true;
      await tester.pump();
      expect(find.text('桌面播放条'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('picker saves selection', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DesktopMiniPlayerStylePicker())),
    );
    await tester.tap(find.text('黑胶'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(DesktopMiniPlayerSettings.style.value, DesktopMiniPlayerStyle.vinyl);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'desktop_mini_player_style',
      ),
      'vinyl',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('vinyl preserves title, progress, queue and player callbacks', (
    tester,
  ) async {
    PlayerService.instance.currentSong.value = const SongEntity(
      id: 'desktop-song',
      title: '桌面测试歌曲',
      artist: '测试歌手',
    );
    var opened = 0;
    var queued = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MiniPlayerBar(
            vinyl: true,
            onOpenPlayer: () => opened++,
            onOpenQueue: () => queued++,
          ),
        ),
      ),
    );
    expect(find.byType(VinylDisc), findsOneWidget);
    expect(find.text('桌面测试歌曲'), findsOneWidget);
    expect(find.byType(MiniPlayerPlayButton), findsOneWidget);
    await tester.tap(find.text('桌面测试歌曲'));
    await tester.tap(find.byIcon(Icons.queue_music_rounded));
    expect(opened, 1);
    expect(queued, 1);
    for (final width in [200.0, 160.0, 140.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: width, child: MiniPlayerBar(vinyl: true)),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'vinyl layout adapts to window width, theme and accessible text',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      PlayerService.instance.currentSong.value = const SongEntity(
        id: 'long-title',
        title: '一首很长很长的歌曲名称 A long song title',
        artist: '歌手与艺术家',
      );
      LyricsService.instance.currentLineText.value = '歌词仍然从真实播放服务获取，长文本应平滑省略';
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 1.5, 2.0]) {
          for (final width in [
            140.0,
            180.0,
            240.0,
            320.0,
            520.0,
            900.0,
            1600.0,
          ]) {
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(brightness: brightness),
                home: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: Scaffold(
                    body: SizedBox(
                      width: width,
                      child: MiniPlayerBar(vinyl: true),
                    ),
                  ),
                ),
              ),
            );
            expect(
              tester.takeException(),
              isNull,
              reason: '$brightness / $scale / $width',
            );
            final surface = find.byKey(const ValueKey('desktop-vinyl-surface'));
            expect(tester.getSize(surface).width, lessThanOrEqualTo(760));
            expect(
              find.byTooltip('上一曲'),
              width >= 552 ? findsOneWidget : findsNothing,
            );
            expect(
              find.byTooltip('下一曲'),
              width >= 552 ? findsOneWidget : findsNothing,
            );
            expect(
              find.byTooltip('播放队列'),
              width >= 352 ? findsOneWidget : findsNothing,
            );
            expect(
              tester.getSize(find.byType(MiniPlayerPlayButton)),
              const Size(44, 44),
            );
          }
        }
      }
      LyricsService.instance.currentLineText.value = null;
    },
  );

  testWidgets('empty vinyl state disables playback and navigation controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: MiniPlayerBar(vinyl: true))),
    );
    expect(find.text('未选择歌曲'), findsOneWidget);
    final buttons = tester.widgetList<IconButton>(
      find.descendant(
        of: find.byType(MiniPlayerBar),
        matching: find.byType(IconButton),
      ),
    );
    expect(buttons, isNotEmpty);
    expect(buttons.every((button) => button.onPressed == null), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop picker previews selected style without animation or interaction',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      PlayerService.instance.isPlaying.value = true;
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DesktopMiniPlayerStylePicker())),
      );
      expect(
        tester.widget<MiniPlayerBar>(find.byType(MiniPlayerBar)).vinyl,
        isFalse,
      );
      DesktopMiniPlayerSettings.style.value = DesktopMiniPlayerStyle.vinyl;
      await tester.pump();
      expect(find.byType(VinylDisc), findsOneWidget);
      final context = tester.element(find.byType(VinylDisc));
      expect(TickerMode.valuesOf(context).enabled, isFalse);
      expect(MediaQuery.disableAnimationsOf(context), isTrue);
      expect(
        tester
            .widget<IgnorePointer>(
              find
                  .ancestor(
                    of: find.byType(MiniPlayerBar),
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'floating dock margins pass clicks to the page and blur stays uncached',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      AppGlassSettings.liquidGlassEnabled.value = false;
      AppBackgroundSettings.panelBlurEnabled.value = true;
      var pageTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => pageTaps++,
                    child: const SizedBox.expand(),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: MiniPlayerBar(vinyl: true),
                ),
              ],
            ),
          ),
        ),
      );
      final surface = tester.getRect(
        find.byKey(const ValueKey('desktop-vinyl-surface')),
      );
      await tester.tapAt(Offset(30, surface.center.dy));
      await tester.tapAt(Offset(1170, surface.center.dy));
      expect(pageTaps, 2);
      var cached = false;
      tester.element(find.byType(BackdropFilter)).visitAncestorElements((
        element,
      ) {
        if (element.widget is MiniPlayerBar) return false;
        if (element.widget is RepaintBoundary) cached = true;
        return true;
      });
      expect(cached, isFalse);
    },
  );

  testWidgets('large desktop text reserves enough page space for the dock', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    PlayerService.instance.currentSong.value = const SongEntity(
      id: 'large-text',
      title: '放大的歌曲名称',
      artist: '歌手',
    );
    var reserved = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Builder(
            builder: (context) {
              reserved = AppPageScaffold.scrollableBottomPadding(context);
              return Scaffold(
                body: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: MiniPlayerBar(
                        vinyl: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    final height = tester.getSize(find.byType(MiniPlayerBar)).height;
    expect(reserved, greaterThanOrEqualTo(height + 24));
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop host switches live, pauses hidden vinyl, excludes TV', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final navKey = GlobalKey<NavigatorState>();
    PlayerService.instance.currentSong.value = const SongEntity(
      id: 'desktop-song',
      title: '桌面测试歌曲',
      artist: '测试歌手',
    );
    PlayerService.instance.isPlaying.value = true;
    await tester.pumpWidget(
      MaterialApp(
        home: TabletLayoutHost(
          navigatorKey: navKey,
          child: Navigator(
            key: navKey,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('内容')),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(VinylDisc), findsNothing);
    DesktopMiniPlayerSettings.style.value = DesktopMiniPlayerStyle.vinyl;
    await tester.pump();
    double angle() => tester
        .widget<RotationTransition>(
          find.descendant(
            of: find.byType(VinylDisc),
            matching: find.byType(RotationTransition),
          ),
        )
        .turns
        .value;
    await tester.pump(const Duration(milliseconds: 100));
    expect(angle(), greaterThan(0));
    for (final hidden in [
      AppLayoutSettings.modalSheetActive,
      AppLayoutSettings.playerRouteActive,
    ]) {
      hidden.value = true;
      await tester.pump();
      final stopped = angle();
      await tester.pump(const Duration(milliseconds: 200));
      expect(angle(), stopped);
      hidden.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(angle(), greaterThan(stopped));
    }
    AppLayoutSettings.tvMode.value = true;
    await tester.pump();
    expect(find.byType(VinylDisc), findsNothing);
    expect(DesktopMiniPlayerSettings.style.value, DesktopMiniPlayerStyle.vinyl);
    AppLayoutSettings.tvMode.value = false;
    await tester.pump();
    expect(find.byType(VinylDisc), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });
}
