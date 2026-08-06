import 'package:flutter/widgets.dart';

/// TV 端布局辅助（10-foot UI）。
///
/// 所有值都是纯函数，调用方在 `tvEnabled` 为真时使用；手机端不使用这些值，
/// 因此不影响现有布局。
class TvLayout {
  TvLayout._();

  /// TV 网格列数：按逻辑宽度分级，1080p 盒子（约 1920 逻辑宽）取 5-6 列。
  static int gridColumns(double width) {
    if (width >= 1600) return 6;
    if (width >= 1200) return 5;
    return 4;
  }

  /// TV 卡片宽高比（宽/高）。
  ///
  /// 网格卡是「正方形封面 + 标题」结构：卡片高度 ≈ 封面(W) + 标题区(~40px)。
  /// 若比例太小（如 0.5 = 高是宽的 2 倍），正方形封面下方会空出一大段
  /// 空白。TV 用 0.84~0.88 让卡片高度恰好容纳正方形封面 + 标题，无空隙。
  static double cardAspectRatio(int columns) {
    return switch (columns) {
      4 => 0.88,
      5 => 0.86,
      _ => 0.84,
    };
  }

  /// 页面水平/垂直留白：TV 从 3 米外观看，间距比手机大，底部无需
  /// 160px 手势条留白（TV 没有全面屏手势条）。
  static EdgeInsets pagePadding() =>
      const EdgeInsets.fromLTRB(32, 12, 32, 32);

  /// 列表行封面/缩略图尺寸。
  static double artworkSize() => 56;

  /// 列表行最小高度（加大命中区域，方便遥控器聚焦）。
  static double tileMinHeight() => 72;

  /// 侧栏宽度（TabletLayoutHost 使用），比手机端抽屉更宽。
  static const double railWidthMin = 320;
  static const double railWidthMax = 360;
}
