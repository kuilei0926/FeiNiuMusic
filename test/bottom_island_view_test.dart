import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/components/layout/bottom_island/bottom_island_host.dart';
import 'package:feiniu_music/components/layout/bottom_island/bottom_island_layout.dart';
import 'package:feiniu_music/components/layout/bottom_island/bottom_island_style_picker.dart';
import 'package:feiniu_music/components/layout/bottom_island/bottom_chrome_scope.dart';
import 'package:feiniu_music/app/utils/primary_shell_scope.dart';
import 'package:feiniu_music/components/layout/base/app_page_scaffold.dart';
import 'package:feiniu_music/components/player/mini_player/mini_player_bar.dart';

const _song = SongEntity(
  id: 'view-song',
  title: '一首很长很长的测试歌曲标题',
  artist: '测试歌手',
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BottomIslandSettings.resetForTest();
    AppGlassSettings.liquidGlassEnabled.value = false;
    AppBackgroundSettings.panelBlurEnabled.value = false;
  });

  for (final style in [
    BottomIslandStyle.c1,
    BottomIslandStyle.c2,
    BottomIslandStyle.c3,
  ]) {
    for (final width in [320.0, 360.0, 390.0, 430.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets('${style.name} fits $width at text $scale in both themes', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final selected = <int>[];
          for (final brightness in Brightness.values) {
            final layout = BottomIslandLayout.resolve(
              style: style,
              width: width,
              textScale: scale,
              bottomInset: 34,
            );
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(brightness: brightness),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 900),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: Scaffold(
                    body: Stack(
                      children: [
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: BottomIslandView(
                            layout: layout,
                            song: _song,
                            onSelected: selected.add,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            expect(tester.takeException(), isNull);
            final box = tester.getRect(find.byType(BottomIslandView));
            expect(box.height, closeTo(layout.occupiedHeight, .01));
            for (final index in layout.navigationIndices) {
              final tab = find.byKey(ValueKey('island-tab-$index'));
              final size = tester.getSize(tab);
              expect(size.width, greaterThanOrEqualTo(48));
              expect(size.height, greaterThanOrEqualTo(48));
              await tester.tap(tab);
              expect(selected.last, index);
            }
          }
        });
      }
    }
  }

  testWidgets(
    'C2 transparent shoulders pass hits; disc and tabs consume theirs',
    (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var background = 0;
      var opened = 0;
      var tab = -1;
      final layout = BottomIslandLayout.resolve(
        style: BottomIslandStyle.c2,
        width: 390,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => background++,
                    child: const SizedBox.expand(),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: BottomIslandView(
                    layout: layout,
                    song: _song,
                    onOpen: () => opened++,
                    onSelected: (value) => tab = value,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(BottomIslandView));
      await tester.tapAt(Offset(28, rect.top + 10));
      await tester.tapAt(Offset(362, rect.top + 10));
      expect(background, 2);
      await tester.tap(find.byKey(const ValueKey('island-open-player')));
      expect(opened, 1);
      expect(background, 2);
      await tester.tap(find.byKey(const ValueKey('island-tab-3')));
      expect(tab, 3);
      expect(background, 2);
    },
  );

  testWidgets('settings picker persists selection and restores it on rebuild', (
    tester,
  ) async {
    await BottomIslandSettings.ensureLoaded();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: const BottomIslandStylePicker()),
        ),
      ),
    );
    final choice = find.byKey(const ValueKey('island-style-c2'));
    await tester.ensureVisible(choice);
    await tester.pumpAndSettle();
    await tester.tap(choice);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(BottomIslandSettings.style.value, BottomIslandStyle.c2);
    expect(find.textContaining('C1/C2 极简模式下'), findsNWidgets(2));
    BottomIslandSettings.resetForTest();
    await BottomIslandSettings.ensureLoaded();
    expect(BottomIslandSettings.style.value, BottomIslandStyle.c2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('transition reserves the larger envelope then releases it', (
    tester,
  ) async {
    final c2 = BottomIslandLayout.resolve(
      style: BottomIslandStyle.c2,
      width: 390,
    );
    final c1 = BottomIslandLayout.resolve(
      style: BottomIslandStyle.c1,
      width: 390,
    );
    Widget scene(BottomIslandLayout layout) => MaterialApp(
      home: BottomChromeFrame(
        layout: layout,
        child: Builder(
          builder: (context) =>
              Text('${BottomChromeScope.occupiedHeightOf(context)}'),
        ),
      ),
    );
    await tester.pumpWidget(scene(c2));
    await tester.pumpWidget(scene(c1));
    expect(find.text('${c2.occupiedHeight}'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 301));
    expect(find.text('${c1.occupiedHeight}'), findsOneWidget);
  });

  testWidgets(
    'safe area consumed by the page is subtracted from shared padding',
    (tester) async {
      BottomIslandSettings.style.value = BottomIslandStyle.c1;
      AppLayoutSettings.resetForTest();
      final layout = BottomIslandLayout.resolve(
        style: BottomIslandStyle.c1,
        width: 390,
        bottomInset: 34,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 800),
              padding: EdgeInsets.only(bottom: 34),
            ),
            child: BottomChromeFrame(
              layout: layout,
              child: SafeArea(
                child: Builder(
                  builder: (context) => Text(
                    '${AppPageScaffold.scrollableBottomPadding(context, hasBottomNav: true)}',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('${layout.occupiedHeight - 34 + 24}'), findsOneWidget);
    },
  );

  testWidgets(
    'prewarmed pages never render an extra island or suppress the shared owner',
    (tester) async {
      BottomIslandSettings.style.value = BottomIslandStyle.c1;
      AppLayoutSettings.resetForTest();
      await tester.pumpWidget(
        MaterialApp(
          home: PrimaryShellMarker(
            child: Stack(
              children: [
                IndexedStack(
                  index: 0,
                  children: [
                    AppPageScaffold(
                      body: const Text('active'),
                      bottomNavIndex: 0,
                      onBottomNavTap: (_) {},
                    ),
                    AppPageScaffold(
                      body: const Text('hidden'),
                      bottomNavIndex: 1,
                      onBottomNavTap: (_) {},
                      showMiniPlayer: false,
                    ),
                  ],
                ),
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: BottomIslandHost(),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byType(BottomIslandHost, skipOffstage: false),
        findsOneWidget,
      );
      expect(find.byType(MiniPlayerBar, skipOffstage: false), findsNothing);
      expect(find.byKey(const ValueKey('bottom-island-c1')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
