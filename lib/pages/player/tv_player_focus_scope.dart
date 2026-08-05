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
      // 焦点在可激活按钮上（自带 ActivateIntent 处理器的节点，如 IconButton/
      // InkWell）→ 放行让按钮自己消费，不触发播放/暂停。
      final primary = FocusManager.instance.primaryFocus;
      final act = primary?.context == null
          ? null
          : Actions.maybeFind<ActivateIntent>(primary!.context!);
      if (act != null) return KeyEventResult.ignored;
      widget.onTogglePlayPause?.call();
      return KeyEventResult.handled;
    }

    // 下键：移到/跳到底部操作栏。
    if (key == LogicalKeyboardKey.arrowDown) {
      final primary = FocusManager.instance.primaryFocus;
      if (_inBottomPanel(primary)) return KeyEventResult.ignored;
      final moved = primary?.focusInDirection(TraversalDirection.down) ?? false;
      if (!moved) _focusFirstBottomAction();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 聚焦底部操作栏第一个可聚焦按钮（随机/定时等），确保下键有明确落点。
  void _focusFirstBottomAction() {
    final bottom = widget.bottomActionsFocusNode;
    if (bottom == null) return;
    FocusNode? first;
    for (final n in bottom.descendants) {
      if (n.canRequestFocus && !n.skipTraversal) {
        first = n;
        break;
      }
    }
    (first ?? bottom).requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: Focus(
        focusNode: _node,
        // 纯按键处理祖先：自身不是焦点/遍历目标，避免方向键移进本 scope。
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKeyEvent,
        child: widget.child,
      ),
    );
  }
}
