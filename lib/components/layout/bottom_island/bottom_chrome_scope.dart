import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'bottom_island_layout.dart';

class BottomChromeScope extends InheritedWidget {
  final double occupiedHeight;
  final double bottomInset;
  const BottomChromeScope({
    super.key,
    required this.occupiedHeight,
    this.bottomInset = 0,
    required super.child,
  });

  static double? occupiedHeightOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<BottomChromeScope>();
    if (scope == null) return null;
    final consumed = (scope.bottomInset - MediaQuery.paddingOf(context).bottom)
        .clamp(0.0, scope.bottomInset);
    return math.max(0, scope.occupiedHeight - consumed);
  }

  @override
  bool updateShouldNotify(BottomChromeScope oldWidget) =>
      occupiedHeight != oldWidget.occupiedHeight ||
      bottomInset != oldWidget.bottomInset;
}

class BottomChromeFrame extends StatefulWidget {
  final BottomIslandLayout layout;
  final Widget child;
  const BottomChromeFrame({
    super.key,
    required this.layout,
    required this.child,
  });
  @override
  State<BottomChromeFrame> createState() => _BottomChromeFrameState();
}

class _BottomChromeFrameState extends State<BottomChromeFrame> {
  Timer? _settle;
  late double _height = widget.layout.occupiedHeight;

  @override
  void didUpdateWidget(BottomChromeFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layout.occupiedHeight == widget.layout.occupiedHeight) return;
    _settle?.cancel();
    final target = widget.layout.occupiedHeight;
    _height = math.max(_height, target);
    if (target < _height) {
      _settle = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _height = widget.layout.occupiedHeight);
      });
    }
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BottomChromeScope(
    occupiedHeight: _height,
    bottomInset: widget.layout.bottomInset,
    child: widget.child,
  );
}
