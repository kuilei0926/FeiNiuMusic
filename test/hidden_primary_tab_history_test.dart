import 'package:flutter_test/flutter_test.dart';
import 'package:feiniu_music/app/utils/hidden_primary_tab_history.dart';

void main() {
  test(
    'hidden songs returns to its source, repeated selection keeps source',
    () {
      final history = HiddenPrimaryTabHistory();
      history.selected(3, 2, hiddenSongs: true);
      history.selected(2, 2, hiddenSongs: true);
      expect(history.backDestination(2, hiddenSongs: true), 3);
      expect(history.backDestination(2, hiddenSongs: true), 0);
    },
  );
  test(
    'explicit navigation away clears source rather than creating tab history',
    () {
      final history = HiddenPrimaryTabHistory();
      history.selected(3, 2, hiddenSongs: true);
      history.selected(2, 1, hiddenSongs: true);
      expect(history.backDestination(1, hiddenSongs: true), 0);
      expect(history.backDestination(2, hiddenSongs: true), 0);
    },
  );
  test('switching to five destinations clears stale source', () {
    final history = HiddenPrimaryTabHistory();
    history.selected(4, 2, hiddenSongs: true);
    history.selected(2, 2, hiddenSongs: false);
    expect(history.backDestination(2, hiddenSongs: true), 0);
  });
}
