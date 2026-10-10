// data watchdog — notices the telemetry going quiet while the video keeps playing
//
// the data channel can stall on its own: the comma keeps sending video but no
// cereal messages arrive, and the overlay freezes until the app is reopened.
// webrtcd sends opviewParams every second and deviceState twice a second, so
// any gap longer than [staleAfter] means the data has stopped, even while parked.

/// what the connection manager should do after a check
enum WatchdogAction { none, stale, restart }

class DataWatchdog {
  /// no data for this long: show that the overlay is paused
  static const staleAfter = Duration(milliseconds: 1500);

  /// no data for this long: rebuild the session (doubles after each rebuild that
  /// brings no data back, up to [maxRestartAfter], so a comma that has stopped
  /// sending is not hammered)
  static const restartAfter = Duration(seconds: 4);
  static const maxRestartAfter = Duration(seconds: 30);

  final DateTime Function() _now;
  DateTime _last;
  int _restarts = 0;
  bool _stale = false;

  DataWatchdog({DateTime Function()? now})
      : _now = now ?? DateTime.now,
        _last = (now ?? DateTime.now)();

  /// whether the overlay is currently showing old data
  bool get stale => _stale;

  /// rebuilds in a row that have not brought data back
  int get restarts => _restarts;

  /// how long without data before the next rebuild
  Duration get currentRestartAfter {
    final ms = restartAfter.inMilliseconds * (1 << _restarts.clamp(0, 10));
    return Duration(milliseconds: ms.clamp(0, maxRestartAfter.inMilliseconds));
  }

  /// a session has just connected: start timing from now
  void connected() {
    _last = _now();
  }

  /// a message arrived; returns true when this ends a stale spell
  bool onData() {
    _last = _now();
    _restarts = 0;
    final wasStale = _stale;
    _stale = false;
    return wasStale;
  }

  /// called every half second or so while connected
  WatchdogAction check() {
    final gap = _now().difference(_last);
    if (gap >= currentRestartAfter) {
      _restarts++;
      _last = _now();  // time the next rebuild from this one
      _stale = true;
      return WatchdogAction.restart;
    }
    if (gap >= staleAfter && !_stale) {
      _stale = true;
      return WatchdogAction.stale;
    }
    return WatchdogAction.none;
  }
}
