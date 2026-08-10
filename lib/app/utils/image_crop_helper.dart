import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_cropper/image_cropper.dart';

/// 封面图片裁剪辅助。
///
/// Android/iOS 走原生 image_cropper 裁剪；其余平台（Windows 桌面等）无
/// image_cropper 实现，直接返回原始文件（不裁剪），避免 MissingPluginException。
///
/// 调用方仅需关心 [CroppedFile] 的 `path`，行为差异对上层透明。
Future<CroppedFile?> cropCoverImage({
  required String sourcePath,
  List<PlatformUiSettings>? uiSettings,
  double? ratioX,
  double? ratioY,
}) async {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
    // 桌面端无原生裁剪：直通所选文件。
    return CroppedFile(sourcePath);
  }
  return ImageCropper().cropImage(
    sourcePath: sourcePath,
    compressFormat: ImageCompressFormat.png,
    compressQuality: 95,
    aspectRatio:
        (ratioX != null && ratioY != null)
            ? CropAspectRatio(ratioX: ratioX, ratioY: ratioY)
            : null,
    uiSettings: uiSettings,
  );
}
