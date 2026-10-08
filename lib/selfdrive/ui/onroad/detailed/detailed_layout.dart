// Detailed layout
//
// the Enhanced layout's camera, border, path, lead box, driver icon, torque bar,
// blind spot glow and alerts, with as much of the comma's data as fits around them:
//   - top row, centred on the speed: set speed | speed | speed limit (and the next one)
//   - top right: clock and device health (CPU temperature, memory, disk, Wi-Fi,
//     power draw, calibration)
//   - left: STEERING and DRIVER panels
//   - right: LONGITUDINAL and LEAD panels
//   - bottom: gear, turn signal, blind spot, lane line confidence, path curvature
//
// sizes are in comma four pixels, scaled by `unit`, as in the Enhanced layout.

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:opview/common/transformations.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/clock_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/onroad/exp_button.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/services/app_settings.dart';

// -- sizes, in comma four pixels --

const detailedPanelWidth = 112.0;
const detailedPanelTop = 82.0;        // below the driver icon
const detailedCornerWidth = 82.0;     // clock and device health, top right
const _rowHeight = 9.0;
const _traceHeight = 20.0;

// -- colours --

const _panelColor = Color(0xBD101010);
const _chipColor = Color(0x99101010);
const _labelColor = Color(0xFF9A9A9A);
const _dimColor = Color(0xFF6E6E6E);
const _green = Color(0xFF3ADB6D);
const _orange = Color(0xFFFF9A3C);
const _blue = Color(0xFF4D9DFF);
const _limitPillColor = Color(0xDBCED0D2);  // soft grey-white
const _limitTextColor = Color(0xFF1A1A1A);
const _limitLabelColor = Color(0xFF555555);

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

/// distance to the next speed limit: "0.4 mi" / "650 ft", or "0.6 km" / "350 m"
String formatAheadDistance(double metres, bool isMetric) {
  if (isMetric) {
    return metres >= 1000 ? '${(metres / 1000).toStringAsFixed(1)} km' : '${(metres / 50).round() * 50} m';
  }
  final miles = metres / 1609.344;
  return miles >= 0.1 ? '${miles.toStringAsFixed(1)} mi' : '${(metres * 3.28084 / 50).round() * 50} ft';
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

/// the speed limit to show, in m/s, or null when there is none
double? detailedSpeedLimit(UIState st) {
  if (st.speedLimitValid && st.speedLimit > 0) return st.speedLimit;
  if (st.speedLimitLastValid && st.speedLimitLast > 0) return st.speedLimitLast;
  return null;
}

// -- layout --

class DetailedLayout extends StatelessWidget {
  final UIState uiState;
  final ClockMode clockMode;
  final FrameTransform Function(double w, double h) frameFor;
  final Widget Function(FrameTransform frame) videoBuilder;

  const DetailedLayout({
    super.key,
    required this.uiState,
    required this.clockMode,
    required this.frameFor,
    required this.videoBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final st = uiState;
      final w = constraints.maxWidth, h = constraints.maxHeight;
      final unit = enhancedUnit(Size(w, h));
      final radius = BorderRadius.circular(enhancedCornerRadius * unit);
      final edge = (enhancedBorderWidth + enhancedMargin) * unit;
      final frame = frameFor(w, h);
      final active = st.status != UIStatus.disengaged;
      final hudBottom = edge + (enhancedSpeedPillHeight + 6 + 24) * unit;
      final panelTop = (enhancedBorderWidth + detailedPanelTop) * unit;

      Widget column(List<Widget> children) => Align(
            alignment: Alignment.topCenter,
            // a short screen shrinks the panels rather than cutting them off
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) SizedBox(height: 4 * unit),
                    children[i],
                  ],
                ],
              ),
            ),
          );

      return ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            videoBuilder(frame),
            CustomPaint(
              painter: ModelRendererPainter(
                state: st,
                carSpaceTransform: frame.carToScreen,
                contentRect: Rect.fromLTWH(0, 0, w, h),
                pathEdgeLines: true,
                leadReticle: true,
                leadTagMinTop: hudBottom + 4 * unit,
                showLeads: enhancedShowsLead(st.status),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: h * 0.35,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0x99000000)],
                  ),
                ),
              ),
            ),
            if (st.showBlindSpot && st.leftBlindspot) _glow(unit, left: true),
            if (st.showBlindSpot && st.rightBlindspot) _glow(unit, left: false),
            CustomPaint(
              painter: EnhancedTorqueBarPainter(value: st.torqueBarValue, status: st.status, unit: unit),
            ),

            // top row: set speed | speed | speed limit
            Positioned(
              top: edge,
              left: 0,
              right: 0,
              height: enhancedSpeedPillHeight * unit,
              child: DetailedTopRow(uiState: st, unit: unit),
            ),
            if (st.showRoadName)
              Positioned(
                top: edge + (enhancedSpeedPillHeight + 6) * unit,
                left: 0,
                right: 0,
                child: Center(child: _roadName(st.roadName, unit, w)),
              ),

            if (active && st.dmSeen)
              Positioned(
                left: edge,
                top: edge,
                width: enhancedDriverIconSize * unit,
                height: enhancedDriverIconSize * unit,
                child: Opacity(
                  opacity: st.dmActive ? 1.0 : 0.35,
                  child: CustomPaint(
                    painter: EnhancedDriverIconPainter(
                      coneColor: st.dmActive ? enhancedDriverConeColor(awarenessFull: !st.dmAwarenessUnfull) : null,
                      rotationDeg: st.dmRotationDeg,
                    ),
                    child: Center(
                      child: Icon(Icons.person, color: Colors.white, size: enhancedDriverIconSize * unit * 0.62),
                    ),
                  ),
                ),
              ),

            // clock and device health, top right
            Positioned(
              right: edge,
              top: edge,
              width: detailedCornerWidth * unit,
              child: DetailedDeviceGrid(uiState: st, unit: unit, clockMode: clockMode),
            ),

            // side panels
            Positioned(
              left: edge,
              top: panelTop,
              bottom: edge,
              width: detailedPanelWidth * unit,
              child: column([
                DetailedSteeringPanel(uiState: st, unit: unit),
                DetailedDriverPanel(uiState: st, unit: unit),
              ]),
            ),
            Positioned(
              right: edge,
              top: panelTop,
              bottom: edge,
              width: detailedPanelWidth * unit,
              child: column([
                DetailedLongitudinalPanel(uiState: st, unit: unit),
                DetailedLeadPanel(uiState: st, unit: unit),
              ]),
            ),

            // car and model state, bottom centre
            Positioned(
              left: edge + (detailedPanelWidth + 8) * unit,
              right: edge + (detailedPanelWidth + 8) * unit,
              bottom: 6.5 * unit,
              child: DetailedStatusStrip(uiState: st, unit: unit),
            ),

            EnhancedAlert(uiState: st, unit: unit),

            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: enhancedBorderColor(st.status), width: enhancedBorderWidth * unit),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _glow(double unit, {required bool left}) {
    const glow = Color(0x8CFF9628);
    return Positioned(
      key: ValueKey(left ? 'blindSpotLeft' : 'blindSpotRight'),
      left: left ? 0 : null,
      right: left ? null : 0,
      top: 0,
      bottom: 0,
      width: enhancedGlowWidth * unit,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: left ? Alignment.centerLeft : Alignment.centerRight,
            end: left ? Alignment.centerRight : Alignment.centerLeft,
            colors: const [glow, Color(0x00FF9628)],
          ),
        ),
      ),
    );
  }
}

Widget _roadName(String name, double unit, double screenW) {
  return ConstrainedBox(
    constraints: BoxConstraints(maxWidth: screenW * 0.4),
    child: Container(
      height: 24 * unit,
      padding: EdgeInsets.symmetric(horizontal: 10 * unit),
      decoration: BoxDecoration(color: const Color(0xB3141414), borderRadius: BorderRadius.circular(8 * unit)),
      child: Center(
        widthFactor: 1,
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: HudColors.whiteTranslucent, fontSize: 13 * unit, fontWeight: FontWeight.w600, height: 1.0),
        ),
      ),
    ),
  );
}

// -- top row --

/// set speed | speed | speed limit, with the speed centred
class DetailedTopRow extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const DetailedTopRow({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final gap = SizedBox(width: 8 * unit);
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: st.isCruiseAvailable ? _setSpeed() : const SizedBox.shrink(),
          ),
        ),
        gap,
        _speed(),
        gap,
        Expanded(child: Align(alignment: Alignment.centerLeft, child: _limit())),
      ],
    );
  }

  Widget _box({Key? key, Color color = const Color(0xB3141414), required Widget child}) {
    return Container(
      key: key,
      width: enhancedSidePillWidth * unit,
      height: enhancedSidePillHeight * unit,
      padding: EdgeInsets.symmetric(horizontal: 10 * unit),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12 * unit)),
      child: FittedBox(fit: BoxFit.scaleDown, child: child),
    );
  }

  Widget _speed() {
    return Container(
      height: enhancedSpeedPillHeight * unit,
      constraints: BoxConstraints(minWidth: 74 * unit),
      padding: EdgeInsets.symmetric(horizontal: 12 * unit),
      decoration: BoxDecoration(color: const Color(0xB3141414), borderRadius: BorderRadius.circular(12 * unit)),
      child: Center(
        widthFactor: 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${uiState.displaySpeed.round()}',
              style: TextStyle(color: HudColors.white, fontSize: 33 * unit, fontWeight: FontWeight.bold, height: 0.95),
            ),
            Text(
              uiState.isMetric ? 'km/h' : 'mph',
              style: TextStyle(color: HudColors.grey, fontSize: 11 * unit, fontWeight: FontWeight.w600, height: 1.0),
            ),
          ],
        ),
      ),
    );
  }

  Widget _setSpeed() {
    final st = uiState;
    Color maxColor = HudColors.grey;
    Color speedColor = HudColors.grey;
    if (st.isCruiseSet) {
      speedColor = HudColors.white;
      if (st.status == UIStatus.engaged) {
        maxColor = HudColors.engaged;
      } else if (st.status == UIStatus.disengaged) {
        maxColor = HudColors.disengaged;
      } else if (st.status == UIStatus.override_) {
        maxColor = HudColors.override_;
      }
    }
    return _box(
      key: const ValueKey('detailedSetSpeed'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text('MAX', style: TextStyle(color: maxColor, fontSize: 11 * unit, fontWeight: FontWeight.w600, height: 1.0)),
          SizedBox(width: 5 * unit),
          Text(
            st.isCruiseSet ? '${st.setSpeed.round()}' : detailedNoValue,
            style: TextStyle(color: speedColor, fontSize: 24 * unit, fontWeight: FontWeight.bold, height: 1.0),
          ),
        ],
      ),
    );
  }

  /// the mirror of the set speed pill, light like a road sign: the limit then a small
  /// LIMIT, and the next limit underneath when one is coming up
  Widget _limit() {
    final st = uiState;
    final limit = detailedSpeedLimit(st);
    final hasNext = limit != null && st.speedLimitAheadValid && st.speedLimitAhead > 0 && st.speedLimitAheadDistance > 0;
    final labelStyle = TextStyle(color: _limitLabelColor, fontSize: 10 * unit, fontWeight: FontWeight.w600, height: 1.0);
    return _box(
      key: const ValueKey('detailedSpeedLimit'),
      color: _limitPillColor,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                limit != null ? '${(limit * st.speedConv).round()}' : '– –',
                style: TextStyle(color: _limitTextColor, fontSize: (hasNext ? 22 : 24) * unit, fontWeight: FontWeight.bold, height: 1.0),
              ),
              SizedBox(width: 5 * unit),
              Text('LIMIT', style: labelStyle),
            ],
          ),
          if (hasNext) ...[
            SizedBox(height: 2.5 * unit),
            Text.rich(
              TextSpan(children: [
                const TextSpan(text: 'next '),
                TextSpan(
                  text: '${(st.speedLimitAhead * st.speedConv).round()}',
                  style: const TextStyle(color: _limitTextColor, fontWeight: FontWeight.bold),
                ),
                TextSpan(text: ' in ${formatAheadDistance(st.speedLimitAheadDistance, st.isMetric)}'),
              ]),
              key: const ValueKey('detailedNextLimit'),
              style: TextStyle(color: _limitLabelColor, fontSize: 5.6 * unit, fontWeight: FontWeight.w600, height: 1.0),
            ),
          ],
        ],
      ),
    );
  }
}

// -- panels --

/// dark card with a title, an optional badge, and rows of label and value
class _Panel extends StatelessWidget {
  final double unit;
  final String title;
  final Widget? badge;
  final List<(String, String, Color)> rows;
  final Widget? footer;

  const _Panel({required this.unit, required this.title, this.badge, required this.rows, this.footer});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: detailedPanelWidth * unit,
      padding: EdgeInsets.symmetric(horizontal: 6 * unit, vertical: 4.5 * unit),
      decoration: BoxDecoration(color: _panelColor, borderRadius: BorderRadius.circular(7 * unit)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 8 * unit,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _shrink(alignment: Alignment.centerLeft, Text(
                  title,
                  style: TextStyle(
                    color: const Color(0xFFCFCFCF),
                    fontSize: 5.6 * unit,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.6 * unit,
                    height: 1.0,
                  ),
                )),
                if (badge != null) ...[
                  SizedBox(width: 3 * unit),
                  _shrink(alignment: Alignment.centerRight, badge!),
                ],
              ],
            ),
          ),
          SizedBox(height: 2 * unit),
          for (final (label, value, color) in rows)
            SizedBox(
              height: _rowHeight * unit,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _shrink(
                    alignment: Alignment.centerLeft,
                    Text(label, style: TextStyle(color: _labelColor, fontSize: 5.6 * unit, fontWeight: FontWeight.w600, height: 1.0)),
                  ),
                  SizedBox(width: 3 * unit),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        value,
                        style: TextStyle(
                          color: color,
                          fontSize: 7 * unit,
                          fontWeight: FontWeight.bold,
                          height: 1.0,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (footer != null) footer!,
        ],
      ),
    );
  }
}

/// [child] at its natural size when it fits in its share of a row, scaled down when not
Widget _shrink(Widget child, {required Alignment alignment}) =>
    Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: alignment, child: child));

/// small outlined tag for a panel title
Widget detailedBadge(double unit, String text, Color color, {Key? key}) {
  return Container(
    key: key,
    padding: EdgeInsets.symmetric(horizontal: 3 * unit, vertical: 0.6 * unit),
    decoration: BoxDecoration(
      border: Border.all(color: color, width: 0.5 * unit),
      borderRadius: BorderRadius.circular(4 * unit),
    ),
    child: Text(text, style: TextStyle(color: color, fontSize: 4.6 * unit, fontWeight: FontWeight.bold, height: 1.0)),
  );
}

/// the last ten seconds of two values: [want] dashed white, [got] solid in [gotColor]
Widget _trace(
  double unit, {
  required String label,
  required List<double> want,
  required List<double> got,
  required String wantName,
  required String gotName,
  required Color gotColor,
  required double lo,
  required double hi,
}) {
  Widget key(String name, Color c) => Padding(
        padding: EdgeInsets.only(left: 5 * unit),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 5 * unit, height: 1 * unit, color: c),
          SizedBox(width: 2 * unit),
          Text(name, style: TextStyle(color: _labelColor, fontSize: 4.8 * unit, height: 1.0)),
        ]),
      );
  return Container(
    margin: EdgeInsets.only(top: 3 * unit),
    padding: EdgeInsets.only(top: 3 * unit),
    decoration: BoxDecoration(border: Border(top: BorderSide(color: const Color(0x1FFFFFFF), width: 0.5 * unit))),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _shrink(alignment: Alignment.centerLeft, Text(label, style: TextStyle(color: _labelColor, fontSize: 4.8 * unit, height: 1.0))),
          _shrink(
            alignment: Alignment.centerRight,
            Row(mainAxisSize: MainAxisSize.min, children: [key(wantName, Colors.white), key(gotName, gotColor)]),
          ),
        ]),
        SizedBox(height: 2 * unit),
        SizedBox(
          height: _traceHeight * unit,
          child: CustomPaint(
            painter: DetailedTracePainter(want: want, got: got, gotColor: gotColor, lo: lo, hi: hi, unit: unit),
          ),
        ),
      ],
    ),
  );
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

class DetailedSteeringPanel extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const DetailedSteeringPanel({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final (String mode, Color modeColor) = switch (st.steeringMode) {
      LateralMode.angle => ('ANGLE', angleColor),
      LateralMode.torque => ('TORQUE', torqueColor),
      null => ('OFF', HudColors.grey),
    };
    final on = st.latActive;
    return _Panel(
      unit: unit,
      title: 'STEERING',
      badge: on
          ? (st.lateralSaturated
              ? detailedBadge(unit, 'SATURATED', _orange, key: const ValueKey('detailedSaturated'))
              : detailedBadge(unit, 'NOT SATURATED', _green))
          : null,
      rows: [
        ('Mode', mode, modeColor),
        ('Target', on ? formatSteeringAngle(st.targetSteeringAngleDeg) : detailedNoValue, Colors.white),
        ('Actual', formatSteeringAngle(st.steeringAngleDeg), Colors.white),
        ('Rate', '${st.steeringRateDeg.toStringAsFixed(1)}°/s', Colors.white),
        ('Torque cmd', on ? '${(st.torqueOutput * 100).round()}%' : detailedNoValue, Colors.white),
        ('Driver torque', st.steeringTorque.toStringAsFixed(1), Colors.white),
        ('Lat accel', on ? formatAccelPair(st.latAccelWant, st.latAccelGot) : detailedNoValue, Colors.white),
      ],
      footer: _trace(
        unit,
        label: 'lat accel, 10 s',
        want: st.latAccelWantHistory,
        got: st.latAccelGotHistory,
        wantName: 'want',
        gotName: 'got',
        gotColor: _green,
        lo: -2,
        hi: 2,
      ),
    );
  }
}

class DetailedDriverPanel extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const DetailedDriverPanel({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final seen = st.dmSeen;
    final attention = st.dmAwarenessPercent.round();
    return _Panel(
      unit: unit,
      title: 'DRIVER',
      badge: st.madsSeen
          ? detailedBadge(unit, st.madsEnabled ? 'MADS ON' : 'MADS OFF', st.madsEnabled ? _green : _dimColor)
          : null,
      rows: [
        ('Face', !seen ? detailedNoValue : (st.dmFaceDetected ? 'detected' : 'not seen'),
            st.dmFaceDetected ? _green : _orange),
        ('Attention', seen ? '$attention%' : detailedNoValue, st.dmAwarenessUnfull ? _orange : _green),
        ('Policy', st.dmPolicy.isEmpty ? detailedNoValue : st.dmPolicy, Colors.white),
      ],
    );
  }
}

class DetailedLongitudinalPanel extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const DetailedLongitudinalPanel({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final pedals = [if (st.gasPressed) 'gas', if (st.brakePressed) 'brake'];
    return _Panel(
      unit: unit,
      title: 'LONGITUDINAL',
      badge: st.experimentalMode
          ? detailedBadge(unit, 'EXPERIMENTAL', _orange, key: const ValueKey('detailedExperimental'))
          : detailedBadge(unit, 'CHILL', HudColors.grey, key: const ValueKey('detailedChill')),
      rows: [
        ('ACC', st.cruiseEnabled ? 'on' : 'off', st.cruiseEnabled ? _green : _dimColor),
        ('Personality', formatPersonality(st.personality), Colors.white),
        ('Accel cmd', st.longActive ? formatAccel(st.accelCommand) : detailedNoValue, Colors.white),
        ('Accel actual', formatAccel(st.aEgo), Colors.white),
        ('Gas / brake', pedals.isEmpty ? '— / —' : pedals.join(' + '), pedals.isEmpty ? _dimColor : _orange),
      ],
      footer: _trace(
        unit,
        label: 'accel, 10 s',
        want: st.accelCommandHistory,
        got: st.accelActualHistory,
        wantName: 'cmd',
        gotName: 'actual',
        gotColor: _orange,
        lo: -2,
        hi: 1.5,
      ),
    );
  }
}

class DetailedLeadPanel extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const DetailedLeadPanel({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final shown = enhancedShowsLead(st.status);
    final lead = shown ? st.activeLead : null;
    if (lead == null) {
      const dash = enhancedNoLeadValue, c = Color(0xFF8A8A8A);
      return _Panel(unit: unit, title: 'LEAD', rows: const [
        ('Distance', dash, c),
        ('Gap', dash, c),
        ('Closing', dash, c),
        ('Lead speed', dash, c),
        ('Time to impact', dash, c),
        ('Second lead', dash, c),
      ]);
    }
    double numOf(Map<String, dynamic> m, String k) => (m[k] as num?)?.toDouble() ?? 0.0;
    final dRel = numOf(lead, 'dRel'), vRel = numOf(lead, 'vRel');
    final speedUnit = st.isMetric ? 'km/h' : 'mph';
    final warn = leadWarnColor(leadWarnLevel(dRel, vRel));
    final ttl = timeToLead(dRel, vRel);
    final two = st.leadTwo;
    var second = detailedNoValue;
    if (two != null && isLeadPresent(two) && (numOf(two, 'dRel') - dRel).abs() > 3.0) {
      second = formatLeadDistance(numOf(two, 'dRel'), st.isMetric);
    }
    final radar = lead['radar'] == true;
    return _Panel(
      unit: unit,
      title: 'LEAD',
      badge: detailedBadge(unit, radar ? 'RADAR + VISION' : 'VISION', _blue),
      rows: [
        ('Distance', formatLeadDistance(dRel, st.isMetric), warn),
        ('Gap', formatLeadGap(dRel, st.vEgo), warn),
        ('Closing', formatLeadRelSpeed(vRel, st.speedConv, speedUnit), Colors.white),
        ('Lead speed', '${max(0.0, (st.vEgo + vRel) * st.speedConv).round()} $speedUnit', Colors.white),
        ('Time to impact', ttl != null && ttl < 99 ? '${ttl.toStringAsFixed(1)} s' : detailedNoValue, Colors.white),
        ('Second lead', second, Colors.white),
      ],
    );
  }
}

// -- top right: clock and device health --

class DetailedDeviceGrid extends StatelessWidget {
  final UIState uiState;
  final double unit;
  final ClockMode clockMode;

  const DetailedDeviceGrid({super.key, required this.uiState, required this.unit, required this.clockMode});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final gap = 2 * unit;
    Widget cell(String label, Widget value) => Container(
          height: 10 * unit,
          padding: EdgeInsets.symmetric(horizontal: 3 * unit),
          decoration: BoxDecoration(color: _chipColor, borderRadius: BorderRadius.circular(4 * unit)),
          child: Row(children: [
            Text(label, style: TextStyle(color: _labelColor, fontSize: 4.6 * unit, height: 1.0)),
            SizedBox(width: 2 * unit),
            // a long value shrinks rather than overflowing the cell
            Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: value)),
          ]),
        );
    Text v(String text, [Color color = Colors.white]) => Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 5.6 * unit,
            fontWeight: FontWeight.bold,
            height: 1.0,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
    final seen = st.deviceSeen;
    final calibrated = st.calStatus == 'calibrated';
    final calText = calibrated ? '100%' : (st.calPerc > 0 ? '${st.calPerc}%' : detailedNoValue);
    final rows = [
      [
        cell('CPU', v(seen ? '${st.cpuTempC.round()}°C' : detailedNoValue)),
        cell('Mem', v(seen ? '${st.memoryUsagePercent}%' : detailedNoValue)),
      ],
      [
        cell('Disk', v(seen ? '${(100 - st.freeSpacePercent).round()}%' : detailedNoValue)),
        cell('Wi-Fi', _bars(networkBars(st.networkStrength))),
      ],
      [
        cell('Power', v(seen ? '${st.powerDrawW.toStringAsFixed(1)} W' : detailedNoValue)),
        cell('Calib', v(calText, calibrated ? _green : _orange)),
      ],
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (clockMode != ClockMode.off) ...[
          Container(
            key: const ValueKey('detailedClock'),
            height: 13 * unit,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: _chipColor, borderRadius: BorderRadius.circular(4 * unit)),
            child: ClockText(
              mode: clockMode,
              style: TextStyle(color: Colors.white, fontSize: 9 * unit, fontWeight: FontWeight.bold, height: 1.0),
              suffixStyle: TextStyle(color: _labelColor, fontSize: 5 * unit, fontWeight: FontWeight.w600, height: 1.0),
              suffixGap: 2 * unit,
            ),
          ),
          SizedBox(height: gap),
        ],
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          Row(children: [
            Expanded(child: rows[i][0]),
            SizedBox(width: gap),
            Expanded(child: rows[i][1]),
          ]),
        ],
      ],
    );
  }

  /// four rising bars, lit up to [n]
  Widget _bars(int n) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 4; i++)
          Container(
            margin: EdgeInsets.only(left: i == 0 ? 0 : 0.6 * unit),
            width: 1.6 * unit,
            height: (2 + i * 1.3) * unit,
            color: i < n ? _green : const Color(0x40FFFFFF),
          ),
      ],
    );
  }
}

// -- bottom: car and model state --

class DetailedStatusStrip extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const DetailedStatusStrip({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    Widget chip(String text, Color color) => Container(
          margin: EdgeInsets.symmetric(horizontal: 1.5 * unit),
          padding: EdgeInsets.symmetric(horizontal: 3.5 * unit, vertical: 1.6 * unit),
          decoration: BoxDecoration(color: const Color(0xB3101010), borderRadius: BorderRadius.circular(4 * unit)),
          child: Text(text, style: TextStyle(color: color, fontSize: 5.2 * unit, fontWeight: FontWeight.bold, height: 1.0)),
        );
    final signal = st.leftBlinker && st.rightBlinker
        ? '◀ hazards ▶'
        : st.leftBlinker
            ? '◀ signal'
            : st.rightBlinker
                ? 'signal ▶'
                : null;
    final bsm = [if (st.leftBlindspot) 'L', if (st.rightBlindspot) 'R'];
    // lanes 1 and 2 are the ones either side of the car
    final probs = st.laneLineProbs;
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          chip(formatGear(st.gearShifter), Colors.white),
          if (signal != null) chip(signal, _orange),
          if (bsm.isNotEmpty) chip('BSM ${bsm.join(' ')}', _orange),
          chip('lanes L ${probs[1].toStringAsFixed(2)} · R ${probs[2].toStringAsFixed(2)}', Colors.white),
          chip('curv ${st.curvature.toStringAsFixed(4)}', Colors.white),
        ],
      ),
    );
  }
}
