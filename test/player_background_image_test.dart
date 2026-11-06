import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals/signals.dart';

import 'package:feiniu_music/app/state/settings_background_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/components/common/setting_widgets.dart';
import 'package:feiniu_music/pages/player/widgets/player_background.dart';
import 'package:feiniu_music/pages/settings/player_background_image_settings.dart';

class _ImagePicker extends FilePicker {
  FilePickerResult? result;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => result;
}

class _DocumentsPath extends PathProviderPlatform {
  final String path;
  _DocumentsPath(this.path);

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late File image;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PlayerBackgroundSettings.resetForTest();
    AppBackgroundSettings.resetForTest();
    temp = Directory.systemTemp.createTempSync('player-background-test-');
    image = File('${temp.path}/background.png');
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
    final picture = recorder.endRecording();
    final raster = await picture.toImage(2, 2);
    final bytes = await raster.toByteData(format: ui.ImageByteFormat.png);
    image.writeAsBytesSync(bytes!.buffer.asUint8List());
    raster.dispose();
    picture.dispose();
  });

  tearDown(() {
    PlayerBackgroundSettings.resetForTest();
    AppBackgroundSettings.resetForTest();
    temp.deleteSync(recursive: true);
  });

  test('image settings persist independently of the app background', () async {
    await AppBackgroundSettings.ensureLoaded();
    await AppBackgroundSettings.setBackgroundImagePath('/app-background.jpg');
    await PlayerBackgroundSettings.ensureLoaded();
    expect(PlayerBackgroundSettings.imagePath.value, isNull);
    await PlayerBackgroundSettings.setImagePath(image.path);
    await PlayerBackgroundSettings.setImageMaskOpacity(0.65);
    await PlayerBackgroundSettings.setImageBlurSigma(12);
    PlayerBackgroundSettings.resetForTest();
    await PlayerBackgroundSettings.ensureLoaded();
    expect(PlayerBackgroundSettings.imagePath.value, image.path);
    expect(PlayerBackgroundSettings.imageMaskOpacity.value, 0.65);
    expect(PlayerBackgroundSettings.imageBlurSigma.value, 12);
    expect(
      AppBackgroundSettings.backgroundImagePath.value,
      '/app-background.jpg',
    );
    await PlayerBackgroundSettings.setImagePath(null);
    PlayerBackgroundSettings.resetForTest();
    await PlayerBackgroundSettings.ensureLoaded();
    expect(PlayerBackgroundSettings.imagePath.value, isNull);
    expect(PlayerBackgroundSettings.dynamicGradientEnabled.value, isTrue);
  });

  test('mask and blur values are bounded and empty selection clears', () async {
    SharedPreferences.setMockInitialValues({
      'player_background_image_mask': 2.0,
      'player_background_image_blur': -10.0,
    });
    await PlayerBackgroundSettings.ensureLoaded();
    expect(PlayerBackgroundSettings.imageMaskOpacity.value, 1);
    expect(PlayerBackgroundSettings.imageBlurSigma.value, 0);
    await PlayerBackgroundSettings.setImageMaskOpacity(-1);
    await PlayerBackgroundSettings.setImageBlurSigma(100);
    expect(PlayerBackgroundSettings.imageMaskOpacity.value, 0);
    expect(PlayerBackgroundSettings.imageBlurSigma.value, 32);
    await PlayerBackgroundSettings.setImagePath(image.path);
    await PlayerBackgroundSettings.setImagePath(' ');
    expect(PlayerBackgroundSettings.imagePath.value, isNull);
  });

  Future<void> pumpBackground(WidgetTester tester, {bool custom = true}) async {
    final songSignal = signal<SongEntity?>(null);
    addTearDown(songSignal.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.expand(
          child: PlayerBackground(
            songSignal: songSignal,
            useCustomImage: custom,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await precacheImage(
        FileImage(image),
        tester.element(find.byType(PlayerBackground)),
      );
    });
    await tester.pump();
  }

  testWidgets('selecting image overrides gradient, clearing restores it', (
    tester,
  ) async {
    await PlayerBackgroundSettings.ensureLoaded();
    await PlayerBackgroundSettings.setImagePath(image.path);
    await pumpBackground(tester);
    final images = tester.widgetList<Image>(find.byType(Image));
    expect(images, hasLength(1));
    expect(images.single.image, isA<ResizeImage>());
    expect(find.byType(ImageFiltered), findsNothing);
    PlayerBackgroundSettings.imageBlurSigma.value = 8;
    await tester.pump();
    expect(find.byType(ImageFiltered), findsOneWidget);
    PlayerBackgroundSettings.imagePath.value = null;
    PlayerBackgroundSettings.dynamicGradientEnabled.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.byType(DecoratedBox), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('mask follows playback theme ${mode.name}', (tester) async {
      await PlayerBackgroundSettings.ensureLoaded();
      await PlayerBackgroundSettings.setImagePath(image.path);
      PlayerBackgroundSettings.playbackThemeMode.value = mode;
      PlayerBackgroundSettings.imageMaskOpacity.value = 0.7;
      await pumpBackground(tester);
      final mask = tester
          .widgetList<ColoredBox>(find.byType(ColoredBox))
          .where((box) => (box.color.a - 0.7).abs() < 0.001)
          .single;
      expect(
        mask.color,
        (mode == ThemeMode.dark ? Colors.black : Colors.white).withValues(
          alpha: 0.7,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('missing and corrupt images fall back without crashing', (
    tester,
  ) async {
    await PlayerBackgroundSettings.ensureLoaded();
    await PlayerBackgroundSettings.setDynamicGradientEnabled(false);
    await PlayerBackgroundSettings.setImagePath('${temp.path}/missing.png');
    await pumpBackground(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DecoratedBox), findsWidgets);
    expect(tester.takeException(), isNull);
    final corrupt = File('${temp.path}/corrupt.png')
      ..writeAsStringSync('invalid image');
    PlayerBackgroundSettings.imagePath.value = corrupt.path;
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DecoratedBox), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gradient preview can opt out of the selected image', (
    tester,
  ) async {
    await PlayerBackgroundSettings.ensureLoaded();
    await PlayerBackgroundSettings.setDynamicGradientEnabled(false);
    await PlayerBackgroundSettings.setImagePath(image.path);
    await pumpBackground(tester, custom: false);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(DecoratedBox), findsWidgets);
  });

  testWidgets(
    'selection copies image into app storage and cancellation preserves it',
    (tester) async {
      await PlayerBackgroundSettings.ensureLoaded();
      final picker = _ImagePicker();
      FilePicker.platform = picker;
      final originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _DocumentsPath(temp.path);
      addTearDown(() => PathProviderPlatform.instance = originalPaths);
      picker.result = FilePickerResult([
        PlatformFile(
          name: 'source.png',
          size: image.lengthSync(),
          path: image.path,
        ),
      ]);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: PlayerBackgroundImageSettings()),
        ),
      );
      await tester.tap(find.text('播放页背景图片'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      final selected = PlayerBackgroundSettings.imagePath.value!;
      expect(selected, isNot(image.path));
      expect(File(selected).parent.path, temp.path);
      expect(File(selected).readAsBytesSync(), image.readAsBytesSync());
      picker.result = null;
      await tester.tap(find.text('播放页背景图片'));
      await tester.pump();
      expect(PlayerBackgroundSettings.imagePath.value, selected);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings sliders update live and clear restores default controls',
    (tester) async {
      await PlayerBackgroundSettings.ensureLoaded();
      await PlayerBackgroundSettings.setImagePath(image.path);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: PlayerBackgroundImageSettings()),
        ),
      );
      await tester.pump();
      AppSettingSlider slider(String title) => tester.widget<AppSettingSlider>(
        find.ancestor(
          of: find.text(title),
          matching: find.byType(AppSettingSlider),
        ),
      );
      slider('播放背景遮罩').onChanged(60);
      slider('播放背景模糊').onChanged(10);
      await tester.pump();
      expect(PlayerBackgroundSettings.imageMaskOpacity.value, 0.6);
      expect(PlayerBackgroundSettings.imageBlurSigma.value, 10);
      await tester.tap(find.text('清除播放页背景'));
      await tester.pumpAndSettle();
      expect(PlayerBackgroundSettings.imagePath.value, isNull);
      expect(find.text('播放背景遮罩'), findsNothing);
      expect(find.text('播放背景模糊'), findsNothing);
      expect(find.text('播放页背景图片'), findsOneWidget);
    },
  );
}
