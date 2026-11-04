// status bar along the bottom, under the camera: the clock and the comma's own figures
// (the block that sat in the Detailed layout's top right corner)
//
// sizes are in the redesign mockup's pixels (a 1920x1000 screen), scaled by `unit`

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/onroad/clock_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/detailed/detailed_layout.dart' show formatGear, networkBars;
import 'package:opview/selfdrive/ui/onroad/throttled.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';

/// height of the bar in mockup pixels
const statusBarHeight = 84.0;

const _barColor = Color(0xFF0E0F10);
const _labelColor = Color(0xFF8C8C8C);
const _good = Color(0xFF3ADB6D);
const _warn = Color(0xFFFF9A3C);
const _noValue = '–';

/// the figures in the bar, left to right, as (label, value, colour)
List<(String, String, Color)> statusBarFigures(UIState st) {
  final seen = st.deviceSeen;
  final calibrated = st.calStatus == 'calibrated';
  return [
    ('CPU', seen ? '${st.cpuTempC.round()}°C' : _noValue, Colors.white),
    ('MEM', seen ? '${st.memoryUsagePercent}%' : _noValue, Colors.white),
    ('DISK', seen ? '${(100 - st.freeSpacePercent).round()}%' : _noValue, Colors.white),
    ('POWER', seen ? '${st.powerDrawW.toStringAsFixed(1)} W' : _noValue, Colors.white),
    ('CALIB', calibrated ? '100%' : (st.calPerc > 0 ? '${st.calPerc}%' : _noValue), calibrated ? _good : _warn),
    ('GEAR', formatGear(st.gearShifter), Colors.white),
  ];
}

class StatusBar extends StatelessWidget {
  final UIState uiState;
  final ClockMode clockMode;
  final double unit;

  const StatusBar({super.key, required this.uiState, required this.clockMode, required this.unit});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('statusBar'),
      height: statusBarHeight * unit,
      color: _barColor,
      padding: EdgeInsets.symmetric(horizontal: 24 * unit),
      // the figures change a few times a second at most; no need to rebuild on every frame
      child: ThrottledByVersion(
        state: uiState,
        builder: (_) {
          final figures = statusBarFigures(uiState);
          final cells = <Widget>[
            ClockText(
              key: const ValueKey('statusBarClock'),
              mode: clockMode,
              style: TextStyle(color: Colors.white, fontSize: 32 * unit, fontWeight: FontWeight.bold, height: 1.0),
              suffixStyle: TextStyle(color: const Color(0xFFA6A6A6), fontSize: 18 * unit, fontWeight: FontWeight.w600, height: 1.0),
              suffixGap: 6 * unit,
            ),
            for (final (label, value, color) in figures.take(3)) _figure(label, value, color),
            _wifi(networkBars(uiState.networkStrength)),
            for (final (label, value, color) in figures.skip(3)) _figure(label, value, color),
          ];
          return Row(
            children: [
              for (var i = 0; i < cells.length; i++) ...[
                if (i > 0) _divider(),
                Expanded(child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: cells[i]))),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _divider() => Container(width: 1, height: 34 * unit, color: const Color(0x1FFFFFFF));

  Widget _figure(String label, String value, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(label,
            style: TextStyle(color: _labelColor, fontSize: 19 * unit, fontWeight: FontWeight.w600, letterSpacing: 0.4 * unit, height: 1.0)),
        SizedBox(width: 10 * unit),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 27 * unit,
            fontWeight: FontWeight.bold,
            height: 1.0,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _wifi(int bars) {
    return Row(
      key: const ValueKey('statusBarWifi'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('WI-FI',
            style: TextStyle(color: _labelColor, fontSize: 19 * unit, fontWeight: FontWeight.w600, letterSpacing: 0.4 * unit, height: 1.0)),
        SizedBox(width: 10 * unit),
        for (var i = 0; i < 4; i++) ...[
          if (i > 0) SizedBox(width: 3 * unit),
          Container(
            width: 8 * unit,
            height: (8 + i * 6) * unit,
            decoration: BoxDecoration(
              color: i < bars ? _good : const Color(0x40FFFFFF),
              borderRadius: BorderRadius.circular(2 * unit),
            ),
          ),
        ],
      ],
    );
  }
}
