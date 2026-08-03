import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/services/player_service.dart';
import '../../app/state/settings_state.dart';
import '../../components/index.dart';
import '../../components/player/player_style_preview.dart';
import '../player/widgets/player_background.dart';

class GradientSettingsPage extends StatefulWidget {
  const GradientSettingsPage({super.key});

  @override
  State<GradientSettingsPage> createState() => _GradientSettingsPageState();
}

class _GradientSettingsPageState extends State<GradientSettingsPage>
    with SignalsMixin {
  late final _saturation = createSignal(1.2);
  late final _hueShift = createSignal(0.0);
  late final _loading = createSignal(true);
  late final _coverColor = createSignal<Color?>(null);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await PlayerBackgroundSettings.ensureLoaded();
    final coverColor = await dominantColorFromAsset(
      PlayerStylePreview.sampleCoverAsset,
    );
    if (!mounted) return;
    _saturation.value = PlayerBackgroundSettings.saturation.value;
    _hueShift.value = PlayerBackgroundSettings.hueShift.value;
    _coverColor.value = coverColor;
    _loading.value = false;
  }

  void _updateSaturation(double value) {
    _saturation.value = value;
    PlayerBackgroundSettings.setSaturation(value);
  }

  void _updateHueShift(double value) {
    _hueShift.value = value;
    PlayerBackgroundSettings.setHueShift(value);
  }

  @override
  Widget build(BuildContext context) {
    return Watch.builder(
      builder: (context) {
        if (_loading.value) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final coverColor = _coverColor.value;
        return AppPageScaffold(
          extendBodyBehindAppBar: true,
          appBar: const AppTopBar(
            title: '流光设置',
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          showMiniPlayer: false,
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              ValueListenableBuilder<PlayerStylePreset>(
                valueListenable: PlayerStyleSettings.stylePreset,
                builder: (context, preset, _) =>
                    _GradientPreview(preset: preset, coverColor: coverColor),
              ),
              const SizedBox(height: 16),
              AppSettingSection(
                title: '参数配置',
                children: [
                  AppSettingSlider(
                    title: '色彩饱和度',
                    value: _saturation.value,
                    min: 0.0,
                    max: 2.0,
                    divisions: 20,
                    valueText: '${(_saturation.value * 100).toInt()}%',
                    description: '数值越大越鲜艳，越小越灰淡',
                    onChanged: _updateSaturation,
                  ),
                  AppSettingSlider(
                    title: '色彩变幻度',
                    value: _hueShift.value,
                    min: 0.0,
                    max: 180.0,
                    divisions: 18,
                    valueText: '${_hueShift.value.toInt()}°',
                    description: '数值越大变化更强，越小更稳定',
                    onChanged: _updateHueShift,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Side-by-side fixed mock following the CURRENT player style: left = the
/// selected style's player preview, right = the lyrics page — both rendered by
/// the shared [PlayerStylePreview] over the REAL 流光 background, so it matches
/// the live effect and reacts to the sliders.
class _GradientPreview extends StatelessWidget {
  final PlayerStylePreset preset;
  final Color? coverColor;

  const _GradientPreview({required this.preset, this.coverColor});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final ratio = (size.shortestSide / size.longestSide).clamp(0.42, 0.7);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: AspectRatio(
            aspectRatio: ratio,
            child: _PreviewScreen(
              label: '播放器',
              coverColor: coverColor,
              child: PlayerStylePreview(preset: preset, fill: true),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: AspectRatio(
            aspectRatio: ratio,
            child: _PreviewScreen(
              label: '歌词页',
              coverColor: coverColor,
              child: PlayerStylePreview(
                preset: preset,
                fill: true,
                lyricsOnly: true,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PreviewScreen extends StatelessWidget {
  final String label;
  final Widget child;
  final Color? coverColor;

  const _PreviewScreen({
    required this.label,
    required this.child,
    this.coverColor,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The actual live background, but locked to the preview's sample cover
          // color (not the currently playing song) so it reacts to the sliders
          // and matches the cover shown above.
          PlayerBackground(
            songSignal: PlayerService.instance.currentSongSignal,
            dominantColor: coverColor,
          ),
          child,
          Positioned(
            left: 10,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
