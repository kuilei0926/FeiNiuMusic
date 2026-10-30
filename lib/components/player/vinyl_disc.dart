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
    child: RotationTransition(
      turns: _rotation,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const SweepGradient(
            colors: [
              Color(0xff101115),
              Color(0xff393b46),
              Color(0xff101115),
              Color(0xff30323d),
              Color(0xff101115),
            ],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: .14)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .25),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            for (final fraction in [.84, .72])
              Container(
                width: widget.size * fraction,
                height: widget.size * fraction,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .07),
                  ),
                ),
              ),
            ClipOval(
              child: MiniPlayerArtwork(
                song: widget.song,
                size: widget.size * .54,
                borderRadius: widget.size,
              ),
            ),
            Container(
              width: widget.size * .09,
              height: widget.size * .09,
              decoration: BoxDecoration(
                color: const Color(0xff101115),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white24, width: .5),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
