// while navigating, on the driving view: the next turn (navd's navInstruction) and a small map.
// Sizes are in the Enhanced layout's comma four units (536x240), scaled by `unit`

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/navigate/nav_map.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/nav/maptiler.dart';
import 'package:opview/services/nav/places.dart';

const turnBannerWidth = 128.0;
const miniMapWidth = 128.0;
const miniMapHeight = 82.0;
const _bannerBlue = Color(0xFF1F5FC4);

/// navd's maneuver (Mapbox type and modifier) as an arrow
IconData maneuverIcon(String type, String modifier) {
  if (type == 'arrive') return Icons.flag;
  if (type.contains('roundabout') || type == 'rotary') return Icons.roundabout_right;
  if (type == 'merge') return Icons.merge;
  if (type == 'fork') return modifier.contains('left') ? Icons.fork_left : Icons.fork_right;
  if (type == 'off ramp' || type == 'on ramp') return modifier.contains('left') ? Icons.ramp_left : Icons.ramp_right;
  return switch (modifier) {
    'left' => Icons.turn_left,
    'right' => Icons.turn_right,
    'slight left' => Icons.turn_slight_left,
    'slight right' => Icons.turn_slight_right,
    'sharp left' => Icons.turn_sharp_left,
    'sharp right' => Icons.turn_sharp_right,
    'uturn' => Icons.u_turn_left,
    _ => Icons.straight,
  };
}

class TurnBanner extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const TurnBanner({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final u = unit;
    final arrival = DateTime.now().add(Duration(seconds: st.navTimeRemaining.round()));
    final street = st.navPrimary.isEmpty ? st.navSecondary : st.navPrimary;
    TextStyle s(double size, FontWeight w, [Color c = Colors.white]) => TextStyle(color: c, fontSize: size * u, fontWeight: w, height: 1.1);
    return Container(
      key: const ValueKey('turnBanner'),
      width: turnBannerWidth * u,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(9 * u), color: const Color(0xE616171A)),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: _bannerBlue,
          padding: EdgeInsets.fromLTRB(8 * u, 7 * u, 8 * u, 7 * u),
          child: Row(children: [
            Icon(maneuverIcon(st.navManeuverType, st.navManeuverModifier), color: Colors.white, size: 24 * u),
            SizedBox(width: 7 * u),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(formatNavDistance(st.navManeuverDistance, st.isMetric), style: s(16, FontWeight.bold)),
                ),
                Text(street, maxLines: 2, overflow: TextOverflow.ellipsis, style: s(9.5, FontWeight.w600)),
              ]),
            ),
          ]),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 8 * u, vertical: 5 * u),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(formatArrival(arrival), style: s(9, FontWeight.w600, const Color(0xFFD0D0D0))),
              SizedBox(width: 10 * u),
              Text(formatNavDuration(st.navTimeRemaining), style: s(9, FontWeight.w600, const Color(0xFFD0D0D0))),
              SizedBox(width: 10 * u),
              Text(formatNavDistance(st.navDistanceRemaining, st.isMetric), style: s(9, FontWeight.w600, const Color(0xFFD0D0D0))),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// the small heading-up map in the bottom-left corner
class MiniMap extends StatelessWidget {
  final UIState uiState;
  final double unit;
  final bool tiles;
  final bool light;

  const MiniMap({super.key, required this.uiState, required this.unit, this.tiles = true, this.light = false});

  @override
  Widget build(BuildContext context) {
    final u = unit;
    return Container(
      key: const ValueKey('miniMap'),
      width: miniMapWidth * u,
      height: miniMapHeight * u,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9 * u),
        border: Border.all(color: const Color(0x33FFFFFF), width: 1.2 * u),
      ),
      clipBehavior: Clip.antiAlias,
      // the map's own sizes are in the 1920x1000 mockup's pixels: about a third of a comma four unit
      child: NavMap(uiState: uiState, unit: u / 3.3, interactive: false, zoom: navMiniZoom, tiles: tiles && hasMapKey, light: light),
    );
  }
}
