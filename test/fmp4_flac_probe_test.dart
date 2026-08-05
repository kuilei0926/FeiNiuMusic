import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/fmp4_flac_probe.dart';

/// 拼一个带 [type] 的 MP4 box：8 字节头 + payload。
Uint8List _box(String type, Uint8List payload) {
  final data = Uint8List(8 + payload.length);
  final bd = ByteData.sublistView(data);
  bd.setUint32(0, data.length);
  for (var i = 0; i < 4; i++) {
    bd.setUint8(4 + i, type.codeUnitAt(i));
  }
  data.setAll(8, payload);
  return data;
}

/// 拼一个 trun box：version/flags(4) + sample_count(4) + sample_size 列表。
Uint8List _trun({int flags = 0x000200, required List<int> sampleSizes}) {
  final payload = ByteData(8 + sampleSizes.length * 4);
  payload.setUint32(0, flags); // version=0, sample_size 位
  payload.setUint32(4, sampleSizes.length);
  for (var i = 0; i < sampleSizes.length; i++) {
    payload.setUint32(8 + i * 4, sampleSizes[i]);
  }
  return _box('trun', payload.buffer.asUint8List());
}

/// 组装一个完整分片：moof(traf(trun)) + mdat（mdat 载荷随意填充）。
Uint8List _segment(List<int> sampleSizes) {
  final traf = _box('traf', _trun(sampleSizes: sampleSizes));
  final moof = _box('moof', traf);
  final mdat = _box('mdat', Uint8List(16));
  final all = Uint8List(moof.length + mdat.length);
  all.setAll(0, moof);
  all.setAll(moof.length, mdat);
  return all;
}

void main() {
  group('fmp4SampleSizes', () {
    test('解析 trun 里的 sample 大小列表', () {
      final sizes = fmp4SampleSizes(_segment([100, 200, 94376]));
      expect(sizes, [100, 200, 94376]);
    });

    test('trun 带 data_offset 位也能解析', () {
      // flags = data_offset(0x001) + sample_size(0x200)；payload 需先写 4 字节 data_offset
      final trunPayload = ByteData(8 + 4 + 2 * 4);
      trunPayload.setUint32(0, 0x000201);
      trunPayload.setUint32(4, 2); // sample_count
      trunPayload.setUint32(8, 1234); // data_offset 字段
      trunPayload.setUint32(12, 32768);
      trunPayload.setUint32(16, 65536);
      final trun = _box('trun', trunPayload.buffer.asUint8List());
      final traf = _box('traf', trun);
      final moof = _box('moof', traf);
      final mdat = _box('mdat', Uint8List(8));
      final all = Uint8List(moof.length + mdat.length);
      all.setAll(0, moof);
      all.setAll(moof.length, mdat);
      expect(fmp4SampleSizes(all), [32768, 65536]);
    });

    test('stsz 固定大小表', () {
      final stsz = ByteData(12 + 3 * 4); // fullbox + 3 个 sample 大小
      stsz.setUint32(0, 0); // fullbox: version/flags
      stsz.setUint32(4, 0); // sample_size = 0 → 走逐条表
      stsz.setUint32(8, 3); // sample_count
      stsz.setUint32(12, 1000);
      stsz.setUint32(16, 2000);
      stsz.setUint32(20, 3000);
      final stbl = _box('stbl', _box('stsz', stsz.buffer.asUint8List()));
      final minf = _box('minf', stbl);
      final mdia = _box('mdia', minf);
      final trak = _box('trak', mdia);
      final moov = _box('moov', trak);
      expect(fmp4SampleSizes(moov), [1000, 2000, 3000]);
    });

    test('非 fMP4 / 空字节 → null', () {
      expect(fmp4SampleSizes(Uint8List(0)), isNull);
      final junk = Uint8List(16)..setAll(0, [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(fmp4SampleSizes(junk), isNull);
    });

    test('只有 init 段（无 trun/stsz）→ null', () {
      final junk = _box('ftyp', Uint8List(4));
      expect(fmp4SampleSizes(junk), isNull);
    });
  });

  group('firstMediaSegment', () {
    final m3u8Url = 'https://nas.example.com/music/api/v1/track/hls/x/preset.m3u8';

    test('跳过 init.mp4 段，取第一个真实分片', () {
      const m3u8 = '#EXTM3U\n'
          '#EXT-X-MAP:URI="init.mp4"\n'
          '#EXTINF:4.0,\n'
          'seg0.mp4\n'
          '#EXTINF:4.0,\n'
          'seg1.mp4\n';
      expect(
        firstMediaSegment(m3u8, m3u8Url),
        'https://nas.example.com/music/api/v1/track/hls/x/seg0.mp4',
      );
    });

    test('相对路径按 m3u8 目录解析', () {
      const m3u8 = '#EXTM3U\n'
          '#EXT-X-MAP:URI="init.mp4"\n'
          '#EXTINF:4.0,\n'
          'seg0.mp4\n';
      expect(
        firstMediaSegment(m3u8, m3u8Url),
        'https://nas.example.com/music/api/v1/track/hls/x/seg0.mp4',
      );
    });

    test('无媒体分片 → null', () {
      const m3u8 = '#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n';
      expect(firstMediaSegment(m3u8, m3u8Url), isNull);
    });
  });
}
