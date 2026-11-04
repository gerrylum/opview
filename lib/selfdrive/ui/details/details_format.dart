// the figures behind the Details view: how they are written, and the 10 second traces
// (these came from the Detailed layout, which the Details view replaced)

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';

/// the second lead car: its box on the road and its row in the LEAD panel. Teal, unlike any
/// warning or border colour, as openpilot only follows the first lead
const detailedSecondLeadColor = Color(0xFF2DD4BF);

/// shown for a value that is not available right now
const detailedNoValue = '–';

// -- formatting --

/// "-0.42 m/s²"; never "-0.00"
String formatAccel(double v) {
  final text = v.toStringAsFixed(2);
  return '${text == '-0.00' ? '0.00' : text} m/s²';
}

/// "0.82 / 0.79"
String formatAccelPair(double want, double got) {
  String f(double v) {
    final t = v.toStringAsFixed(2);
    return t == '-0.00' ? '0.00' : t;
  }
  return '${f(want)} / ${f(got)}';
}

/// relaxed / standard / aggressive, capitalised
String formatPersonality(String p) => p.isEmpty ? detailedNoValue : '${p[0].toUpperCase()}${p.substring(1)}';

/// P R N D, or the name for anything else
String formatGear(String gear) {
  switch (gear) {
    case 'park':
      return 'P';
    case 'reverse':
      return 'R';
    case 'neutral':
      return 'N';
    case 'drive':
      return 'D';
    case '':
    case 'unknown':
      return detailedNoValue;
    default:
      return gear.toUpperCase();
  }
}

/// seconds until the lead is reached at the current closing speed, or null when not closing
double? timeToLead(double dRel, double vRel) => vRel < -0.1 ? dRel / -vRel : null;

/// Wi-Fi / cell strength as 0..4 bars
int networkBars(String strength) {
  switch (strength) {
    case 'poor':
      return 1;
    case 'moderate':
      return 2;
    case 'good':
      return 3;
    case 'great':
      return 4;
    default:
      return 0;
  }
}

/// two lines over a fixed range, with a faint zero line
class DetailedTracePainter extends CustomPainter {
  final List<double> want;
  final List<double> got;
  final Color gotColor;
  final double lo;
  final double hi;
  final double unit;
  final int _wantLength;
  final double _wantLast;
  final double _gotLast;

  DetailedTracePainter({
    required this.want,
    required this.got,
    required this.gotColor,
    required this.lo,
    required this.hi,
    required this.unit,
  })  : _wantLength = want.length,
        _wantLast = want.isEmpty ? 0 : want.last,
        _gotLast = got.isEmpty ? 0 : got.last;

  @override
  void paint(Canvas canvas, Size size) {
    double y(double v) => size.height - ((v.clamp(lo, hi) - lo) / (hi - lo)) * size.height;
    canvas.drawLine(
      Offset(0, y(0)),
      Offset(size.width, y(0)),
      Paint()
        ..color = const Color(0x2EFFFFFF)
        ..strokeWidth = 0.5 * unit,
    );
    // always spread over the full ten seconds, so the newest sample is at the right edge
    final dx = size.width / (UIState.historyLength - 1);
    Path line(List<double> values) {
      final path = Path();
      final start = UIState.historyLength - values.length;
      for (var i = 0; i < values.length; i++) {
        final p = Offset((start + i) * dx, y(values[i]));
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      return path;
    }

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    if (got.length > 1) {
      stroke
        ..color = gotColor
        ..strokeWidth = 1.4 * unit;
      canvas.drawPath(line(got), stroke);
    }
    if (want.length > 1) {
      // dashed: draw every other stretch of the path
      final dash = 2.5 * unit, gap = 2 * unit;
      stroke
        ..color = Colors.white
        ..strokeWidth = 1.1 * unit;
      for (final metric in line(want).computeMetrics()) {
        for (double d = 0; d < metric.length; d += dash + gap) {
          canvas.drawPath(metric.extractPath(d, min(d + dash, metric.length)), stroke);
        }
      }
    }
  }

  @override
  bool shouldRepaint(DetailedTracePainter old) =>
      old._wantLength != _wantLength || old._wantLast != _wantLast || old._gotLast != _gotLast || old.unit != unit;
}
