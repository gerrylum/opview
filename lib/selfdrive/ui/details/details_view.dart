// Details view — everything from the old Detailed layout, with the camera in a small
// window. Opened from Details in the menu column; the menu and status bar stay.
//
//   row 1: STEERING (wide)                          | camera window (16:9, PipLayout)
//   row 2: LONGITUDINAL | LEAD | DRIVER & ROAD (three equal cards)
//
// sizes are in the redesign mockup's pixels for a 1770x916 camera area, scaled by `unit`

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/details/details_format.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/onroad/exp_button.dart' show angleColor, torqueColor;
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/throttled.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';

const detailsRefWidth = 1770.0;
const detailsRefHeight = 916.0;
const detailsCameraWidth = 700.0;
const detailsCameraHeight = 394.0;  // 16:9, and the height of the first row
const _pad = 20.0;
const _gap = 16.0;

/// unit for a Details area of [size]
double detailsUnit(Size size) => min(size.width / detailsRefWidth, size.height / detailsRefHeight);

// -- colours --

const _cardColor = Color(0xFF17181A);
const _cardEdge = Color(0x0FFFFFFF);
const _labelColor = Color(0xFF8C8C8C);
const _rowLabelColor = Color(0xFFA6A6A6);
const _traceBackground = Color(0xFF141517);
const _green = Color(0xFF3ADB6D);
const _orange = Color(0xFFFF9A3C);
const _blue = Color(0xFF4D9DFF);
const _red = Color(0xFFFF5A5A);
const _grey = Color(0xFFBFBFBF);
const _dim = Color(0xFF8A8A8A);

/// the steering angle scale runs this far each way: a full turn (Gerry 2026-11-06)
const detailsAngleRange = 360.0;

/// the following gap bar: red under, orange to, green from
const detailsGapTooClose = 0.8;  // s
const detailsGapClose = 1.4;     // s
const detailsGapScale = 3.0;     // s at the right end of the bar

class DetailsView extends StatelessWidget {
  final UIState uiState;

  /// the camera, already laid out for a small window (PipLayout)
  final Widget cameraWindow;

  const DetailsView({super.key, required this.uiState, required this.cameraWindow});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final u = detailsUnit(c.biggest);
      final cards = ThrottledByVersion(
        state: uiState,
        builder: (_) => _Cards(st: uiState, u: u, camera: cameraWindow),
      );
      return Container(
        key: const ValueKey('detailsView'),
        color: const Color(0xFF0B0C0D),
        padding: EdgeInsets.all(_pad * u),
        child: cards,
      );
    });
  }
}

class _Cards extends StatelessWidget {
  final UIState st;
  final double u;
  final Widget camera;

  const _Cards({required this.st, required this.u, required this.camera});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: detailsCameraHeight * u,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _steering()),
              SizedBox(width: _gap * u),
              ClipRRect(
                key: const ValueKey('detailsCamera'),
                borderRadius: BorderRadius.circular(16 * u),
                child: SizedBox(width: detailsCameraWidth * u, height: detailsCameraHeight * u, child: camera),
              ),
            ],
          ),
        ),
        SizedBox(height: _gap * u),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _longitudinal()),
              SizedBox(width: _gap * u),
              Expanded(child: _lead()),
              SizedBox(width: _gap * u),
              Expanded(child: _driverAndRoad()),
            ],
          ),
        ),
      ],
    );
  }

  // -- the cards --

  Widget _steering() {
    final on = st.latActive;
    final (String mode, Color modeColor) = switch (st.steeringMode) {
      LateralMode.angle => ('ANGLE', angleColor),
      LateralMode.torque => ('TORQUE', torqueColor),
      null => ('OFF', _dim),
    };
    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(child: _big('TARGET', on ? formatSteeringAngle(st.targetSteeringAngleDeg) : detailedNoValue)),
          SizedBox(width: 24 * u),
          Expanded(child: _big('ACTUAL', formatSteeringAngle(st.steeringAngleDeg), color: _blue)),
        ]),
        SizedBox(height: 8 * u),
        Row(children: [
          Expanded(child: _kv('Rate', '${st.steeringRateDeg.toStringAsFixed(1)}°/s')),
          SizedBox(width: 26 * u),
          Expanded(child: _kv('Torque cmd', on ? '${(st.torqueOutput * 100).round()}%' : detailedNoValue)),
        ]),
        Row(children: [
          Expanded(child: _kv('Driver torque', st.steeringTorque.toStringAsFixed(1))),
          SizedBox(width: 26 * u),
          Expanded(child: _kv('Lat accel', on ? formatAccelPair(st.latAccelWant, st.latAccelGot) : detailedNoValue)),
        ]),
      ],
    );
    // across the whole card, under the figures and the graph
    final scale = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _legend('STEERING ANGLE', [('▼ target', Colors.white), ('▮ actual', _blue)]),
      SizedBox(height: 4 * u),
      SizedBox(
        height: 60 * u,
        child: CustomPaint(
          key: const ValueKey('detailsAngleScale'),
          painter: SteeringAngleScalePainter(
            target: on ? st.targetSteeringAngleDeg : null,
            actual: st.steeringAngleDeg,
            unit: u,
          ),
        ),
      ),
    ]);
    final right = _trace('LAT ACCEL · 10 s', st.latAccelWantHistory, st.latAccelGotHistory, lo: -2, hi: 2);
    return _card(
      'STEERING',
      [
        _chip(mode, modeColor, solid: true),
        if (on)
          st.lateralSaturated
              ? _chip('SATURATED', _orange, key: const ValueKey('detailsSaturated'))
              : _chip('NOT SATURATED', _green),
      ],
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [Expanded(child: left), SizedBox(width: 28 * u), Expanded(child: right)],
          ),
        ),
        SizedBox(height: 10 * u),
        scale,
      ]),
    );
  }

  Widget _longitudinal() {
    final pedals = [if (st.gasPressed) 'throttle', if (st.brakePressed) 'brake'];
    return _card(
      'LONGITUDINAL',
      [
        _chip(st.cruiseEnabled ? 'ACC ON' : 'ACC OFF', st.cruiseEnabled ? _green : _dim),
        if (st.personality.isNotEmpty) _chip(formatPersonality(st.personality).toUpperCase(), _grey),
      ],
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(child: _big('COMMAND', st.longActive ? _accel(st.accelCommand) : detailedNoValue, unitText: 'm/s²')),
            SizedBox(width: 24 * u),
            Expanded(child: _big('ACTUAL', _accel(st.aEgo), unitText: 'm/s²')),
          ]),
          SizedBox(height: 6 * u),
          _kv('Throttle / brake', pedals.isEmpty ? '— / —' : pedals.join(' + '), color: pedals.isEmpty ? _dim : _orange),
          const Spacer(),
          SizedBox(height: 150 * u, child: _trace('ACCEL · 10 s', st.accelCommandHistory, st.accelActualHistory, lo: -2, hi: 1.5)),
        ],
      ),
    );
  }

  Widget _lead() {
    final lead = enhancedShowsLead(st.status) ? st.activeLead : null;
    double numOf(Map<String, dynamic> m, String k) => (m[k] as num?)?.toDouble() ?? 0.0;
    if (lead == null) {
      return _card(
        'LEAD',
        const [],
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: _big('DISTANCE', enhancedNoLeadValue, color: _dim)),
              SizedBox(width: 24 * u),
              Expanded(child: _big('GAP', enhancedNoLeadValue, color: _dim)),
            ]),
            SizedBox(height: 6 * u),
            for (final label in const ['Closing', 'Lead speed', 'Time to impact', 'Second lead'])
              _kv(label, enhancedNoLeadValue, color: _dim),
            const Spacer(),
            _gapBar(null),
          ],
        ),
      );
    }
    final dRel = numOf(lead, 'dRel'), vRel = numOf(lead, 'vRel');
    final warn = leadWarnColor(leadWarnLevel(dRel, vRel));
    final speedUnit = st.isMetric ? 'km/h' : 'mph';
    final (distance, distanceUnit) = _split(formatLeadDistance(dRel, st.isMetric));
    final gap = st.vEgo > 0.5 ? dRel / st.vEgo : null;
    final ttl = timeToLead(dRel, vRel);
    final two = st.leadTwo;
    var second = detailedNoValue;
    if (two != null && isLeadPresent(two) && (numOf(two, 'dRel') - dRel).abs() > 3.0) {
      second = formatLeadDistance(numOf(two, 'dRel'), st.isMetric);
    }
    return _card(
      'LEAD',
      [_chip(st.leadRadarRecent ? 'RADAR + VISION' : 'VISION', _blue)],
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(child: _big('DISTANCE', distance, unitText: distanceUnit, color: warn)),
            SizedBox(width: 24 * u),
            Expanded(child: _big('GAP', gap == null ? detailedNoValue : gap.toStringAsFixed(1), unitText: 's', color: warn)),
          ]),
          SizedBox(height: 6 * u),
          _kv('Closing', formatLeadRelSpeed(vRel, st.speedConv, speedUnit)),
          _kv('Lead speed', '${max(0.0, (st.vEgo + vRel) * st.speedConv).round()} $speedUnit'),
          _kv('Time to impact', ttl != null && ttl < 99 ? '${ttl.toStringAsFixed(1)} s' : detailedNoValue),
          _kv('Second lead', second, color: second == detailedNoValue ? Colors.white : detailedSecondLeadColor),
          const Spacer(),
          _gapBar(gap),
        ],
      ),
    );
  }

  Widget _driverAndRoad() {
    final seen = st.dmSeen;
    final attention = st.dmAwarenessPercent.clamp(0.0, 100.0).toDouble();
    final probs = st.laneLineProbs;
    double prob(int i) => i < probs.length ? probs[i].clamp(0.0, 1.0).toDouble() : 0.0;
    final signal = st.leftBlinker ? '◀ SIGNAL' : (st.rightBlinker ? 'SIGNAL ▶' : null);
    final bsm = [if (st.leftBlindspot) 'LEFT', if (st.rightBlindspot) 'RIGHT'];
    return _card(
      'DRIVER & ROAD',
      [
        if (seen) st.dmFaceDetected ? _chip('FACE DETECTED', _green) : _chip('FACE NOT SEEN', _orange),
      ],
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _bar('Attention', seen ? attention / 100 : 0, st.dmAwarenessUnfull ? _orange : _green,
              seen ? '${attention.round()}%' : detailedNoValue),
          _kv('Monitoring', st.dmPolicy.isEmpty ? detailedNoValue : st.dmPolicy),
          SizedBox(height: 14 * u),
          _bar('Left lane line', prob(1), const Color(0xFFE6E6E6), probs.length > 1 ? prob(1).toStringAsFixed(2) : detailedNoValue),
          _bar('Right lane line', prob(2), const Color(0xFFE6E6E6), probs.length > 2 ? prob(2).toStringAsFixed(2) : detailedNoValue),
          const Spacer(),
          Wrap(
            spacing: 10 * u,
            runSpacing: 8 * u,
            children: [
              if (signal != null) _chip(signal, _orange),
              if (bsm.isNotEmpty) _chip('BSM ${bsm.join(' ')}', _orange),
              _chip('CURV ${st.curvature.toStringAsFixed(4)}', _grey),
            ],
          ),
        ],
      ),
    );
  }

  // -- pieces --

  /// a card: title and chips along the top, then [body] filling the rest. A body too tall
  /// for a short screen scrolls rather than overflowing
  Widget _card(String title, List<Widget> chips, Widget body) {
    return Container(
      key: ValueKey('detailsCard_$title'),
      padding: EdgeInsets.fromLTRB(24 * u, 20 * u, 24 * u, 16 * u),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(20 * u),
        border: Border.all(color: _cardEdge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(title,
                    style: TextStyle(color: const Color(0xFFCFCFCF), fontSize: 19 * u, fontWeight: FontWeight.w800, letterSpacing: 2 * u, height: 1.0)),
              ),
            ),
            SizedBox(width: 10 * u),
            if (chips.isNotEmpty)
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      for (var i = 0; i < chips.length; i++) ...[if (i > 0) SizedBox(width: 10 * u), chips[i]],
                    ]),
                  ),
                ),
              ),
          ]),
          SizedBox(height: 14 * u),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: c.maxHeight),
                  child: IntrinsicHeight(child: body),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, Color color, {bool solid = false, Key? key}) {
    return Container(
      key: key,
      padding: EdgeInsets.symmetric(horizontal: 14 * u, vertical: 6 * u),
      decoration: BoxDecoration(
        color: solid ? color : color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10 * u),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: solid ? const Color(0xFF0B0C0D) : color,
          fontSize: 18 * u,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8 * u,
          height: 1.0,
        ),
      ),
    );
  }

  /// a large figure with a small label over it and an optional unit after it
  Widget _big(String label, String value, {String unitText = '', Color color = Colors.white}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: TextStyle(color: _labelColor, fontSize: 17 * u, fontWeight: FontWeight.w700, letterSpacing: 1.2 * u, height: 1.0)),
        SizedBox(height: 6 * u),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  style: TextStyle(
                    color: color,
                    fontSize: 56 * u,
                    fontWeight: FontWeight.w700,
                    height: 1.0,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
              if (unitText.isNotEmpty) ...[
                SizedBox(width: 6 * u),
                Text(unitText,
                    style: TextStyle(color: _rowLabelColor, fontSize: 24 * u, fontWeight: FontWeight.w600, height: 1.0)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// one row: label on the left, value on the right, a faint line above
  Widget _kv(String label, String value, {Color color = Colors.white}) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 9 * u),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0x12FFFFFF)))),
      child: Row(children: [
        Expanded(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _rowLabelColor, fontSize: 21 * u, height: 1.0)),
        ),
        SizedBox(width: 8 * u),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(value,
                style: TextStyle(
                  color: color,
                  fontSize: 24 * u,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
          ),
        ),
      ]),
    );
  }

  /// a row with a bar under it, filled to [frac]
  Widget _bar(String label, double frac, Color color, String value) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 8 * u),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0x12FFFFFF)))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _kvInline(label, value, color),
          SizedBox(height: 8 * u),
          // a plain bar (no progress indicator) so the card can measure its height
          Container(
            height: 8 * u,
            decoration: BoxDecoration(color: const Color(0xFF2A2C30), borderRadius: BorderRadius.circular(4 * u)),
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: frac.clamp(0.0, 1.0).toDouble(),
              heightFactor: 1,
              child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4 * u))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kvInline(String label, String value, Color color) {
    return Row(children: [
      Expanded(
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _rowLabelColor, fontSize: 21 * u, height: 1.0)),
      ),
      Text(value, style: TextStyle(color: color, fontSize: 24 * u, fontWeight: FontWeight.w700, height: 1.0)),
    ]);
  }

  /// a small caption with a key of what each mark means
  Widget _legend(String title, List<(String, Color)> keys) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: TextStyle(color: _labelColor, fontSize: 16 * u, fontWeight: FontWeight.w700, letterSpacing: 1 * u, height: 1.0)),
          for (final (text, color) in keys) ...[
            SizedBox(width: 16 * u),
            Text(text, style: TextStyle(color: color, fontSize: 16 * u, height: 1.0)),
          ],
        ],
      ),
    );
  }

  /// the last 10 seconds of what openpilot wanted (white, dashed) against what happened (blue)
  Widget _trace(String title, List<double> want, List<double> got, {required double lo, required double hi}) {
    return Column(
      key: ValueKey('detailsTrace_$title'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _legend(title, [('– – want', Colors.white), ('— actual', _blue)]),
        SizedBox(height: 6 * u),
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: _traceBackground, borderRadius: BorderRadius.circular(12 * u)),
            padding: EdgeInsets.symmetric(vertical: 8 * u),
            child: CustomPaint(
              painter: DetailedTracePainter(want: want, got: got, gotColor: _blue, lo: lo, hi: hi, unit: 2.2 * u),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _gapBar(double? gap) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _legend('FOLLOWING GAP', const []),
        SizedBox(height: 4 * u),
        SizedBox(
          height: 60 * u,
          child: CustomPaint(key: const ValueKey('detailsGapBar'), painter: FollowingGapPainter(gap: gap, unit: u)),
        ),
      ],
    );
  }
}

/// "-0.62"; never "-0.00"
String _accel(double v) {
  final t = v.toStringAsFixed(2);
  return t == '-0.00' ? '0.00' : t;
}

/// "62 ft" -> ("62", "ft")
(String, String) _split(String s) {
  final i = s.indexOf(' ');
  return i < 0 ? (s, '') : (s.substring(0, i), s.substring(i + 1));
}

/// a ruler from a full turn left to a full turn right, squeezed so the few degrees of normal
/// driving still show: a triangle above it where openpilot wants the wheel, and a bar from the
/// centre to where the wheel is
class SteeringAngleScalePainter extends CustomPainter {
  final double? target;  // null: openpilot is not steering
  final double actual;
  final double unit;

  const SteeringAngleScalePainter({required this.target, required this.actual, required this.unit});

  /// the scale's shape: -1..1 for [deg], square-root spaced (±15° is about a fifth of the way out,
  /// ±90° half way, a full turn at the ends)
  static double squeeze(double deg) {
    final a = deg.abs().clamp(0.0, detailsAngleRange).toDouble();
    final s = sqrt(a / detailsAngleRange);
    return deg < 0 ? -s : s;
  }

  /// where [deg] falls across a scale [width] wide
  static double xFor(double deg, double width) => (squeeze(deg) + 1) / 2 * width;

  /// the labelled ticks, and the small ones between
  static const majorTicks = [0, 15, 45, 90, 180, 270, 360];
  static const minorTicks = [5, 10, 20, 30, 60, 120, 150, 210, 240, 300, 330];
  static const labelled = [0, 15, 45, 90, 180, 360];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    // where most driving happens, ±45°
    canvas.drawRRect(
      RRect.fromLTRBR(xFor(-45, w), 10 * unit, xFor(45, w), 38 * unit, Radius.circular(6 * unit)),
      Paint()..color = Colors.white.withValues(alpha: 0.04),
    );
    void tick(double a, bool major) {
      final x = xFor(a, w);
      canvas.drawLine(
        Offset(x, (major ? 14 : 22) * unit),
        Offset(x, 36 * unit),
        Paint()
          ..color = Colors.white.withValues(alpha: major ? 0.55 : 0.2)
          ..strokeWidth = 2 * unit,
      );
    }

    for (final a in minorTicks) {
      tick(-a.toDouble(), false);
      tick(a.toDouble(), false);
    }
    for (final a in majorTicks) {
      tick(-a.toDouble(), true);
      if (a != 0) tick(a.toDouble(), true);
    }
    for (final a in labelled) {
      for (final v in a == 0 ? [0] : [-a, a]) {
        final tp = TextPainter(
          text: TextSpan(text: '${v > 0 ? '+' : ''}$v°', style: TextStyle(color: _labelColor, fontSize: 14 * unit)),
          textDirection: TextDirection.ltr,
        )..layout();
        var x = xFor(v.toDouble(), w) - tp.width / 2;
        x = x.clamp(0.0, max(0.0, w - tp.width)).toDouble();
        tp.paint(canvas, Offset(x, 40 * unit));
      }
    }
    // the wheel: a bar from the centre, and a mark at its end
    final zero = xFor(0, w), at = xFor(actual, w);
    canvas.drawRRect(
      RRect.fromLTRBR(min(zero, at), 24 * unit, max(zero, at), 32 * unit, Radius.circular(4 * unit)),
      Paint()..color = _blue.withValues(alpha: 0.5),
    );
    canvas.drawRRect(
      RRect.fromLTRBR(at - 3 * unit, 12 * unit, at + 3 * unit, 38 * unit, Radius.circular(3 * unit)),
      Paint()..color = _blue,
    );
    final t = target;
    if (t != null) {
      final x = xFor(t, w);
      canvas.drawPath(
        Path()
          ..moveTo(x, 14 * unit)
          ..lineTo(x - 8 * unit, 2 * unit)
          ..lineTo(x + 8 * unit, 2 * unit)
          ..close(),
        Paint()..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(SteeringAngleScalePainter old) => old.target != target || old.actual != actual || old.unit != unit;
}

/// the time gap to the lead on a 0-3 s bar: red when too close, orange when close, green
/// beyond; a white dot at the current gap, none without a lead
class FollowingGapPainter extends CustomPainter {
  final double? gap;
  final double unit;

  const FollowingGapPainter({required this.gap, required this.unit});

  static double xFor(double seconds, double width) => seconds.clamp(0.0, detailsGapScale) / detailsGapScale * width;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final top = 18 * unit, h = 14 * unit;
    final r = Radius.circular(h / 2);
    final zones = [
      (0.0, detailsGapTooClose, _red.withValues(alpha: 0.55)),
      (detailsGapTooClose, detailsGapClose, _orange.withValues(alpha: 0.55)),
      (detailsGapClose, detailsGapScale, _green.withValues(alpha: 0.45)),
    ];
    for (final (a, b, color) in zones) {
      final rect = Rect.fromLTRB(xFor(a, w), top, xFor(b, w), top + h);
      canvas.drawRRect(
        RRect.fromRectAndCorners(rect,
            topLeft: a == 0 ? r : Radius.zero,
            bottomLeft: a == 0 ? r : Radius.zero,
            topRight: b == detailsGapScale ? r : Radius.zero,
            bottomRight: b == detailsGapScale ? r : Radius.zero),
        Paint()..color = color,
      );
    }
    for (final s in const [0.5, 1.0, 1.5, 2.0, 2.5]) {
      final tp = TextPainter(
        text: TextSpan(text: '${s == s.roundToDouble() ? s.toInt() : s} s', style: TextStyle(color: _labelColor, fontSize: 14 * unit)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(xFor(s, w) - tp.width / 2, top + h + 8 * unit));
    }
    final g = gap;
    if (g != null) {
      final c = Offset(xFor(g, w), top + h / 2);
      canvas.drawCircle(c, 12 * unit, Paint()..color = const Color(0xFF0B0C0D));
      canvas.drawCircle(c, 9.5 * unit, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(FollowingGapPainter old) => old.gap != gap || old.unit != unit;
}
