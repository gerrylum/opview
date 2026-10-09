// redraw part of the screen less often than the rest
//
// the whole driving screen is rebuilt on every model update, about 20 times a
// second. Text readouts cannot be read that fast, and on a slow head unit
// rebuilding and laying them all out every time competes with the video. This
// keeps a readout's last build and reuses it until the state has moved on by
// [every] updates, so it refreshes about 20 / [every] times a second.

import 'package:flutter/widgets.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';

class ThrottledByVersion extends StatefulWidget {
  final UIState state;

  /// rebuild once the state's version has advanced this many updates
  final int every;
  final WidgetBuilder builder;

  const ThrottledByVersion({super.key, required this.state, required this.builder, this.every = 4});

  @override
  State<ThrottledByVersion> createState() => _ThrottledByVersionState();
}

class _ThrottledByVersionState extends State<ThrottledByVersion> {
  Widget? _child;
  int _builtAt = 0;
  UIState? _builtFor;

  @override
  Widget build(BuildContext context) {
    final v = widget.state.version;
    final advanced = v - _builtAt;
    // rebuild when: first time, a different state, enough updates, or a rebuild that
    // was not caused by new data at all (a resize, a setting change)
    final rebuild = _child == null ||
        !identical(_builtFor, widget.state) ||
        advanced == 0 ||
        advanced < 0 ||
        advanced >= widget.every;
    if (rebuild) {
      _builtAt = v;
      _builtFor = widget.state;
      // a new widget instance is built; returning the same one again lets Flutter
      // skip the whole subtree
      _child = RepaintBoundary(child: Builder(builder: widget.builder));
    }
    return _child!;
  }
}
