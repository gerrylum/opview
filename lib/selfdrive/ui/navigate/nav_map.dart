// the map for Navigate and the mini map while driving: MapTiler tiles drawn by flutter_map,
// navd's route, the truck (comma GPS) and the destination. Heading up while it follows the truck
// (Gerry 2026-11-05); dragging stops following until the recentre button

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/nav/maptiler.dart';

const navRouteColor = Color(0xFF3D8BFF);
const navPinColor = Color(0xFFFF4D4D);

/// where the map starts before any GPS fix: the middle of the US
const _fallbackCenter = LatLng(39.8, -98.6);

/// how far in the map sits while following, and in the mini map
const navFollowZoom = 16.0;
const navMiniZoom = 15.0;

/// the map's rotation for heading up: the map turns against the truck's heading
double headingUpRotation(double bearingDeg) => -bearingDeg;

class NavMap extends StatefulWidget {
  final UIState uiState;
  final double unit;

  /// drag and zoom, with the zoom and recentre buttons
  final bool interactive;

  /// a destination picked but not yet routed by the comma (shown as the pin until navd's own)
  final (double, double)? destination;

  /// show the whole route instead of following the truck (the route preview)
  final bool overview;

  final double zoom;

  /// MapTiler's light street map instead of the dark one (Settings > Navigation)
  final bool light;

  /// the driver's MapTiler key for the tiles; none (or in tests) draws the map without them
  final String? mapKey;

  const NavMap({
    super.key,
    required this.uiState,
    required this.unit,
    this.interactive = true,
    this.destination,
    this.overview = false,
    this.zoom = navFollowZoom,
    this.light = false,
    this.mapKey,
  });

  bool get tiles => mapKey != null;

  @override
  State<NavMap> createState() => NavMapState();
}

class NavMapState extends State<NavMap> {
  final controller = MapController();

  // one tile provider for the map's life (it holds the HTTP client); the headers must be a map
  // flutter_map can add to
  late final _tileProvider = NetworkTileProvider(headers: {...mapTilerHeaders});
  bool _ready = false;
  bool following = true;
  (double, double, double)? _lastGps;
  int _lastRouteLength = -1;
  bool _fitted = false;

  UIState get st => widget.uiState;

  @override
  void initState() {
    super.initState();
    st.addListener(_changed);
  }

  @override
  void didUpdateWidget(NavMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uiState != st) {
      oldWidget.uiState.removeListener(_changed);
      st.addListener(_changed);
    }
    if (oldWidget.overview != widget.overview) {
      _fitted = false;
      following = !widget.overview;
      WidgetsBinding.instance.addPostFrameCallback((_) => _place());
    }
  }

  @override
  void dispose() {
    st.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  // UIState changes 20 times a second; the map only moves when the GPS or the route does
  void _changed() {
    final gps = st.gpsFix ? (st.gpsLat, st.gpsLon, st.gpsBearing) : null;
    final routeChanged = st.navRoute.length != _lastRouteLength;
    if (gps == _lastGps && !routeChanged) return;
    _lastGps = gps;
    if (routeChanged) {
      _lastRouteLength = st.navRoute.length;
      _fitted = false;
    }
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _place());
  }

  LatLng? get _me => st.gpsFix ? LatLng(st.gpsLat, st.gpsLon) : null;

  /// move the camera: onto the truck while following, or around the route in the overview
  void _place() {
    if (!_ready || !mounted) return;
    try {
      if (widget.overview) {
        if (_fitted) return;
        final pts = [
          for (final (lat, lon) in st.navRoute) LatLng(lat, lon),
          if (_me != null) _me!,
          if (_dest != null) _dest!,
        ];
        if (pts.length >= 2) {
          controller.fitCamera(CameraFit.coordinates(coordinates: pts, padding: EdgeInsets.all(60 * widget.unit), maxZoom: 17));
          controller.rotate(0);
          _fitted = true;
        } else if (pts.length == 1) {
          controller.move(pts.first, widget.zoom);
        }
        return;
      }
      final me = _me;
      if (following && me != null) {
        controller.moveAndRotate(me, controller.camera.zoom < 3 ? widget.zoom : controller.camera.zoom, headingUpRotation(st.gpsBearing));
      }
    } catch (_) {
      // the map is not laid out yet
    }
  }

  LatLng? get _dest {
    final d = widget.destination ?? st.navDestination;
    return d == null ? null : LatLng(d.$1, d.$2);
  }

  void recentre() {
    setState(() => following = true);
    _place();
  }

  void zoomBy(double d) {
    if (!_ready) return;
    final cam = controller.camera;
    controller.move(cam.center, (cam.zoom + d).clamp(3.0, 19.0));
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.unit;
    final me = _me;
    final dest = _dest;
    final route = [for (final (lat, lon) in st.navRoute) LatLng(lat, lon)];
    return Stack(fit: StackFit.expand, children: [
      ColoredBox(
        color: const Color(0xFF1B1D20),
        child: FlutterMap(
          mapController: controller,
          options: MapOptions(
            initialCenter: me ?? _fallbackCenter,
            initialZoom: me == null ? 3 : widget.zoom,
            initialRotation: me == null || widget.overview ? 0 : headingUpRotation(st.gpsBearing),
            backgroundColor: const Color(0xFF1B1D20),
            interactionOptions: InteractionOptions(flags: widget.interactive ? InteractiveFlag.all & ~InteractiveFlag.rotate : InteractiveFlag.none),
            onMapReady: () {
              _ready = true;
              _place();
            },
            onPositionChanged: (camera, hasGesture) {
              // the driver moved the map: stop following until Recentre
              if (hasGesture && following) setState(() => following = false);
            },
          ),
          children: [
            if (widget.tiles)
              TileLayer(
                urlTemplate: mapTileUrl(widget.mapKey!, light: widget.light),
                userAgentPackageName: 'OPRivView',
                tileProvider: _tileProvider,
                maxZoom: 19,
              ),
            if (route.length >= 2)
              PolylineLayer(polylines: [
                Polyline(points: route, strokeWidth: 9 * u, color: navRouteColor, borderStrokeWidth: 3 * u, borderColor: const Color(0xFF0B3C8C)),
              ]),
            MarkerLayer(markers: [
              if (dest != null)
                Marker(
                  point: dest,
                  width: 44 * u,
                  height: 56 * u,
                  alignment: Alignment.topCenter,
                  rotate: true,  // the pin stays upright as the map turns
                  child: Icon(Icons.location_on, key: const ValueKey('navPin'), color: navPinColor, size: 56 * u),
                ),
              if (me != null)
                Marker(
                  point: me,
                  width: 64 * u,
                  height: 64 * u,
                  child: Transform.rotate(
                    // turns with the map; pointing along the heading it ends up pointing up while heading up
                    angle: st.gpsBearing * pi / 180,
                    child: Container(
                      key: const ValueKey('navMe'),
                      decoration: const BoxDecoration(color: Color(0x553D8BFF), shape: BoxShape.circle),
                      child: Icon(Icons.navigation, color: Colors.white, size: 36 * u),
                    ),
                  ),
                ),
            ]),
          ],
        ),
      ),
      // MapTiler and OpenStreetMap must be credited on the map
      Positioned(
        right: 8 * u,
        bottom: 6 * u,
        child: Text(mapAttribution, style: TextStyle(color: const Color(0xB3FFFFFF), fontSize: (widget.interactive ? 14 : 10) * u)),
      ),
      if (!widget.tiles)
        Center(
          child: Text(
            'No map: add a MapTiler key in Settings › Navigation',
            key: const ValueKey('navNoKey'),
            style: TextStyle(color: const Color(0x99FFFFFF), fontSize: 20 * u),
          ),
        ),
      if (me == null)
        Positioned(
          top: 12 * u,
          right: 12 * u,
          child: Container(
            key: const ValueKey('navNoGps'),
            padding: EdgeInsets.symmetric(horizontal: 14 * u, vertical: 8 * u),
            decoration: BoxDecoration(color: const Color(0xCC16171A), borderRadius: BorderRadius.circular(10 * u)),
            child: Text('Waiting for the comma\'s GPS', style: TextStyle(color: Colors.white70, fontSize: 18 * u)),
          ),
        ),
      if (widget.interactive)
        Positioned(
          right: 20 * u,
          bottom: 40 * u,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _button(Icons.add, () => zoomBy(1), 'navZoomIn'),
            SizedBox(height: 12 * u),
            _button(Icons.remove, () => zoomBy(-1), 'navZoomOut'),
            SizedBox(height: 12 * u),
            _button(following ? Icons.navigation : Icons.my_location, recentre, 'navRecentre'),
          ]),
        ),
    ]);
  }

  Widget _button(IconData icon, VoidCallback onTap, String key) {
    final u = widget.unit;
    return Material(
      color: const Color(0xE616171A),
      borderRadius: BorderRadius.circular(16 * u),
      child: InkWell(
        key: ValueKey(key),
        onTap: onTap,
        borderRadius: BorderRadius.circular(16 * u),
        child: SizedBox(width: 72 * u, height: 72 * u, child: Icon(icon, color: Colors.white, size: 38 * u)),
      ),
    );
  }
}
