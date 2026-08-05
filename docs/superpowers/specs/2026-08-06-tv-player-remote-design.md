# TV 播放页遥控设计（Player Remote Control）

## Context（背景与目标）

TV 模式下播放页需要完整的遥控器操作，当前只有全局 `TvFocusScope`（方向键遍历 + 右边缘打开播放页 + 搜索/快进快退快捷键），播放页内没有针对性的遥控语义：

- **OK 键**没有播放/暂停语义；
- **下键**无法快速聚焦到播放器底部的随机/定时等按钮；
- **长按左右**没有切歌；
- 播放页显示时侧边栏与底部迷你播放器仍可见，挤占大屏空间。

已确认的产品决策：
- **OK 键**：按钮优先 —— 焦点在可激活按钮（随机/定时/播放列表/更多/上一首/下一首）时激活该按钮；焦点在封面/标题/进度条/歌词等中性区域时播放/暂停。**仅播放页生效**。
- **下键**：首次按下聚焦到底部操作栏【随机】按钮，可横向/上下移动。
- **长按左/右**：左→上一曲，右→下一曲。
- **自动隐藏**：仅 TV 播放页自动隐藏侧栏 + 迷你播放器，返回后还原。
- **非 TV 手机/平板完全不变**。

## 架构

```
播放页 (PlayerPage)
   │  用 TvPlayerFocusScope 包裹整棵树（新组件）
   ▼
TvPlayerFocusScope
   ├─ FocusTraversalGroup（ReadingOrder）
   ├─ Actions：OK 键（按钮优先 / 中性区播放暂停）
   ├─ KeyEvent：下键直达底部操作栏 + 长按左右切歌
   ▼
TabletLayoutHost 覆盖层：TV + 播放页路由 → 盖住侧栏与迷你播放器（返回还原）
```

## 组件

### 1. `lib/pages/player/tv_player_focus_scope.dart` — `TvPlayerFocusScope`

包裹播放页整棵树的焦点域，提供播放页专属遥控语义：

- **FocusTraversalGroup**（`ReadingOrderTraversalPolicy`）：方向键按阅读序遍历。
- **Actions（OK 键）**：
  - 检查当前焦点节点是否落在「可激活按钮」上（随机/定时/播放列表/更多/上一首/播放/下一首，通过 `_playerControlsFocusKeys` 判定）。
  - 在按钮上 → 走默认 `ActivateIntent`（命中 Material `IconButton.onPressed`）。
  - 不在按钮上（封面/标题/进度条/歌词）→ `PlayerService.instance.togglePlayPause()`。
  - 仅 TV 播放页生效：组件只在 TV 模式由 `PlayerPage` 安装。
- **下键直达**：首次按【下】，若焦点不在底部操作栏，`focusInDirection(down)` 失败则直接聚焦到播放页底部操作栏 `GlobalKey` 对应 `FocusNode`。
- **长按左/右**：`onKeyEvent` 监听 KeyRepeat，左重复 → `player.previous()`，右重复 → `player.next()`。不拦截普通方向键（单次按仍走遍历）。

### 2. 播放页按钮可聚焦

- `PlayerControls` / `BottomActions` 的 `IconButton` 在 TV 模式下已是可聚焦 Material 控件（有主题焦点色），无需 `TvFocusable` 包装。
- 底部操作栏加 `GlobalKey` 供下键直达（`_bottomActionsFocusKey`）。
- 播放页顶部返回按钮在 TV 模式下用 `TvFocusable` 包装（`PlayerHeader`），使 OK 可返回。

### 3. `lib/components/layout/tablet_layout_host.dart` — 播放页覆盖层

- 监听嵌套导航器路由变化（`Navigator` observer / `appRouteObserver` 或 listener）。
- 当前路由是 `/player`（或 `/player/*`）且 TV 模式 → 用一个全屏 `Positioned.fill` `ColoredBox(surface)` 盖住侧栏与迷你播放器（**只盖一层不卸载**，返回后自动还原）。
- 离开播放页 → 覆盖层消失。
- 手机/平板（非 TV）不渲染覆盖层。

### 4. `lib/pages/player/player_page.dart` — 接线

- TV 模式用 `TvPlayerFocusScope` 包裹播放页整棵树（非 TV 完全绕开）。
- 顶部返回按钮 TV 模式可聚焦。

## 生命周期

- 覆盖层只读当前路由，路由离开即还原；不持播放页状态。
- OK 动作只在播放页 `Actions` 内，不碰全局 `TvFocusScope`（全局无 OK 处理，传输键已由 MediaSession 处理，无冲突）。
- 长按只在播放页 `onKeyEvent`，不拦截正常方向键。

## 错误处理 / 边界

- 无播放中歌曲时 OK 播放/暂停为 no-op（`togglePlayPause` 自身兜底）。
- 底部操作栏为空（设置里全关闭）时下键直达仍安全（找不到节点则忽略）。
- 非 TV 手机/平板逐字节不变：所有新增组件用 `AppLayoutSettings.tvMode.value` 门控。

## 测试

- `TvPlayerFocusScope`：OK 键在按钮上激活 / 在中性区播放暂停；下键直达底部操作栏；长按左/右切歌（用 `tester.sendKeyEvent` + `FocusManager.instance.primaryFocus` 断言）。
- 覆盖层：TV + `/player` 路由 → 侧栏/迷你播放器被盖（`find` 或 hit-test 断言）；离开播放页还原；非 TV 不渲染。
- 沿用现有约定（`setUp` reset、`tester.pump` 不用 `pumpAndSettle`）。

## 范围 / 非目标

- 本次**不**做：传输键播放/暂停（已由 MediaSession 处理）、其他页面的 OK/长按语义、播放页以外的隐藏。
