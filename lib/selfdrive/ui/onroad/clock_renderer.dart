// clock — time of day from this device's own clock (not from the comma)
// not part of the openpilot UI; off unless turned on in settings

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:opview/services/app_settings.dart';

const _fontClock = 56.0;

/// "14:05" or "2:05 PM"
String formatClock(DateTime t, {required bool use24Hour}) {
  final mm = t.minute.toString().padLeft(2, '0');
  if (use24Hour) {
    return '${t.hour.toString().padLeft(2, '0')}:$mm';
  }
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:$mm ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// top right, to the left of the experimental mode button
class ClockRenderer extends StatelessWidget {
  final ClockMode mode;
  final double scale;

  /// time source, replaceable in tests
  final DateTime Function()? now;

  const ClockRenderer({super.key, required this.mode, required this.scale, this.now});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 45 * scale,
      right: 252 * scale,
      child: ClockText(
        mode: mode,
        now: now,
        style: TextStyle(
          color: const Color(0xC8FFFFFF),
          fontSize: _fontClock * scale,
          fontWeight: FontWeight.w600,
          height: 1.0,
          shadows: [Shadow(color: const Color(0x99000000), blurRadius: 8 * scale)],
        ),
      ),
    );
  }
}

/// the time as text, kept current by its own timer; placed by whichever layout uses it
class ClockText extends StatefulWidget {
  final ClockMode mode;
  final TextStyle style;

  /// time source, replaceable in tests
  final DateTime Function()? now;

  const ClockText({super.key, required this.mode, required this.style, this.now});

  @override
  State<ClockText> createState() => _ClockTextState();
}

class _ClockTextState extends State<ClockText> {
  Timer? _timer;
  bool _systemUses24Hour = true;
  String _shown = '';

  @override
  void initState() {
    super.initState();
    // the display only redraws when driving data arrives, so tick on our own as well
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _text() != _shown) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _systemUses24Hour = MediaQuery.of(context).alwaysUse24HourFormat;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _text() {
    final source = widget.now;
    final t = source != null ? source() : DateTime.now();
    final use24Hour = widget.mode == ClockMode.h24 || (widget.mode == ClockMode.system && _systemUses24Hour);
    return formatClock(t, use24Hour: use24Hour);
  }

  @override
  Widget build(BuildContext context) {
    _shown = _text();
    return Text(_shown, style: widget.style);
  }
}
