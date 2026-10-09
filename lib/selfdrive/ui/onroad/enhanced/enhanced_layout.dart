// Enhanced layout
//
// the camera fills the screen inside a rounded border in the engagement colour, and
// everything else is drawn over it in dark pills:
//   - top row, centred on the speed: set speed | speed | clock
//   - road name under the speed
//   - driver monitoring icon, top left
//   - steering readout, bottom left: angle or torque mode, target and actual angle
//   - lead car readout, bottom right: time gap, speed difference, the lead's speed
//   - torque bar, bottom centre
//   - a box around the lead car with its distance (drawn by the model renderer)
//   - a glow from the screen edge on a side whose blind spot is occupied
//   - alerts as a compact card above the torque bar; critical ones take the screen
//
// it began as a port of the comma four's own driving screen (openpilot
// selfdrive/ui/mici/onroad): the driver monitoring icon and the torque bar still
// follow that code, and sizes are in comma four pixels (its screen is 240 tall),
// scaled by `unit`. The camera framing and the path are the Classic ones.

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:opview/common/transformations.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/clock_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/exp_button.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/throttled.dart';
import 'package:opview/services/app_settings.dart';

// -- sizes, in comma four pixels --

const enhancedRefWidth = 536.0;
const enhancedRefHeight = 240.0;
const enhancedCornerRadius = 12.0;
const enhancedBorderWidth = 4.0;
const enhancedMargin = 16.0;          // gap between the border and the corner elements
const enhancedDriverIconSize = 54.0;
const enhancedSpeedPillHeight = 52.0;
const enhancedSidePillWidth = 116.0;  // set speed and clock, either side of the speed
const enhancedSidePillHeight = 40.0;
const enhancedInfoPillWidth = 100.0;  // steering and lead readouts
const enhancedInfoPillHeight = 20.0;
const enhancedInfoPillGap = 4.0;
const enhancedGlowWidth = 70.0;

// path: a bit more solid than stock, drawn further out, and fading later
const enhancedPathOpacity = 1.35;
const enhancedPathDistance = 150.0;  // metres; stock 100
const enhancedPathFadeStop = 0.65;   // stock 0.5

// torque bar (mici torque_bar.py uses a span of 12.7; shortened to clear the readouts)
const _torqueAngleSpanDeg = 8.0;
const _torqueRadius = 1200.0;

// alert sizes and severities, as in cereal
const _alertSizeNone = 0;
const _alertSizeSmall = 1;
const _alertSizeFull = 3;
const _alertStatusUserPrompt = 1;
const _alertStatusCritical = 2;

// -- colours --

const _pillColor = Color(0xB3141414);
const _discColor = Color(0xE6101010);
const _labelColor = HudColors.grey;
const _blindSpotGlow = Color(0x8CFF9628);

/// border around the screen, by engagement state
Color enhancedBorderColor(UIStatus status) {
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

/// cone on the driver monitoring icon: green while attention is full, orange once
/// it starts to run down (mici driver_state.py CONE_COLOR_*)
Color enhancedDriverConeColor({required bool awarenessFull}) {
  return awarenessFull ? const Color(0xFF00FF40) : const Color(0xFFFF7300);
}

/// alert background: dark for a notice, orange when a response is needed, red when critical
Color enhancedAlertColor(int alertStatus, {required bool fullScreen}) {
  if (alertStatus == _alertStatusCritical) return const Color(0xF1C92231);
  if (alertStatus == _alertStatusUserPrompt) return const Color(0xF1DA6F25);
  return fullScreen ? const Color(0xF1151515) : const Color(0xE0141414);
}

/// critical alerts and full-size alerts cover the whole screen; the rest are a card
bool enhancedAlertIsFullScreen(int alertSize, int alertStatus) =>
    alertSize == _alertSizeFull || alertStatus == _alertStatusCritical;

// -- geometry --

/// comma four pixel size on a screen: its 536x240 display scaled to fit inside
double enhancedUnit(Size screen) => min(screen.height / enhancedRefHeight, screen.width / enhancedRefWidth);

// -- layout --

class EnhancedLayout extends StatelessWidget {
  final UIState uiState;
  final ClockMode clockMode;

  /// where the camera image goes and the matching overlay transform, for the whole
  /// screen; the same framing as the Classic layout
  final FrameTransform Function(double w, double h) frameFor;
  final Widget Function(FrameTransform frame) videoBuilder;

  const EnhancedLayout({
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
      final edge = (enhancedBorderWidth + enhancedMargin) * unit;  // screen edge to corner elements
      final frame = frameFor(w, h);

      // bottom of the road name pill: the lead's distance tag stays below it
      final hudBottom = edge + (enhancedSpeedPillHeight + 6 + 24) * unit;

      return ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // camera over the whole screen, with the path, lane lines and lead box
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
                pathOpacity: enhancedPathOpacity,
                maxPathDistance: enhancedPathDistance,
                pathFadeStop: enhancedPathFadeStop,
              ),
            ),

            // fade out the bottom of the overlay, as the comma four does
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

            // blind spot: glow from the edge on the occupied side, under everything else
            if (st.showBlindSpot && st.leftBlindspot)
              Positioned(
                key: const ValueKey('blindSpotLeft'),
                left: 0,
                top: 0,
                bottom: 0,
                width: enhancedGlowWidth * unit,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [_blindSpotGlow, Color(0x00FF9628)],
                    ),
                  ),
                ),
              ),
            if (st.showBlindSpot && st.rightBlindspot)
              Positioned(
                key: const ValueKey('blindSpotRight'),
                right: 0,
                top: 0,
                bottom: 0,
                width: enhancedGlowWidth * unit,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerRight,
                      end: Alignment.centerLeft,
                      colors: [_blindSpotGlow, Color(0x00FF9628)],
                    ),
                  ),
                ),
              ),

            CustomPaint(
              painter: EnhancedTorqueBarPainter(value: st.torqueBarValue, status: st.status, unit: unit),
            ),

            // top row: set speed | speed | clock, with the speed centred
            Positioned(
              top: edge,
              left: 0,
              right: 0,
              height: enhancedSpeedPillHeight * unit,
              child: EnhancedTopRow(uiState: st, unit: unit, clockMode: clockMode),
            ),

            // road name under the speed
            if (st.showRoadName)
              Positioned(
                top: edge + (enhancedSpeedPillHeight + 6) * unit,
                left: 0,
                right: 0,
                child: Center(child: _roadName(st.roadName, unit, w)),
              ),

            // driver monitoring, top left: the cone points where the driver's head is
            // turned; dimmed, without a cone, when camera monitoring is not running
            // shown whenever the car is on and the comma reports on the driver, engaged or not
            if (st.started && st.dmSeen)
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

            // steering readout, bottom left
            Positioned(
              left: edge,
              bottom: edge,
              child: ThrottledByVersion(state: st, builder: (_) => EnhancedSteeringPills(uiState: st, unit: unit)),
            ),

            // lead car readout, bottom right
            Positioned(
              right: edge,
              bottom: edge,
              child: ThrottledByVersion(state: st, builder: (_) => EnhancedLeadPills(uiState: st, unit: unit)),
            ),

            EnhancedAlert(uiState: st, unit: unit),

            // border in the engagement colour, on top of everything
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
}

// -- pills --

/// dark rounded box as wide as its content
Widget _pill(double unit, {required double height, required Widget child, double minWidth = 0}) {
  return Container(
    height: height * unit,
    constraints: BoxConstraints(minWidth: minWidth * unit),
    padding: EdgeInsets.symmetric(horizontal: 12 * unit),
    decoration: BoxDecoration(
      color: _pillColor,
      borderRadius: BorderRadius.circular(12 * unit),
    ),
    child: Center(widthFactor: 1, child: child),
  );
}

/// dark rounded box of a fixed size; the content is centred and shrinks to fit
Widget _fixedPill(double unit, {required double width, required double height, required Widget child, Key? key}) {
  return Container(
    key: key,
    width: width * unit,
    height: height * unit,
    padding: EdgeInsets.symmetric(horizontal: 10 * unit),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: _pillColor,
      borderRadius: BorderRadius.circular(12 * unit),
    ),
    child: FittedBox(fit: BoxFit.scaleDown, child: child),
  );
}

/// one line of a readout: small grey label on the left, value on the right. All of
/// them are the same width, so the values line up; a long value shrinks to fit
Widget _infoPill(double unit, String label, String value, Color valueColor) {
  return Container(
    width: enhancedInfoPillWidth * unit,
    height: enhancedInfoPillHeight * unit,
    padding: EdgeInsets.symmetric(horizontal: 8 * unit),
    decoration: BoxDecoration(
      color: _pillColor,
      borderRadius: BorderRadius.circular(7 * unit),
    ),
    child: Row(
      children: [
        Text(
          label,
          style: TextStyle(color: _labelColor, fontSize: 8.5 * unit, fontWeight: FontWeight.w600, height: 1.0),
        ),
        SizedBox(width: 4 * unit),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              value,
              style: TextStyle(
                color: valueColor,
                fontSize: 12 * unit,
                fontWeight: FontWeight.bold,
                height: 1.0,
                // digits of equal width, so values do not jitter as they change
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ],
    ),
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

/// speed in a pill at top centre, with matching set speed and clock pills either
/// side; the speed stays centred whatever is shown beside it
class EnhancedTopRow extends StatelessWidget {
  final UIState uiState;
  final double unit;
  final ClockMode clockMode;

  const EnhancedTopRow({super.key, required this.uiState, required this.unit, required this.clockMode});

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

  /// the number with its unit underneath
  Widget _speed() {
    return _pill(
      unit,
      height: enhancedSpeedPillHeight,
      minWidth: 74,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${uiState.displaySpeed.round()}',
            style: TextStyle(color: HudColors.white, fontSize: 33 * unit, fontWeight: FontWeight.bold, height: 0.95),
          ),
          Text(
            uiState.isMetric ? 'km/h' : 'mph',
            style: TextStyle(color: _labelColor, fontSize: 11 * unit, fontWeight: FontWeight.w600, height: 1.0),
          ),
        ],
      ),
    );
  }

  /// small "MAX" then the number; label colours as on the Classic MAX box
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
    return _fixedPill(
      unit,
      key: const ValueKey('enhancedSetSpeed'),
      width: enhancedSidePillWidth,
      height: enhancedSidePillHeight,
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

  /// the mirror of the set speed pill: the time, then a small AM/PM
  Widget _clock() {
    return _fixedPill(
      unit,
      key: const ValueKey('enhancedClock'),
      width: enhancedSidePillWidth,
      height: enhancedSidePillHeight,
      child: ClockText(
        mode: clockMode,
        style: TextStyle(color: HudColors.white, fontSize: 24 * unit, fontWeight: FontWeight.bold, height: 1.0),
        suffixStyle: TextStyle(color: _labelColor, fontSize: 11 * unit, fontWeight: FontWeight.w600, height: 1.0),
        suffixGap: 5 * unit,
      ),
    );
  }
}

// -- steering readout --

/// "12.3°", never "-0.0°"
String formatSteeringAngle(double deg) {
  final text = deg.toStringAsFixed(1);
  return '${text == '-0.0' ? '0.0' : text}°';
}

/// bottom left: steering mode, the angle openpilot is asking for, and the angle
/// the wheel is at
class EnhancedSteeringPills extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const EnhancedSteeringPills({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final String modeText;
    final Color modeColor;
    switch (st.steeringMode) {
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
    final gap = SizedBox(height: enhancedInfoPillGap * unit);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _infoPill(unit, 'STEER', modeText, modeColor),
        gap,
        // only meaningful while openpilot is steering
        _infoPill(unit, 'TARGET', st.latActive ? formatSteeringAngle(st.targetSteeringAngleDeg) : '–',
            HudColors.white),
        gap,
        _infoPill(unit, 'ACTUAL', formatSteeringAngle(st.steeringAngleDeg), HudColors.white),
      ],
    );
  }
}

// -- lead car readout --

/// lead car box and numbers show whenever openpilot is doing something (steering
/// only, cruise only, fully engaged, or overridden), not while disengaged
bool enhancedShowsLead(UIStatus status) => status != UIStatus.disengaged;

/// shown in each lead pill while there is no lead to report
const enhancedNoLeadValue = '– –';
const _noLeadColor = Color(0xFF8A8A8A);

/// following time in seconds, or a dash when standing still
String formatLeadGap(double dRel, double vEgo) => vEgo > 0.5 ? '${(dRel / vEgo).toStringAsFixed(1)} s' : '–';

/// speed difference to the lead with its sign: "-3 mph" is closing, "+2 mph" is pulling away
String formatLeadRelSpeed(double vRel, double conv, String speedUnit) {
  final v = (vRel * conv).round();
  return '${v > 0 ? '+' : ''}$v $speedUnit';
}

/// bottom right, always there: time gap, speed difference, and the lead's own
/// speed, or grey dashes with no lead car or while disengaged. The distance is on
/// the tag above the lead's box
class EnhancedLeadPills extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const EnhancedLeadPills({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final lead = enhancedShowsLead(st.status) ? st.activeLead : null;
    final gap = SizedBox(height: enhancedInfoPillGap * unit);
    if (lead == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _infoPill(unit, 'GAP', enhancedNoLeadValue, _noLeadColor),
          gap,
          _infoPill(unit, 'REL', enhancedNoLeadValue, _noLeadColor),
          gap,
          _infoPill(unit, 'LEAD', enhancedNoLeadValue, _noLeadColor),
        ],
      );
    }

    final dRel = (lead['dRel'] as num?)?.toDouble() ?? 0.0;
    final vRel = (lead['vRel'] as num?)?.toDouble() ?? 0.0;
    final speedUnit = st.isMetric ? 'km/h' : 'mph';
    final leadSpeed = max(0.0, (st.vEgo + vRel) * st.speedConv).round();
    final warn = leadWarnColor(leadWarnLevel(dRel, vRel));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _infoPill(unit, 'GAP', formatLeadGap(dRel, st.vEgo), warn),
        gap,
        _infoPill(unit, 'REL', formatLeadRelSpeed(vRel, st.speedConv, speedUnit), HudColors.white),
        gap,
        _infoPill(unit, 'LEAD', '$leadSpeed $speedUnit', HudColors.white),
      ],
    );
  }
}

// -- alerts --

/// notices and prompts are a compact card above the torque bar, between the two
/// readouts, so the rest of the display stays visible. Critical alerts, and any
/// alert openpilot sends at full size, cover the whole screen
class EnhancedAlert extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const EnhancedAlert({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    if (st.alertSize == _alertSizeNone) return const SizedBox.shrink();

    if (enhancedAlertIsFullScreen(st.alertSize, st.alertStatus)) {
      return Positioned.fill(
        child: Container(
          key: const ValueKey('enhancedAlertFull'),
          color: enhancedAlertColor(st.alertStatus, fullScreen: true),
          padding: EdgeInsets.all(20 * unit),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(flex: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  st.alertText1,
                  style: TextStyle(color: Colors.white, fontSize: 44 * unit, fontWeight: FontWeight.bold, height: 1.1),
                ),
              ),
              const Spacer(),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  st.alertText2,
                  style: TextStyle(color: Colors.white, fontSize: 24 * unit, height: 1.1),
                ),
              ),
              const Spacer(flex: 2),
            ],
          ),
        ),
      );
    }

    final showSecondLine = st.alertSize != _alertSizeSmall && st.alertText2.isNotEmpty;
    return Positioned(
      left: 0,
      right: 0,
      bottom: (enhancedBorderWidth + enhancedMargin + 46) * unit,
      child: Center(
        child: Container(
          key: const ValueKey('enhancedAlertCard'),
          constraints: BoxConstraints(minWidth: 150 * unit, maxWidth: 262 * unit),
          padding: EdgeInsets.symmetric(horizontal: 18 * unit, vertical: 11 * unit),
          decoration: BoxDecoration(
            color: enhancedAlertColor(st.alertStatus, fullScreen: false),
            borderRadius: BorderRadius.circular(12 * unit),
            boxShadow: [BoxShadow(color: const Color(0x59000000), blurRadius: 10 * unit, offset: Offset(0, 2 * unit))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                st.alertText1,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 20 * unit, fontWeight: FontWeight.bold, height: 1.1),
              ),
              if (showSecondLine) ...[
                SizedBox(height: 6 * unit),
                Text(
                  st.alertText2,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: const Color(0xF2FFFFFF), fontSize: 13 * unit, height: 1.1),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// -- driver monitoring icon --

/// dark disc with a cone (drawn as an arc) on the side the driver's head is turned
/// towards; the person glyph is the painter's child. [rotationDeg] is the comma
/// four's head rotation, where 90 is straight ahead and puts the cone at the top
class EnhancedDriverIconPainter extends CustomPainter {
  final Color? coneColor;  // null: no cone
  final double rotationDeg;

  const EnhancedDriverIconPainter({required this.coneColor, required this.rotationDeg});

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
  bool shouldRepaint(EnhancedDriverIconPainter old) => old.coneColor != coneColor || old.rotationDeg != rotationDeg;
}

// -- torque bar (mici/onroad/torque_bar.py) --

/// arc along the bottom of the screen: grey track, filled from the centre towards
/// the side the car is steering, turning orange near the limit
class EnhancedTorqueBarPainter extends CustomPainter {
  final double value;  // -1..1
  final UIStatus status;
  final double unit;

  const EnhancedTorqueBarPainter({required this.value, required this.status, required this.unit});

  @override
  void paint(Canvas canvas, Size size) {
    // hidden when nothing is steering
    if (status == UIStatus.disengaged || status == UIStatus.longOnly) return;
    final steering = status == UIStatus.engaged || status == UIStatus.latOnly;

    final mag = value.abs();
    final offset = (_interp(mag, 0.5, 1, 22, 26) + enhancedBorderWidth) * unit;
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
  bool shouldRepaint(EnhancedTorqueBarPainter old) =>
      old.value != value || old.status != status || old.unit != unit;
}

/// linear interpolation of [x] from [x0]..[x1] to [y0]..[y1], held at the ends
double _interp(double x, double x0, double x1, double y0, double y1) {
  if (x <= x0) return y0;
  if (x >= x1) return y1;
  return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
}
