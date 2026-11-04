// lane guard on the torque bar (design: claude/oprivview-lane-guard-visualization-design.md, option A)
//
// While EVPilot's lane guard is on and openpilot steers, the torque bar gets graduation ticks
// at ±half, a tall white centre detent, a thinner coloured band filling from the centre
// toward lane guard's push, and a painted-line mark just past each end:
//   grey      armed, watching a line or road edge on that side
//   faint     nothing trusted on that side to watch
//   dotted    paused (driver steering, blinker / lane change, slow)
//   amber     pushing away from the lane line on that side (red: a road edge), with a glow
// The ticks, detent and marks stand on the arc's normal, so they fan out with the curve.

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';

const laneGuardLineColor = Color(0xFFFFB020);  // amber
const laneGuardEdgeColor = Color(0xFFFF5A4B);  // red

/// below this share of the limit the band is not drawn and no side counts as pushed from
const laneGuardPushDeadband = 0.02;

enum LaneGuardMark { unguarded, armed, paused, line, edge }

/// what the bar shows of lane guard this frame
class LaneGuardBar {
  final double push;  // -1..1, positive pushes right
  final Color color;  // the band
  final LaneGuardMark left;
  final LaneGuardMark right;

  const LaneGuardBar({required this.push, required this.color, required this.left, required this.right});

  /// null when the bar should be the plain torque bar
  static LaneGuardBar? of(UIState st) {
    if (!st.showsLaneGuard) return null;
    final push = st.laneGuardPush;
    final edge = st.laneGuardSource == 'roadEdge';
    return LaneGuardBar(
      push: push,
      color: edge ? laneGuardEdgeColor : laneGuardLineColor,
      left: laneGuardMark(st, left: true),
      right: laneGuardMark(st, left: false),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LaneGuardBar && other.push == push && other.color == color && other.left == left && other.right == right;

  @override
  int get hashCode => Object.hash(push, color, left, right);
}

/// the mark past one end of the bar
LaneGuardMark laneGuardMark(UIState st, {required bool left}) {
  final push = st.laneGuardPush;
  // a push to the right is away from the left
  final pushedFrom = push > laneGuardPushDeadband ? true : (push < -laneGuardPushDeadband ? false : null);
  if (pushedFrom == left) return st.laneGuardSource == 'roadEdge' ? LaneGuardMark.edge : LaneGuardMark.line;
  if (st.laneGuardPaused != 'none') return LaneGuardMark.paused;
  final guarded = left
      ? st.laneGuardLeftLine || st.laneGuardLeftEdge
      : st.laneGuardRightLine || st.laneGuardRightEdge;
  return guarded ? LaneGuardMark.armed : LaneGuardMark.unguarded;
}

/// the parts drawn on the torque bar's arc. [center] and [midR] are the arc's circle,
/// [top] the angle of its centre, [halfSpan] the angle to each end, [thick] its thickness
class LaneGuardArc {
  final Offset center;
  final double midR;
  final double top;
  final double halfSpan;
  final double thick;

  const LaneGuardArc(this.center, this.midR, this.top, this.halfSpan, this.thick);

  Offset at(double angle, [double r = 0]) =>
      center + Offset(cos(angle), sin(angle)) * (midR + r);

  /// a line across the arc at [angle], [length] long, along the radius there
  void tick(Canvas canvas, double angle, double length, Paint paint) {
    canvas.drawLine(at(angle, -length / 2), at(angle, length / 2), paint);
  }

  /// ticks at ±half, under the fills
  void paintTicks(Canvas canvas) {
    final paint = Paint()
      ..color = const Color(0x99FFFFFF)
      ..strokeWidth = thick * 0.125
      ..strokeCap = StrokeCap.round;
    for (final s in const [-0.5, 0.5]) {
      tick(canvas, top + halfSpan * s, thick * 0.6, paint);
    }
  }

  /// the band from the centre toward the push, thinner than the bar, with a dark outline
  void paintBand(Canvas canvas, double push, Color color) {
    if (push.abs() < laneGuardPushDeadband) return;
    final arc = Rect.fromCircle(center: center, radius: midR);
    final band = thick * 0.42;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    paint
      ..strokeWidth = band + thick * 0.15
      ..color = const Color(0x8C000000);
    canvas.drawArc(arc, top, halfSpan * push, false, paint);
    paint
      ..strokeWidth = band
      ..color = color;
    canvas.drawArc(arc, top, halfSpan * push, false, paint);
  }

  /// the tall white centre detent, over the fills
  void paintDetent(Canvas canvas) {
    tick(
      canvas,
      top,
      thick * 1.9,
      Paint()
        ..color = Colors.white
        ..strokeWidth = thick * 0.15
        ..strokeCap = StrokeCap.round,
    );
  }

  /// angle of the mark just past one end: the round cap, then a gap
  double markAngle({required bool left}) {
    final beyond = (thick / 2 + thick * 0.45) / midR;
    return left ? top - halfSpan - beyond : top + halfSpan + beyond;
  }

  void paintMark(Canvas canvas, LaneGuardMark mark, {required bool left}) {
    final angle = markAngle(left: left);
    final length = thick * 1.6;
    final width = thick * 0.375;
    switch (mark) {
      case LaneGuardMark.paused:
        // three dots along where the mark would be
        final paint = Paint()..color = const Color(0x4DFFFFFF);
        for (final f in const [-0.5, 0.0, 0.5]) {
          canvas.drawCircle(at(angle, length * f), width / 2, paint);
        }
        return;
      case LaneGuardMark.line:
      case LaneGuardMark.edge:
        final color = mark == LaneGuardMark.edge ? laneGuardEdgeColor : laneGuardLineColor;
        tick(
          canvas,
          angle,
          length,
          Paint()
            ..color = color.withValues(alpha: 0.35)
            ..strokeWidth = thick * 0.7
            ..strokeCap = StrokeCap.round,
        );
        tick(
          canvas,
          angle,
          length,
          Paint()
            ..color = color
            ..strokeWidth = width
            ..strokeCap = StrokeCap.round,
        );
        return;
      case LaneGuardMark.armed:
      case LaneGuardMark.unguarded:
        tick(
          canvas,
          angle,
          length,
          Paint()
            ..color = Color.fromRGBO(255, 255, 255, mark == LaneGuardMark.armed ? 0.45 : 0.15)
            ..strokeWidth = width
            ..strokeCap = StrokeCap.round,
        );
    }
  }
}
