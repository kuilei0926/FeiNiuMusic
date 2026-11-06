import 'package:flutter/material.dart';

import '../../app/state/song_state.dart';
import '../../app/utils/route_visibility.dart';
import 'mini_player/mini_player_artwork.dart';

class VinylDisc extends StatefulWidget {
  final SongEntity? song;
  final bool playing;
  final double size;

  const VinylDisc({super.key, this.song, this.playing = false, this.size = 44});

  @override
  State<VinylDisc> createState() => _VinylDiscState();
}

class _VinylDiscState extends State<VinylDisc>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  );
  ModalRoute<void>? _route;
  bool _visible = true;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route != route) {
      appRouteObserver.unsubscribe(this);
      _route = route;
      _visible = route?.isCurrent ?? true;
      if (route != null) appRouteObserver.subscribe(this, route);
    }
    _sync();
  }

  @override
  void didUpdateWidget(VinylDisc oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final animate =
        widget.playing &&
        _visible &&
        _foreground &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (animate && !_rotation.isAnimating) {
      _rotation.repeat();
    } else if (!animate) {
      _rotation.stop();
    }
  }

  @override
  void didPush() {
    _visible = true;
    _sync();
  }

  @override
  void didPop() {
    _visible = false;
    _sync();
  }

  @override
  void didPushNext() {
    _visible = false;
    _sync();
  }

  @override
  void didPopNext() {
    _visible = true;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appRouteObserver.unsubscribe(this);
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xff111215),
        border: Border.all(
          color: Colors.white.withValues(alpha: .16),
          width: .7,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .22),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Positioned.fill(child: CustomPaint(painter: _RecordGrooves())),
          RotationTransition(
            turns: _rotation,
            child: ClipOval(
              child: MiniPlayerArtwork(
                song: widget.song,
                size: widget.size * .56,
                borderRadius: widget.size,
              ),
            ),
          ),
          // The light and shadow stay fixed while the label rotates beneath.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(
                    stops: const [0, .12, .25, .5, .62, .75, 1],
                    colors: [
                      Colors.transparent,
                      Colors.white.withValues(alpha: .18),
                      Colors.transparent,
                      Colors.transparent,
                      Colors.white.withValues(alpha: .10),
                      Colors.transparent,
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Container(
            width: widget.size * .075,
            height: widget.size * .075,
            decoration: BoxDecoration(
              color: const Color(0xff111215),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white38, width: .5),
            ),
          ),
        ],
      ),
    ),
  );
}

class _RecordGrooves extends CustomPainter {
  const _RecordGrooves();

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .45;
    for (var i = 0; i < 12; i++) {
      paint.color = Colors.white.withValues(alpha: i.isEven ? .085 : .035);
      canvas.drawCircle(center, radius * (.62 + i * .029), paint);
    }
  }

  @override
  bool shouldRepaint(_RecordGrooves oldDelegate) => false;
}
