/// A single return location for the songs tab omitted by C1/C2.
class HiddenPrimaryTabHistory {
  int? _previousIndex;

  void selected(int current, int next, {required bool hiddenSongs}) {
    if (!hiddenSongs) {
      clear();
    } else if (next != current) {
      _previousIndex = next == 2 ? current : null;
    }
  }

  int backDestination(int current, {required bool hiddenSongs}) {
    final destination = hiddenSongs && current == 2 ? _previousIndex ?? 0 : 0;
    clear();
    return destination;
  }

  void clear() => _previousIndex = null;
}
