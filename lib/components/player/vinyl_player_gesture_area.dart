import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// One control surface: tap toggles, horizontal swipes skip, upward swipes open.
class VinylPlayerGestureArea extends StatefulWidget {
  final Widget child;
  final String label;
  final String value;
  final bool enabled;
  final VoidCallback? onPlay;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onOpen;

  const VinylPlayerGestureArea({
    super.key,
    required this.child,
    required this.label,
    required this.value,
    required this.enabled,
    this.onPlay,
    this.onPrevious,
    this.onNext,
    this.onOpen,
  });

  @override
  State<VinylPlayerGestureArea> createState() => _VinylPlayerGestureAreaState();
}

class _VinylPlayerGestureAreaState extends State<VinylPlayerGestureArea> {
  double _horizontalTravel = 0;
  double _verticalTravel = 0;
  bool _dragging = false;

  void _reset() => setState(() {
    _horizontalTravel = 0;
    _verticalTravel = 0;
    _dragging = false;
  });

  void _horizontalEnd(DragEndDetails details) {
    final travel = _horizontalTravel;
    final velocity = details.primaryVelocity ?? 0;
    _reset();
    if (travel.abs() < 24 && velocity.abs() < 400) return;
    final direction = travel.abs() >= 24 ? travel : velocity;
    if (direction < 0) {
      widget.onNext?.call();
    } else {
      widget.onPrevious?.call();
    }
  }

  void _verticalEnd(DragEndDetails details) {
    final travel = _verticalTravel;
    final velocity = details.primaryVelocity ?? 0;
    _reset();
    if (travel <= -24 || (travel <= 0 && velocity < -400)) {
      widget.onOpen?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      value: widget.value,
      hint: enabled ? '点按播放或暂停，左右滑动切歌，上滑打开播放页' : null,
      onTap: enabled ? widget.onPlay : null,
      customSemanticsActions: enabled
          ? {
              if (widget.onPrevious != null)
                const CustomSemanticsAction(label: '上一曲'): widget.onPrevious!,
              if (widget.onNext != null)
                const CustomSemanticsAction(label: '下一曲'): widget.onNext!,
              if (widget.onOpen != null)
                const CustomSemanticsAction(label: '打开播放页'): widget.onOpen!,
            }
          : null,
      child: GestureDetector(
        excludeFromSemantics: true,
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? widget.onPlay : null,
        onHorizontalDragStart: enabled
            ? (_) => setState(() => _dragging = true)
            : null,
        onHorizontalDragUpdate: enabled
            ? (details) =>
                  setState(() => _horizontalTravel += details.primaryDelta ?? 0)
            : null,
        onHorizontalDragEnd: enabled ? _horizontalEnd : null,
        onHorizontalDragCancel: enabled ? _reset : null,
        onVerticalDragStart: enabled
            ? (_) => setState(() => _dragging = true)
            : null,
        onVerticalDragUpdate: enabled
            ? (details) =>
                  setState(() => _verticalTravel += details.primaryDelta ?? 0)
            : null,
        onVerticalDragEnd: enabled ? _verticalEnd : null,
        onVerticalDragCancel: enabled ? _reset : null,
        child: AnimatedContainer(
          duration: _dragging || reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          transform: Matrix4.translationValues(
            reduceMotion ? 0 : (_horizontalTravel * .12).clamp(-8, 8),
            reduceMotion ? 0 : (_verticalTravel * .12).clamp(-8, 0),
            0,
          ),
          child: ExcludeSemantics(child: widget.child),
        ),
      ),
    );
  }
}
