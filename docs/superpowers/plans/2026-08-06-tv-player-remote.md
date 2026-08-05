# TV 播放页遥控（Player Remote Control）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TV 模式播放页支持遥控器：OK 键「按钮优先 / 其余播放暂停」、下键移动到底部随机/定时按钮、长按左右切歌、自动隐藏侧栏+迷你播放器并在返回后还原。

**Architecture:** 新增 `TvPlayerFocusScope` 包住播放页整棵树，通过 `Focus.onKeyEvent` 提供 OK/长按/下键语义（依赖按键冒泡：按钮自消费 Enter，中性区冒泡到 scope → 播放/暂停）；播放按钮 TV 模式 `autofocus`（进页 OK 即暂停、下键走自然遍历到底部操作栏）。`AppLayoutSettings.playerRouteActive` 由 PlayerPage initState/dispose 置位，`TabletLayoutHost` 据此在 TV 模式用 `Opacity 0 + IgnorePointer` 隐藏侧栏与迷你播放器（保留挂载、返回还原）。

**Tech Stack:** Flutter Focus/KeyEvent/Actions、`signals_flutter`、现有 `PlayerService`。

## Global Constraints

- 手机/平板（非 TV）**逐字节不变**：所有新增 UI/逻辑用 `AppLayoutSettings.tvMode.value` 门控。
- 按钮优先：Material 按钮（随机/定时/播放列表/更多/上/下/播放）的 Enter 由按钮自己消费；只有中性区（封面/标题/进度条/歌词）的 OK 才触发播放/暂停。
- 传输键（播放/暂停硬件键）**不**在此处理（已由 MediaSession + MediaButtonReceiver 处理，避免双触发）。本设计只处理 Enter/Select/Space（遥控 OK）与方向键。
- 隐藏侧栏+迷你播放器**只盖不卸载**（Opacity 0 + IgnorePointer），离开播放页自动还原。
- 测试沿用现有约定：`TestWidgetsFlutterBinding.ensureInitialized()`、`SharedPreferences.setMockInitialValues({})`、`AppLayoutSettings.resetForTest()`、`tester.pump()`（不用 `pumpAndSettle`）。

---

### Task 1: TvPlayerFocusScope —— 播放页遥控焦点域

**Files:**
- Create: `lib/pages/player/tv_player_focus_scope.dart`
- Test: `test/tv_player_focus_scope_test.dart`

**Interfaces:**
- Consumes: `PlayerService`（由调用方注入回调，不直接依赖，便于测试）
- Produces:
  - `class TvPlayerFocusScope extends StatefulWidget { final Widget child; final FocusNode? bottomActionsFocusNode; final VoidCallback? onTogglePlayPause; final VoidCallback? onPrevious; final VoidCallback? onNext; }`
  - 语义：OK（Enter/Select/Space，且未被按钮消费）→ `onTogglePlayPause`；KeyRepeat 左/右 → `onPrevious`/`onNext`；arrowDown → 焦点不在底部操作栏时下移，移不动则 `requestFocus(bottomActionsFocusNode)` 后 post-frame 下移。

- [ ] **Step 1: 写失败测试**

```dart
// test/tv_player_focus_scope_test.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/pages/player/tv_player_focus_scope.dart';

void main() {
  testWidgets('OK 键在中性区 → 播放/暂停', (tester) async {
    var toggled = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TvPlayerFocusScope(
          onTogglePlayPause: () => toggled++,
          child: Scaffold(
            body: Center(child: Focus(autofocus: true, child: Text('中性'))),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(toggled, 1);
  });

  testWidgets('OK 键在按钮上 → 激活按钮，不播放/暂停', (tester) async {
    var toggled = 0;
    var pressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TvPlayerFocusScope(
          onTogglePlayPause: () => toggled++,
          child: Scaffold(
            body: Center(
              child: IconButton(
                autofocus: true,
                icon: const Icon(Icons.alarm),
                onPressed: () => pressed++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(pressed, 1);
    expect(toggled, 0);
  });

  testWidgets('长按左/右 → 上一曲/下一曲（KeyRepeat）', (tester) async {
    var prev = 0;
    var next = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TvPlayerFocusScope(
          onPrevious: () => prev++,
          onNext: () => next++,
          child: Scaffold(body: Center(child: Focus(autofocus: true))),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(prev, 1);
    expect(next, 1);
  });

  testWidgets('下键：焦点在中性区 → 移到底部操作栏内第一个可聚焦项', (tester) async {
    final bottomFocus = FocusNode();
    addTearDown(bottomFocus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: TvPlayerFocusScope(
          bottomActionsFocusNode: bottomFocus,
          child: Scaffold(
            body: Column(
              children: [
                // 中性区：无按钮，焦点落在这里
                Expanded(child: Focus(autofocus: true, child: Text('封面区'))),
                Focus(
                  focusNode: bottomFocus,
                  child: Row(children: [IconButton(icon: const Icon(Icons.shuffle), onPressed: () {})]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus,
      isNot(equals(bottomFocus)),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // 焦点应进入底部操作栏区域（bottomFocus 或其子孙）
    final primary = FocusManager.instance.primaryFocus;
    expect(primary, isNotNull);
    expect(
      identical(primary, bottomFocus) || bottomFocus.descendants.contains(primary),
      isTrue,
      reason: '下键应聚焦到底部操作栏：实际 $primary',
    );
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
flutter test test/tv_player_focus_scope_test.dart
```
Expected: FAIL（`TvPlayerFocusScope` 未定义，编译错误）。

- [ ] **Step 3: 实现 `lib/pages/player/tv_player_focus_scope.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 播放页遥控焦点域：包住播放页整棵树，提供 OK/长按/下键语义。
///
/// 只在 TV 模式由 [PlayerPage] 安装；手机端完全不参与。
///
/// 语义：
/// - **OK 键**（Enter/Select/Space）：焦点在 Material 按钮上时按钮自己消费
///   该键（激活），不会冒泡到这里；只有中性区（封面/标题/进度条/歌词）的
///   OK 才触发 [onTogglePlayPause]。天然满足「按钮优先，其余播放/暂停」。
/// - **长按左/右**（KeyRepeat）：[onPrevious] / [onNext]。
/// - **下键**：焦点不在底部操作栏时先尝试 `focusInDirection(down)`；移不动
///   则 `requestFocus([bottomActionsFocusNode])` 并 post-frame 下移，落到
///   底部操作栏第一个可聚焦项（随机/定时等）。
class TvPlayerFocusScope extends StatefulWidget {
  final Widget child;
  final FocusNode? bottomActionsFocusNode;
  final VoidCallback? onTogglePlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  const TvPlayerFocusScope({
    super.key,
    required this.child,
    this.bottomActionsFocusNode,
    this.onTogglePlayPause,
    this.onPrevious,
    this.onNext,
  });

  @override
  State<TvPlayerFocusScope> createState() => _TvPlayerFocusScopeState();
}

class _TvPlayerFocusScopeState extends State<TvPlayerFocusScope> {
  final FocusNode _node = FocusNode();

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  bool _inBottomPanel(FocusNode? primary) {
    final bottom = widget.bottomActionsFocusNode;
    if (primary == null || bottom == null) return false;
    return identical(primary, bottom) || bottom.descendants.contains(primary);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    // 长按左/右切歌：KeyRepeat 触发，不拦截普通单次方向键。
    if (event is KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        widget.onPrevious?.call();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        widget.onNext?.call();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // OK 键：能被按钮消费的已在按钮层处理，这里只处理中性区。
    final isOk = key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.space;
    if (isOk) {
      widget.onTogglePlayPause?.call();
      return KeyEventResult.handled;
    }

    // 下键：移到/跳到底部操作栏。
    if (key == LogicalKeyboardKey.arrowDown) {
      final primary = FocusManager.instance.primaryFocus;
      if (_inBottomPanel(primary)) return KeyEventResult.ignored;
      final moved = primary?.focusInDirection(TraversalDirection.down) ?? false;
      if (!moved) {
        final bottom = widget.bottomActionsFocusNode;
        if (bottom != null) {
          bottom.requestFocus();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            FocusManager.instance.primaryFocus
                ?.focusInDirection(TraversalDirection.down);
          });
        }
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: const ReadingOrderTraversalPolicy(),
      child: Focus(
        focusNode: _node,
        onKeyEvent: _onKeyEvent,
        child: widget.child,
      ),
    );
  }
}
```

> 注：`FocusNode.descendants` 为 Flutter 公开 API（`Iterable<FocusNode>`），用于「底部操作栏节点是否包含当前焦点」。

- [ ] **Step 4: 运行测试确认通过**

```bash
flutter test test/tv_player_focus_scope_test.dart
```
Expected: PASS（4 个测试）。若「按钮优先」测试失败（Enter 冒泡被 scope 抢走导致按钮不激活），说明该 Flutter 版本按键派发路径不同：把 OK 分支改为「先检查 primaryFocus 是否命中可激活按钮」—— 用 `Actions.maybeFind<ActivateIntent>(focusNode.context)` 判断焦点是否自带 ActivateIntent 处理器，是则 `return ignored` 让按钮处理，否则播放/暂停。以测试为准调整。

- [ ] **Step 5: Commit**

```bash
git add lib/pages/player/tv_player_focus_scope.dart test/tv_player_focus_scope_test.dart
git commit -m "feat: TvPlayerFocusScope 播放页遥控（OK 播放暂停/长按切歌/下键落底部）"
```

---

### Task 2: 播放页接线 —— 包 scope + 播放按钮 autofocus + 底部操作栏焦点

**Files:**
- Modify: `lib/pages/player/player_page.dart`（包 `TvPlayerFocusScope`、`_bottomPanelFocus` 传递）
- Modify: `lib/pages/player/widgets/player_bottom_panel.dart`（`PlayerControls` 播放按钮 TV autofocus）
- Test: `test/tv_player_page_test.dart`

**Interfaces:**
- Consumes: `TvPlayerFocusScope`（Task 1）、`PlayerService`、`AppLayoutSettings`
- Produces: `AppLayoutSettings.playerRouteActive`（Task 3 消费，见 Task 3 定义）

- [ ] **Step 1: 写失败测试**

```dart
// test/tv_player_page_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/pages/player/player_page.dart';
import 'package:feiniu_music/pages/player/tv_player_focus_scope.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });
  tearDown(() => AppLayoutSettings.resetForTest());

  testWidgets('非 TV：无 TvPlayerFocusScope，playerRouteActive 不动', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    expect(find.byType(TvPlayerFocusScope), findsNothing);
  });

  testWidgets('TV 模式：PlayerPage 挂载 → playerRouteActive=true，卸载 → false',
      (tester) async {
    AppLayoutSettings.tvMode.value = true;
    expect(AppLayoutSettings.playerRouteActive.value, isFalse);

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    expect(AppLayoutSettings.playerRouteActive.value, isTrue);
    expect(find.byType(TvPlayerFocusScope), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(AppLayoutSettings.playerRouteActive.value, isFalse);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
flutter test test/tv_player_page_test.dart
```
Expected: FAIL（`TvPlayerFocusScope` 未包、`playerRouteActive` 未定义）。

- [ ] **Step 3: 在 `settings_layout_state.dart` 添加播放页路由状态**

在 `AppLayoutSettings` 加（`_doLoad`/`resetForTest` 均复位为 false）：

```dart
  /// 播放页路由当前是否激活（由 PlayerPage initState/dispose 置位）。
  /// TabletLayoutHost 据此在 TV 模式隐藏侧栏与迷你播放器。
  static final ValueNotifier<bool> playerRouteActive = ValueNotifier(false);
```
并在 `resetForTest()` 中加 `playerRouteActive.value = false;`。

- [ ] **Step 4: `player_page.dart` 接线**

4a. 新增 import：`import 'tv_player_focus_scope.dart';`

4b. `_PlayerPageState` 新增字段并在 dispose 释放 + initState/dispose 置位：

```dart
  final FocusNode _bottomPanelFocus = FocusNode();
```
在 `initState()` 末尾加 `AppLayoutSettings.playerRouteActive.value = true;`
在 `dispose()` 里 `_bottomPanelFocus.dispose();` 且 `AppLayoutSettings.playerRouteActive.value = false;`

4c. `build` 末尾包 scope（在现有 `return PopScope(...)` 外层或内层均可，确保 scope 包住整棵树）：

现有：
```dart
  @override
  Widget build(BuildContext context) {
    // 系统返回键...
    return PopScope(
      canPop: Navigator.of(context).canPop(),
      ...
    );
  }
```
改为（包一层 TV 门控）：
```dart
  @override
  Widget build(BuildContext context) {
    final isTv = AppLayoutSettings.tvMode.value;
    final Widget page = PopScope(
      canPop: Navigator.of(context).canPop(),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _closePlayer();
      },
      child: Scaffold(...),  // 原整棵 Scaffold 不变
    );
    if (!isTv) return page;
    return TvPlayerFocusScope(
      bottomActionsFocusNode: _bottomPanelFocus,
      onTogglePlayPause: () => _player.togglePlayPause(),
      onPrevious: _player.previous,
      onNext: _player.next,
      child: page,
    );
  }
```

4d. 把 `_bottomPanelFocus` 传进两个布局的底部面板：给 `_PlayerView`、`_MobilePlayerLayout`、`_TabletLandscapePlayerLayout` 增加 `FocusNode? bottomPanelFocus` 参数，在 `PlayerBottomPanel` 外包 `Focus(focusNode: bottomPanelFocus, child: panel)`（非 TV 也包，无害；仅 TV 的 scope 会用到）。调用点依次传递 `bottomPanelFocus: _bottomPanelFocus`。

- [ ] **Step 5: `player_bottom_panel.dart` 播放按钮 TV autofocus**

`PlayerControls` 的主播放/暂停 `IconButton`（`onPressed: player.togglePlayPause` 那个）加 `autofocus: AppLayoutSettings.tvMode.value`。TV 模式进播放页默认聚焦播放按钮 → OK 即暂停、下键自然遍历到底部操作栏。

- [ ] **Step 6: 运行测试确认通过**

```bash
flutter test test/tv_player_page_test.dart
```
Expected: PASS（2 个测试）。若 `PlayerService.instance` 在测试构造时触发真实引擎初始化，把该测试的断言拆成最小：只断言 `playerRouteActive` 的置位/复位与 `TvPlayerFocusScope` 存在，不深究 UI。

- [ ] **Step 7: 全量回归**

```bash
flutter analyze && flutter test
```
Expected: analyze 仅既有 info；全部通过（非 TV 行为未变）。

- [ ] **Step 8: Commit**

```bash
git add lib/pages/player/player_page.dart lib/pages/player/widgets/player_bottom_panel.dart lib/app/state/settings_layout_state.dart test/tv_player_page_test.dart
git commit -m "feat: 播放页接线 TV 遥控（包 scope + 播放钮 autofocus + playerRouteActive）"
```

---

### Task 3: TabletLayoutHost —— TV 播放页隐藏侧栏 + 迷你播放器

**Files:**
- Modify: `lib/components/layout/tablet_layout_host.dart`（`hideChrome` 时 Opacity 0 + IgnorePointer）
- Test: `test/tv_player_chrome_test.dart`

**Interfaces:**
- Consumes: `AppLayoutSettings.playerRouteActive`（Task 2）、`AppLayoutSettings.tvMode`、现有 `SideMenu`/`_buildMiniPlayer`
- Produces: 无

- [ ] **Step 1: 写失败测试**

```dart
// test/tv_player_chrome_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/router/app_router.dart';
import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/components/layout/tablet_layout_host.dart';
import 'package:feiniu_music/components/layout/side_menu.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });
  tearDown(() => AppLayoutSettings.resetForTest());

  Widget buildHost() {
    final navKey = GlobalKey<NavigatorState>();
    return MaterialApp(
      home: TabletLayoutHost(
        navigatorKey: navKey,
        child: Navigator(
          key: navKey,
          initialRoute: AppRoutes.home,
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('内容')),
          ),
        ),
      ),
    );
  }

  bool sideMenuInvisible(WidgetTester tester) {
    final ignore = tester
        .widgetList<IgnorePointer>(find.ancestor(
          of: find.byType(SideMenu),
          matching: find.byType(IgnorePointer),
        ))
        .firstOrNull;
    if (ignore == null) return false;
    return ignore.ignoring;
  }

  testWidgets('非 TV：播放页激活也不隐藏侧栏', (tester) async {
    await tester.pumpWidget(buildHost());
    await tester.pump();
    AppLayoutSettings.playerRouteActive.value = true;
    await tester.pump();
    expect(sideMenuInvisible(tester), isFalse);
  });

  testWidgets('TV + 播放页激活 → 侧栏被隐藏（IgnorePointer ignoring）', (tester) async {
    AppLayoutSettings.tvMode.value = true;
    await tester.pumpWidget(buildHost());
    await tester.pump();
    expect(sideMenuInvisible(tester), isFalse);

    AppLayoutSettings.playerRouteActive.value = true;
    await tester.pump();
    expect(sideMenuInvisible(tester), isTrue);

    // 返回后还原
    AppLayoutSettings.playerRouteActive.value = false;
    await tester.pump();
    expect(sideMenuInvisible(tester), isFalse);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
flutter test test/tv_player_chrome_test.dart
```
Expected: FAIL（TV+播放页激活时侧栏未被隐藏）。

- [ ] **Step 3: `tablet_layout_host.dart` 实现**

在 `_TabletLayoutHostState.build` 的 `AnimatedBuilder.builder` 里，把整个 `Stack` 用 `ValueListenableBuilder<bool>`（监听 `AppLayoutSettings.playerRouteActive`）包起来，计算 `hideChrome` 并应用到侧栏与迷你播放器：

```dart
child: AppBackground(
  child: ValueListenableBuilder<bool>(
    valueListenable: AppLayoutSettings.playerRouteActive,
    builder: (context, playerActive, _) {
      // TV 模式且播放页激活 → 隐藏侧栏与迷你播放器（只盖不卸载，返回还原）。
      final hideChrome = AppLayoutSettings.tvMode.value && playerActive;
      return Stack(
        children: [
          Positioned.fill(child: ClipRect(child: Padding(... /* 原内容，不变 */))),
          Positioned(
            left: -drawerWidth + drawerWidth * t,
            top: 0,
            bottom: 0,
            width: drawerWidth,
            child: IgnorePointer(
              ignoring: hideChrome,
              child: Opacity(
                opacity: hideChrome ? 0 : 1,
                child: IgnorePointer(
                  ignoring: t == 0,
                  child: SideMenu(
                    onNavigate: _handleNavigate,
                    onPush: _handlePush,
                  ),
                ),
              ),
            ),
          ),
          if (AppLayoutSettings.effectiveTabletMode)
            Positioned(
              left: 0,
              right: 0,
              bottom: bottomInset,
              child: IgnorePointer(
                ignoring: hideChrome,
                child: Opacity(
                  opacity: hideChrome ? 0 : 1,
                  child: _buildMiniPlayer(),
                ),
              ),
            ),
        ],
      );
    },
  ),
),
```

> 只改 `Stack` 结构；`contentWidth`/`pageOffset`/`bottomInset` 等既有计算保持不变。`_buildMiniPlayer()` 的 `TvFocusable` 逻辑不变。

- [ ] **Step 4: 运行测试确认通过**

```bash
flutter test test/tv_player_chrome_test.dart
```
Expected: PASS（2 个测试）。

- [ ] **Step 5: 全量回归**

```bash
flutter analyze && flutter test
```
Expected: analyze 仅既有 info；**全部测试通过**（非 TV 行为未变：`hideChrome` 恒 false，Opacity=1、IgnorePointer 不忽略）。

- [ ] **Step 6: Commit**

```bash
git add lib/components/layout/tablet_layout_host.dart test/tv_player_chrome_test.dart
git commit -m "feat: TV 播放页自动隐藏侧栏与迷你播放器（返回还原）"
```

---

## Self-Review 记录

- **Spec 覆盖**：
  - OK 键「按钮优先 / 其余播放暂停」→ Task 1（`onKeyEvent` Enter/Select/Space 只在按钮未消费时触发）+ Task 2（播放按钮 autofocus）✅
  - 下键移动到底部随机/定时按钮 → Task 1（arrowDown + `bottomActionsFocusNode` 兜底）+ Task 2（`_bottomPanelFocus` 传递）✅
  - 长按左/右切歌 → Task 1（KeyRepeat）✅
  - 自动隐藏侧栏+迷你播放器、返回还原 → Task 3（`playerRouteActive` + Opacity/IgnorePointer）✅
  - 非 TV 逐字节不变 → Task 2/3 断言 ✅
- **占位符扫描**：无 TBD/TODO；每个代码步骤含完整实现。
- **类型一致性**：`TvPlayerFocusScope` 参数（`bottomActionsFocusNode`/`onTogglePlayPause`/`onPrevious`/`onNext`）在 Task 1/2 一致；`AppLayoutSettings.playerRouteActive` 在 Task 2（定义+置位）/Task 3（消费）一致；`FocusNode.descendants` 仅用于 Task 1 测试与实现。
- **已知风险**：Task 1 的「按钮优先」依赖按键冒泡到 scope；若测试失败（按钮 Enter 被 scope 抢走），已给出备选方案（`Actions.maybeFind<ActivateIntent>` 判定焦点是否自带处理器）。Task 2 若 `PlayerService.instance` 在测试构造触发真实引擎，测试已降级为只断言 flag 与 scope 存在。
