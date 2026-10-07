// comma four style layout, extended for a larger screen
//
// the main area follows the comma four's own driving screen (openpilot
// selfdrive/ui/mici/onroad): a rounded camera view in the device's 536x240 shape,
// a status ball in a strip on its right, the steering wheel icon bottom left and
// the torque bar along the bottom. The comma four shows no permanent speed, so the
// screen space left over holds an information panel: speed, set speed, speed limit,
// road name and clock.
//
// all device measurements are in comma four pixels (240 tall), scaled by `unit`.
//
// not ported yet: the device's own path and lane line style (the Classic overlay is
// drawn instead), the driver monitoring face, the brief set speed pop-up, and the
// confidence ball's rise and fall (opview is not sent the model's confidence values,
// so the ball shows engagement state only, at a fixed height).

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:opview/common/transformations.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/alert_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/clock_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/exp_button.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/speed_limit_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/turn_signal_renderer.dart';
import 'package:opview/services/app_settings.dart';

// -- comma four screen (mici/onroad) --

const miciScreenWidth = 536.0;
const miciScreenHeight = 240.0;
const miciSidePanelWidth = 60.0;   // SIDE_PANEL_WIDTH
const miciCornerRadius = 24.0;     // rounded border, roundness 0.2 of a 240 px side
const miciBallRadius = 24.0;       // status_dot_radius
const miciWheelSize = 50.0;

/// zoom of the comma four's own screen, in screen px per camera px on its 240 px
/// tall display with its OS04C10 cameras (augmented_road_view.py _calc_frame_matrix)
const miciWideZoom = 0.7 * 1.5;
double miciRoadZoom(double vEgo) => _interp(vEgo, 10, 30, 0.8, 1.0);

/// focal lengths the zooms above were chosen for
const miciRoadFocalLength = 1141.5;
const miciWideFocalLength = 425.25;

// torque_bar.py
const _torqueAngleSpanDeg = 12.7;
const _torqueRadius = 1200.0;

// -- colours --

/// border around the camera view, by engagement state
Color miciBorderColor(UIStatus status) {
  switch (status) {
    case UIStatus.disengaged:
      return const Color(0xFF6E6E6E);  // grey
    case UIStatus.override_:
      return const Color(0xFFB4B4B4);
    case UIStatus.engaged:
      return const Color(0xFF17C653);  // green
    case UIStatus.latOnly:
      return const Color(0xFF2E7BFF);  // blue: steering only
    case UIStatus.longOnly:
      return const Color(0xFF961CA8);  // purple: cruise only
  }
}

/// top and bottom colour of the status ball (confidence_ball.py), or null when hidden
List<Color>? miciBallColors(UIStatus status) {
  switch (status) {
    case UIStatus.disengaged:
      return null;
    case UIStatus.engaged:
      return const [Color(0xFF00FFCC), Color(0xFF00FF26)];
    case UIStatus.override_:
      return const [Color(0xFFFFFFFF), Color(0xFF525252)];
    case UIStatus.latOnly:
      return const [Color(0xFF00C8C8), Color(0xFF00C8C8)];
    case UIStatus.longOnly:
      return const [Color(0xFF961CA8), Color(0xFF961CA8)];
  }
}

// -- geometry --

/// where the comma four screen and the information panel go on a screen of a given size
class MiciGeometry {
  final Rect device;        // comma four screen: camera view plus status strip
  final Rect info;          // information panel
  final bool infoVertical;  // panel is a column at the side (true) or a row below (false)

  const MiciGeometry(this.device, this.info, this.infoVertical);

  /// comma four pixel size on this screen
  double get unit => device.height / miciScreenHeight;

  static MiciGeometry compute(Size screen) {
    const aspect = miciScreenWidth / miciScreenHeight;
    final w = screen.width, h = screen.height;

    // full width with the panel below, if that leaves the panel a usable height
    final below = h - w / aspect;
    if (below >= 0.16 * h) {
      return MiciGeometry(
        Rect.fromLTWH(0, 0, w, w / aspect),
        Rect.fromLTWH(0, w / aspect, w, below),
        false,
      );
    }

    // otherwise the panel goes at the side, at least a fifth of the width
    final panelW = max(w - h * aspect, 0.2 * w);
    final deviceW = w - panelW;
    final deviceH = deviceW / aspect;
    return MiciGeometry(
      Rect.fromLTWH(0, (h - deviceH) / 2, deviceW, deviceH),
      Rect.fromLTWH(deviceW, 0, panelW, h),
      true,
    );
  }
}

/// video placement and overlay transform for a camera view of [w] x [h];
/// zooms are the comma four's own, [scale] is this view's height over 240
typedef MiciFrameBuilder = FrameTransform Function(
  double w,
  double h, {
  required double roadZoom,
  required double wideZoom,
  required double scale,
});

// -- layout --

class MiciExtendedLayout extends StatelessWidget {
  final UIState uiState;
  final ClockMode clockMode;
  final MiciFrameBuilder frameFor;
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
      final geo = MiciGeometry.compute(Size(constraints.maxWidth, constraints.maxHeight));
      return Stack(
        children: [
          Positioned.fromRect(rect: geo.device, child: _deviceScreen(geo)),
          Positioned.fromRect(
            rect: geo.info,
            child: MiciInfoPanel(uiState: uiState, clockMode: clockMode, vertical: geo.infoVertical),
          ),
        ],
      );
    });
  }

  /// the comma four screen: camera view on the left, status ball strip on the right
  Widget _deviceScreen(MiciGeometry geo) {
    final st = uiState;
    final unit = geo.unit;
    final viewW = geo.device.width - miciSidePanelWidth * unit;
    final viewH = geo.device.height;
    final radius = BorderRadius.circular(miciCornerRadius * unit);

    final frame = frameFor(
      viewW,
      viewH,
      roadZoom: miciRoadZoom(st.vEgo),
      wideZoom: miciWideZoom,
      scale: unit,
    );

    // alerts and turn signals are the Classic ones, sized for this view
    final classicScale = viewH / 1080.0;
    final ball = miciBallColors(st.status);
    final tint = wheelTint(st.lateralMode) ?? Colors.white;

    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          width: viewW,
          height: viewH,
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                videoBuilder(frame),
                CustomPaint(
                  painter: ModelRendererPainter(
                    state: st,
                    carSpaceTransform: frame.carToScreen,
                    contentRect: Rect.fromLTWH(0, 0, viewW, viewH),
                  ),
                ),
                // fade out the bottom of the overlay, as the device does
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: viewH * 0.35,
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
                if (st.status != UIStatus.disengaged)
                  Positioned(
                    left: 21 * unit,
                    bottom: 14 * unit,
                    width: miciWheelSize * unit,
                    height: miciWheelSize * unit,
                    child: Transform.rotate(
                      angle: -st.steeringAngleDeg * pi / 180,
                      child: Image.asset(
                        'assets/icons/chffr_wheel.png',
                        color: tint.withAlpha(230),
                        colorBlendMode: BlendMode.modulate,
                      ),
                    ),
                  ),
                AlertRenderer(uiState: st, scale: classicScale),
              ],
            ),
          ),
        ),

        // border in the engagement colour
        Positioned(
          left: 0,
          top: 0,
          width: viewW,
          height: viewH,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: miciBorderColor(st.status), width: 4 * unit),
            ),
          ),
        ),

        // status ball
        if (ball != null)
          Positioned(
            left: geo.device.width - 2 * miciBallRadius * unit,
            top: viewH / 2 - miciBallRadius * unit,
            width: 2 * miciBallRadius * unit,
            height: 2 * miciBallRadius * unit,
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
      ],
    );
  }
}

// -- torque bar (mici/onroad/torque_bar.py) --

/// arc along the bottom of the camera view: grey track, filled from the centre
/// towards the side the car is steering, turning orange near the limit
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
    final offset = _interp(mag, 0.5, 1, 22, 26) * unit;
    final thickness = _interp(mag, 0.5, 1, 14, 56) * unit;
    final radius = _torqueRadius * unit;
    final midR = radius + thickness / 2;
    final center = Offset(size.width / 2 + 8 * unit, size.height + radius - offset);
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

// -- information panel --

/// what the comma four screen leaves out: speed, set speed, speed limit, road name, clock.
/// every item scales to the space it is given, so the panel fits any screen shape
class MiciInfoPanel extends StatelessWidget {
  final UIState uiState;
  final ClockMode clockMode;
  final bool vertical;

  const MiciInfoPanel({super.key, required this.uiState, required this.clockMode, required this.vertical});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final showClock = clockMode != ClockMode.off;
    final cells = <Widget>[
      if (vertical && showClock) _cell(2, _clock()),
      _cell(3, _speed()),
      if (st.isCruiseAvailable) _cell(2, _setSpeed()),
      if (st.showSpeedLimit) _cell(2, _speedLimit()),
      if (st.showRoadName) _cell(vertical ? 1 : 4, _roadName()),
      if (!vertical && showClock) _cell(3, _clock()),
    ];
    return ColoredBox(
      color: Colors.black,
      child: vertical
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells)
          : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells),
    );
  }

  /// one item, scaled to fill its share of the panel
  Widget _cell(int flex, Widget child) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: FittedBox(fit: BoxFit.contain, child: child),
      ),
    );
  }

  Widget _speed() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '${uiState.displaySpeed.round()}',
          style: const TextStyle(color: HudColors.white, fontSize: 96, fontWeight: FontWeight.bold, height: 1.0),
        ),
        const SizedBox(width: 10),
        Text(
          uiState.isMetric ? 'km/h' : 'mph',
          style: const TextStyle(
              color: HudColors.whiteTranslucent, fontSize: 30, fontWeight: FontWeight.w500, height: 1.0),
        ),
      ],
    );
  }

  /// same colours as the Classic MAX box
  Widget _setSpeed() {
    final st = uiState;
    Color maxColor = HudColors.grey;
    Color speedColor = HudColors.darkGrey;
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('MAX', style: TextStyle(color: maxColor, fontSize: 24, fontWeight: FontWeight.w600, height: 1.2)),
        Text(
          st.isCruiseSet ? '${st.setSpeed.round()}' : '–',
          style: TextStyle(color: speedColor, fontSize: 64, fontWeight: FontWeight.bold, height: 1.0),
        ),
      ],
    );
  }

  /// round European sign for metric, rectangular US sign for imperial
  Widget _speedLimit() {
    final sign = SpeedLimitSign.from(uiState);
    final value = Text(
      sign.value,
      style: TextStyle(color: sign.textColor, fontSize: 46, fontWeight: FontWeight.bold, height: 1.0),
    );
    if (uiState.isMetric) {
      return Container(
        width: 110,
        height: 110,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: SpeedLimitColors.white,
          border: Border.all(color: SpeedLimitColors.red, width: 12),
        ),
        child: FittedBox(fit: BoxFit.scaleDown, child: value),
      );
    }
    const label = TextStyle(color: SpeedLimitColors.black, fontSize: 13, fontWeight: FontWeight.bold, height: 1.1);
    return Container(
      width: 90,
      height: 110,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: SpeedLimitColors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SpeedLimitColors.black, width: 3),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('SPEED', style: label),
            const Text('LIMIT', style: label),
            value,
          ],
        ),
      ),
    );
  }

  Widget _roadName() {
    return Text(
      uiState.roadName,
      maxLines: 1,
      style: const TextStyle(color: HudColors.whiteTranslucent, fontSize: 40, fontWeight: FontWeight.w500, height: 1.0),
    );
  }

  Widget _clock() {
    return ClockText(
      mode: clockMode,
      style: const TextStyle(color: HudColors.whiteTranslucent, fontSize: 64, fontWeight: FontWeight.w600, height: 1.0),
    );
  }
}

/// linear interpolation of [x] from [x0]..[x1] to [y0]..[y1], held at the ends
double _interp(double x, double x0, double x1, double y0, double y1) {
  if (x <= x0) return y0;
  if (x >= x1) return y1;
  return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
}
