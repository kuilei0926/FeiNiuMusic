import 'package:flutter/material.dart';

import '../../app/state/settings_state.dart';
import '../../app/theme/app_visual_theme.dart';
import 'glass_panel.dart';
import 'labeled_slider.dart';

class AppSettingSection extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final bool showDividers;

  const AppSettingSection({
    super.key,
    this.title,
    required this.children,
    this.margin,
    this.padding,
    this.showDividers = false,
  });

  @override
  Widget build(BuildContext context) {
    final miuix = context.usesMiuix;
    final content = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0 && showDividers) {
        content.add(const Divider(height: 1));
      }
      content.add(children[i]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: EdgeInsets.fromLTRB(miuix ? 6 : 0, 0, 0, 8),
            child: Text(
              title!,
              style: miuix
                  ? Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    )
                  : Theme.of(context).textTheme.titleMedium,
            ),
          ),
        GlassPanel(
          // 设置分组在滚动列表内：背景逐帧变化，BackdropFilter 每帧重采样
          // 是滚动掉帧主因。显式关闭，改用纯色半透明面板（appPanelColorSolid）。
          backdropBlur: false,
          borderRadius: BorderRadius.circular(miuix ? 24 : 16),
          blurSigma: miuix ? 0.2 : 0.8,
          boxShadow: miuix ? const [] : null,
          borderColor: miuix ? Colors.transparent : null,
          child: Padding(
            padding: margin ?? EdgeInsets.zero,
            child: Padding(
              padding: padding ?? EdgeInsets.zero,
              child: Column(children: content),
            ),
          ),
        ),
      ],
    );
  }
}

class AppSettingTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  const AppSettingTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final miuix = context.usesMiuix;
    final isTv = AppLayoutSettings.tvMode.value;
    // 用透明 Material 包住 ListTile，让它的背景/涟漪画在自己的 Material
    // 上，避免中间的带色面板容器（GlassPanel）触发 SDK 的
    // "ListTile background color or ink splashes may be invisible" 断言。
    return Material(
      color: Colors.transparent,
      child: ListTile(
        dense: isTv ? false : !miuix,
        // TV 端加大设置行高度，方便遥控器聚焦命中。
        minVerticalPadding: isTv ? 16 : null,
        contentPadding: EdgeInsets.symmetric(
          horizontal: isTv ? 24 : (miuix ? 20 : 16),
          vertical: isTv ? 6 : 0,
        ),
        leading: leading,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: trailing,
        onTap: onTap,
      ),
    );
  }
}

class AppSettingSwitchTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const AppSettingSwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return AppSettingTile(
      title: title,
      subtitle: subtitle,
      trailing: Switch.adaptive(value: value, onChanged: onChanged),
      onTap: onChanged == null ? null : () => onChanged!(!value),
    );
  }
}

class AppSettingCheckboxTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const AppSettingCheckboxTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return AppSettingTile(
      title: title,
      subtitle: subtitle,
      trailing: SizedBox(
        width: 40,
        child: Align(
          alignment: Alignment.center,
          child: Checkbox(
            value: value,
            onChanged: onChanged == null ? null : (v) => onChanged!(v ?? value),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
      ),
      onTap: onChanged == null ? null : () => onChanged!(!value),
    );
  }
}

class AppSettingSlider extends StatelessWidget {
  final String title;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? valueText;
  final String? description;
  final ValueChanged<double> onChanged;

  const AppSettingSlider({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    this.valueText,
    this.description,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LabeledSlider(
      title: title,
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      valueText: valueText,
      description: description,
      onChanged: onChanged,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
    );
  }
}
