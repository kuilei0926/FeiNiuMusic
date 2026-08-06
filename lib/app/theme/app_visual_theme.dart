import 'package:flutter/material.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shad;

extension AppVisualStyleContext on BuildContext {
  bool get usesMiuix => true;
}

ThemeData buildMiuixMaterialTheme(
  ThemeData base,
  ColorScheme source, {
  bool isTv = false,
}) {
  final isDark = source.brightness == Brightness.dark;
  final background = isDark ? const Color(0xFF080808) : const Color(0xFFF7F7F7);
  final surface = isDark ? const Color(0xFF1C1C1E) : Colors.white;
  final surfaceHigh = isDark
      ? const Color(0xFF27272A)
      : const Color(0xFFF0F0F2);
  final outline = isDark
      ? Colors.white.withValues(alpha: 0.10)
      : Colors.black.withValues(alpha: 0.07);
  final scheme = source.copyWith(
    surface: surface,
    surfaceContainerLowest: background,
    surfaceContainerLow: surface,
    surfaceContainer: surface,
    surfaceContainerHigh: surfaceHigh,
    surfaceContainerHighest: surfaceHigh,
    outline: outline,
    outlineVariant: outline,
  );
  final textTheme = base.textTheme.copyWith(
    headlineMedium: base.textTheme.headlineMedium?.copyWith(
      fontSize: 24,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontSize: 17,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 16),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 14),
  );
  final pillShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(999),
  );

  return base.copyWith(
    colorScheme: scheme,
    // Material 3 深色模式下 primaryColor 默认派生为暗色（近黑），导致
    // 用 Theme.of(context).primaryColor 作背景的确认按钮在深色下看不见。
    // 统一改为 colorScheme.primary（深色下为浅色，配合 onPrimary 文字对比清晰）。
    primaryColor: scheme.primary,
    scaffoldBackgroundColor: background,
    canvasColor: background,
    cardColor: surface,
    splashFactory: InkRipple.splashFactory,
    // TV 模式：给所有 Material 可聚焦控件（InkWell/ListTile/IconButton 等）
    // 设主题 focusColor，让遥控器焦点在 10-foot 距离清晰可见。手机端 isTv
    // 为 false，focusColor 走默认，行为逐字节不变。
    // 0.34/0.18 是为 TV 屏幕调高的可见度（0.22 太浅，3 米外看不出选中）。
    focusColor: isTv
        ? scheme.primary.withValues(alpha: 0.34)
        : null,
    highlightColor: isTv
        ? scheme.primary.withValues(alpha: 0.18)
        : null,
    textTheme: textTheme,
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: 20,
    ),
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
      minVerticalPadding: 14,
      iconColor: scheme.onSurfaceVariant,
      titleTextStyle: textTheme.bodyLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
      subtitleTextStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    dividerTheme: DividerThemeData(
      color: outline,
      thickness: 0.7,
      space: 1,
      indent: 20,
      endIndent: 20,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      modalBackgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 46),
        shape: pillShape,
        elevation: 0,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(64, 46),
        shape: pillShape,
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 46),
        shape: pillShape,
        side: BorderSide(color: outline),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 42),
        shape: pillShape,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(shape: const CircleBorder()),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return isDark ? const Color(0xFF2A2A2C) : const Color(0xFFE7E7EA);
        }
        if (states.contains(WidgetState.selected)) {
          return scheme.primary;
        }
        return isDark ? const Color(0xFF3A3A3C) : const Color(0xFFD8D8DD);
      }),
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return isDark ? const Color(0xFF707074) : const Color(0xFFB8B8BD);
        }
        if (states.contains(WidgetState.selected)) {
          return scheme.onPrimary;
        }
        return isDark ? const Color(0xFFD8D8DC) : Colors.white;
      }),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      trackOutlineWidth: const WidgetStatePropertyAll(0),
      overlayColor: WidgetStatePropertyAll(
        scheme.primary.withValues(alpha: 0.10),
      ),
      splashRadius: 22,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: outline)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      elevation: 0,
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primary.withValues(alpha: 0.14),
      indicatorShape: pillShape,
      labelTextStyle: WidgetStatePropertyAll(
        textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
  );
}

shad.ThemeData buildMiuixShadTheme(ColorScheme scheme) {
  final isDark = scheme.brightness == Brightness.dark;
  final background = isDark ? const Color(0xFF080808) : const Color(0xFFF7F7F7);
  final surface = isDark ? const Color(0xFF1C1C1E) : Colors.white;
  final muted = isDark ? const Color(0xFF2A2A2D) : const Color(0xFFF0F0F2);
  final border = isDark
      ? Colors.white.withValues(alpha: 0.10)
      : Colors.black.withValues(alpha: 0.07);
  final colorScheme = shad.ColorScheme(
    brightness: scheme.brightness,
    background: background,
    foreground: scheme.onSurface,
    card: surface,
    cardForeground: scheme.onSurface,
    popover: surface,
    popoverForeground: scheme.onSurface,
    primary: scheme.primary,
    primaryForeground: scheme.onPrimary,
    secondary: muted,
    secondaryForeground: scheme.onSurface,
    muted: muted,
    mutedForeground: scheme.onSurfaceVariant,
    accent: scheme.primary.withValues(alpha: isDark ? 0.24 : 0.12),
    accentForeground: scheme.primary,
    destructive: scheme.error,
    border: border,
    input: muted,
    ring: scheme.primary,
    chart1: scheme.primary,
    chart2: scheme.tertiary,
    chart3: scheme.secondary,
    chart4: scheme.error,
    chart5: scheme.primaryContainer,
  );
  return isDark
      ? shad.ThemeData.dark(colorScheme: colorScheme, radius: 1.25)
      : shad.ThemeData(colorScheme: colorScheme, radius: 1.25);
}
