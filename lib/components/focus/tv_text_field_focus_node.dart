import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../app/state/settings_state.dart';

/// TV 模式下可方向键移出的文本输入框焦点节点。
///
/// 问题：Flutter 的 [EditableText] 在获得焦点后，其内部 Shortcuts 会把
/// 方向键映射为光标移动（[ExtendSelectionVerticallyToAdjacentLineIntent] 等），
/// 因此 TV 遥控器聚焦到输入框后就再也移不出去了（焦点被输入框吞掉）。
///
/// 解决：本节点在 TV 模式下拦截方向键转成焦点遍历（[FocusNode.focusInDirection]）。
/// - **上下键**始终遍历：单行输入框没有「上一行/下一行」光标可移，上下键
///   对单行编辑无意义，交给焦点遍历让遥控器能移到下一个输入框/按钮。
/// - **左右键**仅当输入框为空时遍历（有内容时左右键用于光标微调，保留编辑行为）。
///
/// 使用：传给 TextField/TextFormField 的 `focusNode`，并用 [bindTo] 关联
/// controller 以便内部感知内容是否为空。
class TvTextFieldFocusNode extends FocusNode {
  TvTextFieldFocusNode({super.debugLabel}) {
    // FocusNode.onKeyEvent 是字段而非可覆写方法，构造函数里赋值。
    onKeyEvent = _handleKeyEvent;
  }

  /// 当前文本值。调用方在 `onChanged` 里更新，或把 controller 通过
  /// [bindTo] 关联后由内部监听。
  String text = '';

  TextEditingController? _boundController;

  /// 关联 controller：内部监听其变化，避免调用方手动同步 [text]。
  void bindTo(TextEditingController controller) {
    _boundController?.removeListener(_syncFromController);
    _boundController = controller;
    text = controller.text;
    controller.addListener(_syncFromController);
  }

  void _syncFromController() {
    text = _boundController?.text ?? '';
  }

  @override
  void dispose() {
    _boundController?.removeListener(_syncFromController);
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!AppLayoutSettings.tvMode.value) return KeyEventResult.ignored;

    final key = event.logicalKey;
    // 上下键：单行输入框无上下光标可移，总是遍历移出。
    final isVertical = key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    // 左右键：仅空输入框时遍历（有内容时保留给光标微调）。
    final isHorizontal = key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    if (!isVertical && !isHorizontal) return KeyEventResult.ignored;
    if (isHorizontal && text.isNotEmpty) return KeyEventResult.ignored;

    final direction = switch (key) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;

    // 移动焦点到方向上的下一个可聚焦节点；找不到时保持原地，不消费事件。
    if (node.focusInDirection(direction)) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}
