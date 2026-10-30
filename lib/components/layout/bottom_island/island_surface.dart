import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../app/state/settings_state.dart';
import '../../../app/theme/app_glass_theme.dart';
import '../../common/glass_gate.dart';
import '../../common/glass_panel.dart';

class IslandSurface extends StatelessWidget {
  final Widget child;
  final double radius;
  final bool preview;

  const IslandSurface({
    super.key,
    required this.child,
    this.radius = 32,
    this.preview = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final original = GlassPanel(
      borderRadius: BorderRadius.circular(radius),
      backdropBlur: preview ? false : null,
      color: scheme.surfaceContainerHigh.withValues(alpha: .90),
      borderColor: scheme.outlineVariant.withValues(alpha: .22),
      child: child,
    );
    if (preview) return original;
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppGlassSettings.glassBlurStrength,
        AppGlassSettings.glassThickness,
      ]),
      builder: (context, _) => GlassGate(
        original: original,
        glass: GlassContainer(
          shape: LiquidRoundedRectangle(borderRadius: radius),
          clipBehavior: Clip.antiAlias,
          settings: kAppGlassSurfaceSettings.copyWith(
            blur: AppGlassSettings.glassBlurStrength.value,
            thickness: AppGlassSettings.glassThickness.value,
            glassColor: scheme.surface.withValues(alpha: .18),
          ),
          useOwnLayer: true,
          quality: GlassQuality.standard,
          child: child,
        ),
      ),
    );
  }
}
