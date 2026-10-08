// comma four style layout, extended for a larger screen
//
// follows the comma four's own driving screen (openpilot selfdrive/ui/mici/onroad)
// as it appears in device-screen clips: the camera fills the screen inside a
// rounded border in the engagement colour, with
//   - driver monitoring icon, top left
//   - speed in a dark pill, top centre
//   - steering readout, bottom left: angle or torque mode, target and actual angle
//     (the device shows a steering wheel icon here)
//   - torque bar, bottom centre
//   - confidence ball on the right edge: high and green when the model is
//     confident, sinking and turning orange then red as a takeover gets likelier
// and, as extras for a larger screen, the set speed and clock either side of the
// speed pill and the road name under it.
//
// device measurements are in comma four pixels (240 tall), scaled by `unit`.
//
// simplified or not ported yet: the device's own path and lane line style (the
// Classic overlay is drawn instead), and the icons are drawn here, not taken from
// the device's image files. The confidence ball needs the model's disengage
// predictions, which webrtcd sends only on newer opview branches; without them it
// stays at the bottom and shows engagement state only.

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:opview/common/transformations.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/alert_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/clock_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/exp_button.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/turn_signal_renderer.dart';
import 'package:opview/services/app_settings.dart';

// -- comma four screen (mici/onroad) --

const miciScreenWidth = 536.0;
const miciScreenHeight = 240.0;
const miciCornerRadius = 12.0;   // the device's is 24; halved for a large screen
const miciBorderWidth = 4.0;
const miciBallRadius = 14.0;     // the device's is 24
const miciBallPadding = 4.0;     // dark disc showing around the ball
const miciDriverIconSize = 54.0;
const miciSpeedPillHeight = 52.0;
const miciMargin = 16.0;         // gap between the border and the corner elements

// torque_bar.py
const _torqueAngleSpanDeg = 12.7;
const _torqueRadius = 1200.0;

// -- colours --

const _pillColor = Color(0xB3141414);
const _discColor = Color(0xE6101010);

/// border around the screen, by engagement state
Color miciBorderColor(UIStatus status) {
  switch (status) {
    case UIStatus.disengaged:
      return const Color(0xFF6E6E6E);  // grey
    case UIStatus.override_:
      return const Color(0xFFB4B4B4);
    case UIStatus.engaged:
      return const Color(0xFF17C653);  // green
    case UIStatus.latOnly:
      return const Color(0xFF4D9DFF);  // blue: steering only
    case UIStatus.longOnly:
      return const Color(0xFF961CA8);  // purple: cruise only
  }
}

/// top and bottom colour of the confidence ball (confidence_ball.py), or null when
/// hidden. While fully engaged the colour follows [confidence]
List<Color>? miciBallColors(UIStatus status, {double confidence = 1.0}) {
  switch (status) {
    case UIStatus.disengaged:
      return null;
    case UIStatus.engaged:
      if (confidence > 0.5) return const [Color(0xFF00FFCC), Color(0xFF00FF26)];  // green
      if (confidence > 0.2) return const [Color(0xFFFFC800), Color(0xFFFF7300)];  // orange
      return const [Color(0xFFFF0015), Color(0xFFFF0059)];                        // red
    case UIStatus.override_:
      return const [Color(0xFFFFFFFF), Color(0xFF525252)];
    case UIStatus.latOnly:
      return const [Color(0xFF4D9DFF), Color(0xFF4D9DFF)];
    case UIStatus.longOnly:
      return const [Color(0xFF961CA8), Color(0xFF961CA8)];
  }
}

/// cone on the driver monitoring icon: green while attention is full, orange once
/// it starts to run down (driver_state.py CONE_COLOR_*)
Color miciDriverConeColor({required bool awarenessFull}) {
  return awarenessFull ? const Color(0xFF00FF40) : const Color(0xFFFF7300);
}

// -- geometry --

/// comma four pixel size on a screen: its 536x240 display scaled to fit inside
double miciUnit(Size screen) => min(screen.height / miciScreenHeight, screen.width / miciScreenWidth);

// -- layout --

class MiciExtendedLayout extends StatelessWidget {
  final UIState uiState;
  final ClockMode clockMode;
  /// where the camera image goes and the matching overlay transform, for the whole
  /// screen; the same framing as the Classic layout
  final FrameTransform Function(double w, double h) frameFor;
  final Widget Function(FrameTransform frame) videoBuilder;

  const MiciExtendedLayout({
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
      final unit = miciUnit(Size(w, h));
      final radius = BorderRadius.circular(miciCornerRadius * unit);
      final edge = (miciBorderWidth + miciMargin) * unit;  // screen edge to corner elements

      final frame = frameFor(w, h);

      // alerts and turn signals are the Classic ones
      final classicScale = h / 1080.0;
      // without confidence values from the device the ball stays at the bottom
      final confidence = st.confidenceSeen ? st.confidenceFiltered.clamp(0.0, 1.0).toDouble() : 0.0;
      final ball = miciBallColors(st.status, confidence: st.confidenceSeen ? confidence : 1.0);
      final ballSize = 2 * (miciBallRadius + miciBallPadding) * unit;
      final ballTop = edge + (1 - confidence) * (h - 2 * edge - ballSize);
      final active = st.status != UIStatus.disengaged;

      return ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // camera over the whole screen, with the path and lane lines
            videoBuilder(frame),
            CustomPaint(
              painter: ModelRendererPainter(
                state: st,
                carSpaceTransform: frame.carToScreen,
                contentRect: Rect.fromLTWH(0, 0, w, h),
              ),
            ),

            // fade out the bottom of the overlay, as the device does
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

            CustomPaint(
              painter: MiciTorqueBarPainter(value: st.torqueBarValue, status: st.status, unit: unit),
            ),
            Positioned.fill(child: TurnSignalRenderer(uiState: st, scale: classicScale)),

            // top row: set speed | speed | clock, with the speed centred
            Positioned(
              top: edge,
              left: 0,
              right: 0,
              height: miciSpeedPillHeight * unit,
              child: MiciTopRow(uiState: st, unit: unit, clockMode: clockMode),
            ),

            // road name under the speed
            if (st.showRoadName)
              Positioned(
                top: edge + (miciSpeedPillHeight + 6) * unit,
                left: 0,
                right: 0,
                child: Center(child: _roadName(st.roadName, unit, w)),
              ),

            // driver monitoring, top left: the cone points where the driver's head is
            // turned; dimmed, without a cone, when camera monitoring is not running.
            // hidden while an alert is showing, as on the device
            if (active && st.dmSeen && st.alertSize == 0)
              Positioned(
                left: edge,
                top: edge,
                width: miciDriverIconSize * unit,
                height: miciDriverIconSize * unit,
                child: Opacity(
                  opacity: st.dmActive ? 1.0 : 0.35,
                  child: CustomPaint(
                    painter: MiciDriverIconPainter(
                      coneColor: st.dmActive ? miciDriverConeColor(awarenessFull: !st.dmAwarenessUnfull) : null,
                      rotationDeg: st.dmRotationDeg,
                    ),
                    child: Center(
                      child: Icon(Icons.person, color: Colors.white, size: miciDriverIconSize * unit * 0.62),
                    ),
                  ),
                ),
              ),

            // steering readout, bottom left
            Positioned(
              left: edge,
              bottom: edge,
              child: MiciSteeringPills(uiState: st, unit: unit),
            ),

            // confidence ball on a dark disc, travelling up and down the right edge
            if (ball != null)
              Positioned(
                key: const ValueKey('miciBall'),
                right: edge,
                top: ballTop,
                width: ballSize,
                height: ballSize,
                child: DecoratedBox(
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: _discColor),
                  child: Padding(
                    padding: EdgeInsets.all(miciBallPadding * unit),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: ball,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            AlertRenderer(uiState: st, scale: classicScale),

            // border in the engagement colour, on top of everything
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: miciBorderColor(st.status), width: miciBorderWidth * unit),
              ),
            ),
          ],
        ),
      );
    });
  }
}

/// dark rounded box, as behind the speed; as wide as its content
Widget _pill(
  double unit, {
  required double height,
  required Widget child,
  double padding = 14,
  double radius = 12,
}) {
  return Container(
    height: height * unit,
    padding: EdgeInsets.symmetric(horizontal: padding * unit),
    decoration: BoxDecoration(
      color: _pillColor,
      borderRadius: BorderRadius.circular(radius * unit),
    ),
    child: Center(widthFactor: 1, child: child),
  );
}

Widget _roadName(String name, double unit, double screenW) {
  return ConstrainedBox(
    constraints: BoxConstraints(maxWidth: screenW * 0.5),
    child: Container(
      height: 24 * unit,
      padding: EdgeInsets.symmetric(horizontal: 10 * unit),
      decoration: BoxDecoration(
        color: _pillColor,
        borderRadius: BorderRadius.circular(8 * unit),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: HudColors.whiteTranslucent,
            fontSize: 13 * unit,
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
      ),
    ),
  );
}

// -- top row --

/// speed in a dark pill at top centre, with the set speed to its left and the clock
/// to its right; the speed stays centred whatever is shown beside it
class MiciTopRow extends StatelessWidget {
  final UIState uiState;
  final double unit;
  final ClockMode clockMode;

  const MiciTopRow({super.key, required this.uiState, required this.unit, required this.clockMode});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final gap = SizedBox(width: 8 * unit);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
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
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: clockMode != ClockMode.off ? _clock() : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  Widget _speed() {
    return _pill(
      unit,
      height: miciSpeedPillHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '${uiState.displaySpeed.round()}',
            style: TextStyle(color: HudColors.white, fontSize: 34 * unit, fontWeight: FontWeight.bold, height: 1.0),
          ),
          SizedBox(width: 5 * unit),
          Text(
            uiState.isMetric ? 'km/h' : 'mph',
            style: TextStyle(
                color: HudColors.whiteTranslucent, fontSize: 14 * unit, fontWeight: FontWeight.w500, height: 1.0),
          ),
        ],
      ),
    );
  }

  Widget _clock() {
    return _pill(
      unit,
      height: 40,
      child: ClockText(
        mode: clockMode,
        style: TextStyle(color: HudColors.white, fontSize: 22 * unit, fontWeight: FontWeight.w600, height: 1.0),
      ),
    );
  }

  /// same colours as the Classic MAX box
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
    return _pill(
      unit,
      height: 40,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            'MAX',
            style: TextStyle(color: maxColor, fontSize: 11 * unit, fontWeight: FontWeight.w600, height: 1.0),
          ),
          SizedBox(width: 5 * unit),
          Text(
            st.isCruiseSet ? '${st.setSpeed.round()}' : '–',
            style: TextStyle(color: speedColor, fontSize: 24 * unit, fontWeight: FontWeight.bold, height: 1.0),
          ),
        ],
      ),
    );
  }
}

// -- steering readout --

/// "12.3°", never "-0.0°"
String formatSteeringAngle(double deg) {
  final text = deg.toStringAsFixed(1);
  return '${text == '-0.0' ? '0.0' : text}\u00B0';
}

/// three small pills, bottom left: steering mode, the angle openpilot is asking
/// for, and the angle the wheel is at
class MiciSteeringPills extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const MiciSteeringPills({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final mode = st.steeringMode;
    final String modeText;
    final Color modeColor;
    switch (mode) {
      case LateralMode.angle:
        modeText = 'ANGLE';
        modeColor = angleColor;
      case LateralMode.torque:
        modeText = 'TORQUE';
        modeColor = torqueColor;
      case null:
        modeText = 'OFF';
        modeColor = HudColors.grey;
    }
    final gap = SizedBox(height: 4 * unit);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row('STEER', modeText, modeColor),
        gap,
        // only meaningful while openpilot is steering
        _row('TARGET', st.latActive ? formatSteeringAngle(st.targetSteeringAngleDeg) : '\u2013', HudColors.white),
        gap,
        _row('ACTUAL', formatSteeringAngle(st.steeringAngleDeg), HudColors.white),
      ],
    );
  }

  Widget _row(String label, String value, Color valueColor) {
    return _pill(
      unit,
      height: 20,
      padding: 8,
      radius: 7,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(color: HudColors.grey, fontSize: 8.5 * unit, fontWeight: FontWeight.w600, height: 1.0),
          ),
          SizedBox(width: 6 * unit),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 12 * unit,
              fontWeight: FontWeight.bold,
              height: 1.0,
              // digits of equal width, so the pill does not jitter as the angle changes
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// -- driver monitoring icon --

/// dark disc with a cone (drawn as an arc) on the side the driver's head is turned
/// towards; the person glyph is the painter's child. [rotationDeg] is the device's
/// head rotation, where 90 is straight ahead and puts the cone at the top
class MiciDriverIconPainter extends CustomPainter {
  final Color? coneColor;  // null: no cone
  final double rotationDeg;

  const MiciDriverIconPainter({required this.coneColor, required this.rotationDeg});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(c, r, Paint()..color = _discColor);
    final color = coneColor;
    if (color == null) return;
    final arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.16
      ..strokeCap = StrokeCap.round;
    // 100 degrees wide; the device turns its cone image by (rotation - 90) from the top
    final middle = (rotationDeg - 180) * pi / 180;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r * 0.84), middle - 50 * pi / 180, 100 * pi / 180, false, arc);
  }

  @override
  bool shouldRepaint(MiciDriverIconPainter old) => old.coneColor != coneColor || old.rotationDeg != rotationDeg;
}

// -- torque bar (mici/onroad/torque_bar.py) --

/// arc along the bottom of the screen: grey track, filled from the centre towards
/// the side the car is steering, turning orange near the limit
class MiciTorqueBarPainter extends CustomPainter {
  final double value;  // -1..1
  final UIStatus status;
  final double unit;

  const MiciTorqueBarPainter({required this.value, required this.status, required this.unit});

  @override
  void paint(Canvas canvas, Size size) {
    // hidden when nothing is steering
    if (status == UIStatus.disengaged || status == UIStatus.longOnly) return;
    final steering = status == UIStatus.engaged || status == UIStatus.latOnly;

    final mag = value.abs();
    final offset = (_interp(mag, 0.5, 1, 22, 26) + miciBorderWidth) * unit;
    final thickness = _interp(mag, 0.5, 1, 14, 56) * unit;
    final radius = _torqueRadius * unit;
    final midR = radius + thickness / 2;
    final center = Offset(size.width / 2, size.height + radius - offset);
    final arc = Rect.fromCircle(center: center, radius: midR);

    const top = -pi / 2;
    const halfSpan = _torqueAngleSpanDeg / 2 * pi / 180;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;

    // track
    final trackAlpha = steering ? _interp(mag, 0.5, 1, 0.25, 0.5) : 0.15;
    paint.color = Color.fromRGBO(255, 255, 255, trackAlpha);
    canvas.drawArc(arc, top - halfSpan, 2 * halfSpan, false, paint);

    // fill
    if (mag > 0.001) {
      final hot = max(0.0, mag - 0.75) * 4;
      paint.color = steering
          ? Color.lerp(const Color(0xE6FFFFFF), const Color(0xFFFF7300), hot)!
          : const Color(0x59FFFFFF);
      canvas.drawArc(arc, top, halfSpan * value, false, paint);
    }

    // centre dot while the bar is thin
    if (mag < 0.5) {
      canvas.drawCircle(
        Offset(center.dx, size.height - offset - thickness / 2),
        5 * unit,
        Paint()..color = const Color(0xE6B6B6B6),
      );
    }
  }

  @override
  bool shouldRepaint(MiciTorqueBarPainter old) =>
      old.value != value || old.status != status || old.unit != unit;
}

/// linear interpolation of [x] from [x0]..[x1] to [y0]..[y1], held at the ends
double _interp(double x, double x0, double x1, double y0, double y1) {
  if (x <= x0) return y0;
  if (x >= x1) return y1;
  return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
}
