import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'image_crop_helper.dart';

Future<String?> pickBackgroundImage(
  BuildContext context, {
  required String filenamePrefix,
}) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.image,
    allowMultiple: false,
  );
  final file = result?.files.first;
  if (file?.path == null) return null;

  // Use the device's short/long dimensions so the crop frame matches what
  // the wallpaper will actually be painted into. Reading it once here is
  // fine — no need to react to rotation while the cropper UI is on screen.
  if (!context.mounted) return null;
  final size = MediaQuery.of(context).size;

  final cropped = await cropCoverImage(
    sourcePath: file!.path!,
    ratioX: size.width,
    ratioY: size.height,
    uiSettings: [
      AndroidUiSettings(
        toolbarTitle: '裁剪背景',
        hideBottomControls: true,
        lockAspectRatio: true,
        // Explicit toolbar / status bar tint so the confirm/cancel icons
        // never blend into the phone's system bar (which was the "点几下才
        // 点得到" bug on notched screens).
        toolbarColor: const Color(0xFF212121),
        statusBarLight: false,
        toolbarWidgetColor: Colors.white,
        activeControlsWidgetColor: Colors.white,
        backgroundColor: Colors.black,
      ),
      IOSUiSettings(
        title: '裁剪背景',
        aspectRatioLockEnabled: true,
        resetAspectRatioEnabled: false,
      ),
    ],
  );
  if (cropped == null) return null;

  // uCrop writes to a cache directory that OS may sweep; copy the output
  // into our app documents dir so the background survives across launches.
  // Desktop platforms return the original file, so keep its extension
  // instead of labelling JPEG/HEIC bytes as PNG.
  final docs = await getApplicationDocumentsDirectory();
  final extension = path.extension(cropped.path);
  final targetPath = path.join(
    docs.path,
    '${filenamePrefix}_${DateTime.now().microsecondsSinceEpoch}'
    '${extension.isEmpty ? '.png' : extension}',
  );
  await File(cropped.path).copy(targetPath);
  return targetPath;
}
