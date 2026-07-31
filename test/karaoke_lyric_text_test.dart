import 'package:flutter/material.dart';
import 'package:flutter_lyric/core/lyric_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/components/player/karaoke_lyric_text.dart';

KaraokeHighlightPainter _highlightPainter(WidgetTester tester) {
  final customPaint = tester.widget<CustomPaint>(
    find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is KaraokeHighlightPainter,
    ),
  );
  return customPaint.painter! as KaraokeHighlightPainter;
}

LyricLine _buildLine() {
  return LyricLine(
    start: const Duration(milliseconds: 0),
    text: '一二三四五',
    words: [
      for (var i = 0; i < 5; i++)
        LyricWord(
          text: '一二三四五'[i],
          start: Duration(milliseconds: i * 200),
          end: Duration(milliseconds: i * 200 + 200),
        ),
    ],
  );
}

Widget _buildSubject({
  required ValueNotifier<Duration> position,
  Duration? lineEnd,
}) {
  return MaterialApp(
    home: Scaffold(
      body: KaraokeLyricText(
        line: _buildLine(),
        position: position,
        lineEnd: lineEnd,
        style: const TextStyle(fontSize: 16, color: Colors.black),
        highlightColor: Colors.red,
        maxLines: 1,
      ),
    ),
  );
}

void main() {
  testWidgets('KaraokeLyricText fills nothing before the first word', (
    tester,
  ) async {
    final position = ValueNotifier<Duration>(const Duration(milliseconds: 0));
    await tester.pumpWidget(_buildSubject(position: position));
    // Let the initial fill animation settle.
    await tester.pumpAndSettle();
    expect(_highlightPainter(tester).fraction, 0.0);
  });

  testWidgets('KaraokeLyricText shows a hard-edged highlight mid-line', (
    tester,
  ) async {
    final position = ValueNotifier<Duration>(const Duration(milliseconds: 300));
    await tester.pumpWidget(
      _buildSubject(
        position: position,
        lineEnd: const Duration(milliseconds: 1000),
      ),
    );
    // Let the initial fill animation settle.
    await tester.pumpAndSettle();
    final fraction = _highlightPainter(tester).fraction;
    expect(fraction, greaterThan(0.0));
    expect(fraction, lessThan(1.0));
  });

  testWidgets('KaraokeLyricText fully highlights after line end', (
    tester,
  ) async {
    final position = ValueNotifier<Duration>(
      const Duration(milliseconds: 1000),
    );
    await tester.pumpWidget(
      _buildSubject(
        position: position,
        lineEnd: const Duration(milliseconds: 1000),
      ),
    );
    // Let the initial fill animation settle.
    await tester.pumpAndSettle();
    expect(_highlightPainter(tester).fraction, 1.0);
  });
}
