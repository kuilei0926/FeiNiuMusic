import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../app/utils/background_image_picker.dart';
import '../../components/common/setting_widgets.dart';
import '../../components/feedback/app_toast.dart';
import '../player/widgets/player_background.dart';

class PlayerBackgroundImageSettings extends StatefulWidget {
  const PlayerBackgroundImageSettings({super.key});

  @override
  State<PlayerBackgroundImageSettings> createState() =>
      _PlayerBackgroundImageSettingsState();
}

class _PlayerBackgroundImageSettingsState
    extends State<PlayerBackgroundImageSettings> {
  bool _picking = false;

  Future<void> _pickImage() async {
    setState(() => _picking = true);
    try {
      final selected = await pickBackgroundImage(
        context,
        filenamePrefix: 'player_background',
      );
      if (!mounted || selected == null) return;
      await PlayerBackgroundSettings.setImagePath(selected);
    } catch (error) {
      debugPrint('Pick player background failed: $error');
      if (mounted) {
        AppToast.show(context, '无法读取所选图片，请重新选择', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: PlayerBackgroundSettings.imagePath,
      builder: (context, imagePath, _) {
        final hasImage = imagePath != null && imagePath.trim().isNotEmpty;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppSettingTile(
              title: '播放页背景图片',
              subtitle: _picking
                  ? '正在选择图片…'
                  : hasImage
                  ? '${path.basename(imagePath)} · 清除后恢复流光或渐变'
                  : '独立于应用背景，同时用于播放页与歌词页',
              trailing: const Icon(Icons.image_outlined),
              onTap: _picking ? null : _pickImage,
            ),
            if (hasImage) ...[
              AppSettingTile(
                title: '清除播放页背景',
                trailing: const Icon(Icons.delete_outline_rounded),
                onTap: _picking
                    ? null
                    : () => PlayerBackgroundSettings.setImagePath(null),
              ),
              ValueListenableBuilder<double>(
                valueListenable: PlayerBackgroundSettings.imageMaskOpacity,
                builder: (context, value, _) => AppSettingSlider(
                  title: '播放背景遮罩',
                  description: '数值越大，背景越接近播放页主题底色，文字越容易看清。',
                  value: value * 100,
                  min: 0,
                  max: 100,
                  divisions: 100,
                  valueText: '${(value * 100).round()}%',
                  onChanged: (value) =>
                      PlayerBackgroundSettings.setImageMaskOpacity(value / 100),
                ),
              ),
              ValueListenableBuilder<double>(
                valueListenable: PlayerBackgroundSettings.imageBlurSigma,
                builder: (context, value, _) => AppSettingSlider(
                  title: '播放背景模糊',
                  description: '0 为原图清晰效果',
                  value: value,
                  min: 0,
                  max: 32,
                  divisions: 32,
                  valueText: value.round().toString(),
                  onChanged: PlayerBackgroundSettings.setImageBlurSigma,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
