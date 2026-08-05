/// fMP4（fragmented MP4）分片解析：提取音频 sample 大小列表。
///
/// 在 HLS 转码流里，每个媒体分片（`*.m4s` / `*.init.mp4` 之后的段）由
/// `moof + mdat` 组成，`moof/traf/trun` 记录了每个 sample 的字节大小。
/// 对 FLAC 而言一个 sample 就是一个压缩帧，因此最大 sample 大小即最大
/// FLAC 帧大小——用它判断该流是否超出 Android FLAC 解码器输入缓冲上限。
///
/// 同时兼容 `stsz`（完整/非分片 MP4 的 sample 表），见 [fmp4SampleSizes]。
///
/// **现状**：双引擎架构（media_kit 接管 FLAC/DSF）后，生产代码不再调用
/// 本文件——FLAC 由 FFmpeg 解码，无 32KB 帧缓冲限制，不再需要探测帧大小。
/// 保留纯函数与测试（`test/fmp4_flac_probe_test.dart`）以备未来诊断/
/// 复用它检测其他播放器限制。
library;

import 'dart:typed_data';

/// 从 m3u8 文本提取第一个媒体分片地址。
///
/// 跳过 `#EXT-X-MAP`（init.mp4，无音频 sample 大小信息）与 `#EXTINF`
/// 时长为 0 的占位段。相对地址按 m3u8 所在地址解析。
String? firstMediaSegment(String m3u8, String m3u8Url) {
  final lines = m3u8.split('\n').map((l) => l.trim()).toList();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty || line.startsWith('#EXTINF') || line.startsWith('#EXT-X-MAP')) {
      continue;
    }
    if (line.startsWith('#')) continue;
    if (line == '.mp4' || line == 'init.mp4') continue;
    return Uri.parse(m3u8Url).resolve(line).toString();
  }
  return null;
}

/// 已知容器 box（payload 内部嵌套子 box），递归进入；其余按叶子处理。
/// `mdat` 等载荷为原始字节的 box 不递归，避免把音频数据当 box 头解析。
const Set<String> _containerBoxes = {
  'moov', 'trak', 'mdia', 'minf', 'stbl',
  'moof', 'traf', 'mvex', 'edts', 'dinf', 'udta',
  'meco', 'ipro', 'sinf', 'schi', 'tapt', 'strk', 'meta',
};

/// 解析分片中的音频 sample 大小（字节），返回 null 表示未解析出任何
/// sample（非 fMP4 / 损坏 / 仅 init 段）。
List<int>? fmp4SampleSizes(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final sizes = <int>[];
  var parsed = false;
  _walkBoxes(view, 0, bytes.length, 0, (view, payloadStart, payloadEnd, type) {
    if (type == 'trun') {
      final trun = _trunSampleSizes(view, payloadStart, payloadEnd);
      if (trun != null) {
        parsed = true;
        sizes.addAll(trun);
      }
    } else if (type == 'stsz') {
      final stsz = _stszSampleSizes(view, payloadStart, payloadEnd);
      if (stsz != null) {
        parsed = true;
        sizes.addAll(stsz);
      }
    }
  });
  return parsed ? sizes : null;
}

void _walkBoxes(
  ByteData view,
  int start,
  int end,
  int depth,
  void Function(ByteData view, int payloadStart, int payloadEnd, String type)
      visit,
) {
  if (depth > 8) return;
  var offset = start;
  while (offset + 8 <= end) {
    final size32 = view.getUint32(offset);
    final type = _ascii(view, offset + 4, 4);
    int boxSize;
    int headerSize;
    if (size32 == 1) {
      if (offset + 16 > end) return;
      boxSize = view.getUint64(offset + 8);
      headerSize = 16;
    } else if (size32 == 0) {
      boxSize = end - offset;
      headerSize = 8;
    } else {
      boxSize = size32;
      headerSize = 8;
    }
    if (boxSize < headerSize) return; // 损坏
    final payloadStart = offset + headerSize;
    final payloadEnd = offset + boxSize;
    if (payloadEnd > end) return; // 越界，停止解析该路径
    visit(view, payloadStart, payloadEnd, type);
    if (_containerBoxes.contains(type)) {
      _walkBoxes(view, payloadStart, payloadEnd, depth + 1, visit);
    }
    offset += boxSize;
  }
}

/// 解析 `trun`（Track Run）：根据 flags 读取每 sample 的大小。
///
/// 音频分片通常带 `sample_size`(0x000200) 位；缺失该位时返回空列表
/// （该分片不含可用 sample 大小信息）。
List<int>? _trunSampleSizes(ByteData view, int start, int end) {
  if (start + 8 > end) return null;
  final versionAndFlags = view.getUint32(start);
  final flags = versionAndFlags & 0xFFFFFF;
  final sampleCount = view.getUint32(start + 4);
  if (sampleCount > 100000) return null; // 防御异常大值
  var p = start + 8;
  if (flags & 0x000001 != 0) p += 4; // data_offset
  if (flags & 0x000004 != 0) p += 4; // first_sample_flags
  final sizes = <int>[];
  for (var i = 0; i < sampleCount; i++) {
    if (flags & 0x000100 != 0) p += 4; // sample_duration
    if (flags & 0x000200 != 0) {
      if (p + 4 > end) return sizes;
      sizes.add(view.getUint32(p));
      p += 4;
    }
    if (flags & 0x000400 != 0) p += 4; // sample_flags
    if (flags & 0x000800 != 0) p += 4; // sample_composition_time_offset
    if (p > end) return sizes;
  }
  return sizes;
}

/// 解析 `stsz`（Sample Size Box）：固定大小或逐 sample 大小表。
List<int>? _stszSampleSizes(ByteData view, int start, int end) {
  if (start + 12 > end) return null;
  final sampleSize = view.getUint32(start + 4);
  final sampleCount = view.getUint32(start + 8);
  if (sampleCount > 100000) return null; // 防御异常大值
  if (sampleSize != 0) {
    return List<int>.filled(sampleCount, sampleSize);
  }
  if (start + 12 + sampleCount * 4 > end) return null;
  final sizes = <int>[];
  for (var i = 0; i < sampleCount; i++) {
    sizes.add(view.getUint32(start + 12 + i * 4));
  }
  return sizes;
}

String _ascii(ByteData view, int offset, int length) {
  final chars = List<int>.generate(
    length,
    (i) => view.getUint8(offset + i),
  );
  return String.fromCharCodes(chars);
}
