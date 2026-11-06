// Navigate: search for a place (MapTiler), send it to the comma, which plans the route (navd).
// It fills the camera area like the Gallery; the menu and status bar stay.
//
//   search panel (left) over the map: field, Home / Work / recent chips, results with distance
//   picked: the destination goes to the comma at once (Gerry 2026-11-05: send on pick); the card
//           shows navd's arrival time, time and distance with Start (back to driving) and Cancel
//   already routing: the current route's card with End route
//   typing: while the keyboard is up the search goes wide across the top, results three across
//           above the keyboard (Gerry 2026-11-05, mockup K1); the rest of the app keeps its size
//   no MapTiler key: a card saying how to get one, in place of the search (the driver's own key,
//           Settings > Navigation; the builds carry none)
//
// Sizes are in the redesign mockup's pixels (1920x1000), scaled by `unit`

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:opview/selfdrive/ui/navigate/nav_map.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/nav/maptiler.dart';
import 'package:opview/services/nav/places.dart';

typedef PlaceSearch = Future<List<Place>> Function(String query, double? lat, double? lon);

/// sends a destination to the comma (null clears it); false when not connected
typedef SendDestination = Future<bool> Function((double, double)? destination);

/// how long the card waits for navd before saying why there may be no route
const navPlanningPatience = Duration(seconds: 20);

const _panel = Color(0xF2121314);
const _row = Color(0xFF1C1D1F);
const _blue = Color(0xFF3D8BFF);
const _grey = Color(0xFF8C8C8C);

class NavigateView extends StatefulWidget {
  final UIState uiState;
  final AppSettings settings;
  final double unit;
  final SendDestination send;

  /// back to the driving view
  final VoidCallback onClose;

  /// replaceable in tests (MapTiler geocoding otherwise)
  final PlaceSearch? search;

  /// load MapTiler tiles under the map (off in tests); needs the driver's key too
  final bool tiles;

  /// opens Settings > Navigation to add a MapTiler key
  final VoidCallback? onAddKey;

  const NavigateView({
    super.key,
    required this.uiState,
    required this.settings,
    required this.unit,
    required this.send,
    required this.onClose,
    this.search,
    this.tiles = true,
    this.onAddKey,
  });

  @override
  State<NavigateView> createState() => _NavigateViewState();
}

class _NavigateViewState extends State<NavigateView> {
  final _field = TextEditingController();
  // the field moves between the side panel and the wide layout as the keyboard comes and goes;
  // the same node and key keep its focus (and the keyboard) through the move
  final _focus = FocusNode();
  final _fieldKey = GlobalKey();
  http.Client? _client;
  Timer? _debounce;
  int _query = 0;
  List<Place> _results = const [];
  bool _searching = false;
  String? _searchError;

  /// the place just picked (sent to the comma), until Start, Cancel or a new search
  Place? _picked;
  DateTime? _pickedAt;
  String? _sendError;

  /// searching for a new destination while one is being routed
  bool _newSearch = false;

  UIState get st => widget.uiState;
  double get u => widget.unit;
  String? get _key => widget.settings.mapTilerKey;

  /// search works: the driver's key, or a search given by a test
  bool get _canSearch => _key != null || widget.search != null;

  @override
  void initState() {
    super.initState();
    st.addListener(_changed);
  }

  @override
  void dispose() {
    st.removeListener(_changed);
    _debounce?.cancel();
    _client?.close();
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  // the card follows navd (the route arriving, the comma's answer); 20 updates a second is
  // more than it needs, so only rebuild on what it shows
  (bool, int, String?, (double, double)?, bool?)? _seen;
  void _changed() {
    final now = (st.navValid, st.navRoute.length, st.navDestinationError, st.navDestination, st.navigationEnabled);
    if (now == _seen || !mounted) return;
    _seen = now;
    setState(() {});
  }

  Future<List<Place>> _doSearch(String q, double? lat, double? lon) {
    final s = widget.search;
    if (s != null) return s(q, lat, lon);
    final key = _key;
    if (key == null) return Future.error(StateError('Add a MapTiler key in Settings › Navigation'));
    return searchPlaces(_client ??= http.Client(), key, q, lat: lat, lon: lon);
  }

  void _onQuery(String text) {
    _debounce?.cancel();
    final q = text.trim();
    if (q.length < 3) {
      setState(() {
        _results = const [];
        _searching = false;
        _searchError = null;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final id = ++_query;
      try {
        final r = await _doSearch(q, st.gpsFix ? st.gpsLat : null, st.gpsFix ? st.gpsLon : null);
        if (!mounted || id != _query) return;
        setState(() {
          _results = r;
          _searching = false;
          _searchError = r.isEmpty ? 'Nothing found' : null;
        });
      } catch (e) {
        if (!mounted || id != _query) return;
        setState(() {
          _results = const [];
          _searching = false;
          _searchError = e is StateError ? e.message : 'Search failed: no internet on the head unit?';
        });
      }
    });
  }

  Future<void> _pick(Place p) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _picked = p;
      _pickedAt = DateTime.now();
      _sendError = null;
      _newSearch = false;
    });
    widget.settings.addNavRecent(p);
    final ok = await widget.send((p.lat, p.lon));
    if (!ok && mounted) setState(() => _sendError = 'Not connected to the comma');
  }

  Future<void> _cancel() async {
    await widget.send(null);
    if (!mounted) return;
    setState(() {
      _picked = null;
      _newSearch = false;
    });
  }

  /// the name for a destination the comma already has (picked here earlier, or from elsewhere)
  Place _currentPlace((double, double) d) {
    final probe = Place(name: '', address: '', lat: d.$1, lon: d.$2);
    final s = widget.settings;
    for (final p in [if (s.navHome != null) s.navHome!, if (s.navWork != null) s.navWork!, ...s.navRecents]) {
      if (p.sameSpot(probe)) return p;
    }
    return Place(name: 'Current destination', address: '${d.$1.toStringAsFixed(5)}, ${d.$2.toStringAsFixed(5)}', lat: d.$1, lon: d.$2);
  }

  @override
  Widget build(BuildContext context) {
    final current = st.navDestination;
    final picked = _picked;
    final Widget panel;
    if (picked != null) {
      panel = _routeCard(picked, justPicked: true);
    } else if (current != null && !_newSearch) {
      panel = _routeCard(_currentPlace(current), justPicked: false);
    } else {
      panel = _searchPanel();
    }
    final showRoute = picked != null || (current != null && !_newSearch);
    // the keyboard is up over the search: go wide, in the space above it
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final typing = !showRoute && _canSearch && keyboard > 0;
    return LayoutBuilder(builder: (context, c) {
      // Navigate starts at the top of the screen, so this much of it shows above the keyboard
      final above = (MediaQuery.sizeOf(context).height - keyboard).clamp(0.0, c.maxHeight).toDouble();
      return Container(
        key: const ValueKey('navigateView'),
        color: Colors.black,
        child: Stack(fit: StackFit.expand, children: [
          NavMap(
            uiState: st,
            unit: u,
            destination: picked == null ? null : (picked.lat, picked.lon),
            overview: showRoute && picked != null,
            mapKey: widget.tiles ? _key : null,
            light: widget.settings.mapStyle == MapStyle.streets,
          ),
          if (typing) ...[
            const ColoredBox(color: Color(0xB8000000)),
            Positioned(left: 24 * u, top: 22 * u, right: 24 * u, height: (above - 34 * u).clamp(0.0, above).toDouble(), child: _wideSearch()),
          ] else
            Positioned(left: 20 * u, top: 20 * u, bottom: showRoute || !_canSearch ? null : 20 * u, width: 680 * u, child: panel),
        ]),
      );
    });
  }

  // -- no key --

  Widget _noKeyCard() {
    return Container(
      key: const ValueKey('navNoKeyCard'),
      padding: EdgeInsets.all(26 * u),
      decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(24 * u)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Icon(Icons.vpn_key_outlined, color: const Color(0xFFFFB020), size: 44 * u),
        SizedBox(height: 14 * u),
        Text('Navigation needs a MapTiler key',
            style: TextStyle(color: Colors.white, fontSize: 32 * u, fontWeight: FontWeight.bold)),
        SizedBox(height: 12 * u),
        Text('The map and place search come from MapTiler, with your own free key.',
            style: TextStyle(color: const Color(0xFFBFBFBF), fontSize: 22 * u, height: 1.3)),
        SizedBox(height: 14 * u),
        for (final step in const [
          '1.  Sign up free at maptiler.com',
          '2.  Account › API keys: copy your key',
          '3.  Settings › Navigation › MapTiler key: paste it',
        ])
          Padding(
            padding: EdgeInsets.only(bottom: 8 * u),
            child: Text(step, style: TextStyle(color: Colors.white, fontSize: 23 * u)),
          ),
        SizedBox(height: 6 * u),
        Text('Leave the key unrestricted, or allow the User-Agent "OPRivView". '
            'Routes the comma already has still show their turns while driving.',
            style: TextStyle(color: _grey, fontSize: 19 * u, height: 1.3)),
        if (widget.onAddKey != null) ...[
          SizedBox(height: 20 * u),
          _bigButton('Add key in Settings', widget.onAddKey!, primary: true, key: 'navAddKey'),
        ],
      ]),
    );
  }

  // -- search --

  List<(IconData, Place)> get _chipPlaces {
    final s = widget.settings;
    return [
      if (s.navHome != null) (Icons.home_outlined, s.navHome!),
      if (s.navWork != null) (Icons.work_outline, s.navWork!),
      for (final r in s.navRecents.take(4)) (Icons.history, r),
    ];
  }

  /// the search field; the same one in both layouts (see _focus)
  Widget _searchField({double size = 30}) {
    return KeyedSubtree(
      key: _fieldKey,
      child: TextField(
        key: const ValueKey('navSearchField'),
        controller: _field,
        focusNode: _focus,
        autofocus: st.navDestination == null,
        onChanged: _onQuery,
        textInputAction: TextInputAction.search,
        style: TextStyle(color: Colors.white, fontSize: size * u),
        decoration: InputDecoration(
          hintText: 'Search for a place or address',
          hintStyle: TextStyle(color: _grey, fontSize: 28 * u),
          prefixIcon: Icon(Icons.search, color: Colors.white70, size: 34 * u),
          suffixIcon: _field.text.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Icons.close, color: Colors.white70, size: 30 * u),
                  onPressed: () {
                    _field.clear();
                    _onQuery('');
                  },
                ),
          filled: true,
          fillColor: _row,
          contentPadding: EdgeInsets.symmetric(vertical: 20 * u),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16 * u), borderSide: const BorderSide(color: _blue, width: 2)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16 * u), borderSide: const BorderSide(color: _blue, width: 2)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16 * u), borderSide: const BorderSide(color: _blue, width: 2)),
        ),
      ),
    );
  }

  /// Home, Work and recent places, one tap each
  Widget _chips(List<(IconData, Place)> chips) {
    return SizedBox(
      height: 52 * u,
      child: ListView(scrollDirection: Axis.horizontal, children: [
        for (final (icon, p) in chips)
          Padding(
            padding: EdgeInsets.only(right: 10 * u),
            child: Material(
              color: _row,
              borderRadius: BorderRadius.circular(22 * u),
              child: InkWell(
                key: ValueKey('navChip_${p.name}'),
                borderRadius: BorderRadius.circular(22 * u),
                onTap: () => _pick(p),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 18 * u),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, color: Colors.white70, size: 24 * u),
                    SizedBox(width: 8 * u),
                    Text(icon == Icons.home_outlined ? 'Home' : (icon == Icons.work_outline ? 'Work' : p.name),
                        style: TextStyle(color: Colors.white, fontSize: 22 * u, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget get _resultsLabel =>
      Text('RESULTS', style: TextStyle(color: _grey, fontSize: 19 * u, fontWeight: FontWeight.w700, letterSpacing: 1 * u));

  /// the results: a list in the side panel, a grid [columns] across while typing
  Widget _resultsBody({int columns = 1}) {
    if (_searching && _results.isEmpty) {
      return Align(alignment: Alignment.topCenter, child: SizedBox(width: 36 * u, height: 36 * u, child: const CircularProgressIndicator(strokeWidth: 3)));
    }
    if (_searchError != null) {
      return Text(_searchError!, key: const ValueKey('navSearchError'), style: TextStyle(color: _grey, fontSize: 22 * u));
    }
    if (columns == 1) {
      return ListView.separated(
        itemCount: _results.length,
        separatorBuilder: (_, __) => SizedBox(height: 12 * u),
        itemBuilder: (_, i) => _result(_results[i]),
      );
    }
    return GridView.builder(
      key: const ValueKey('navResultsGrid'),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 14 * u,
        crossAxisSpacing: 14 * u,
        // the card's two lines and padding, with room to spare (fonts measure taller than their size)
        mainAxisExtent: 116 * u,
      ),
      itemCount: _results.length,
      itemBuilder: (_, i) => _result(_results[i], selected: i == 0),
    );
  }

  Widget _searchPanel() {
    if (!_canSearch) return _noKeyCard();
    final chips = _chipPlaces;
    return Container(
      key: const ValueKey('navSearchPanel'),
      padding: EdgeInsets.all(26 * u),
      decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(24 * u)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: _searchField()),
          if (st.navDestination != null) ...[
            SizedBox(width: 12 * u),
            _button('Back', () => setState(() => _newSearch = false), key: 'navSearchBack'),
          ],
        ]),
        if (chips.isNotEmpty) ...[
          SizedBox(height: 16 * u),
          _chips(chips),
        ],
        SizedBox(height: 18 * u),
        _resultsLabel,
        SizedBox(height: 10 * u),
        Expanded(child: _resultsBody()),
        Text('Search works anytime · the comma plans the route while driving', style: TextStyle(color: _grey, fontSize: 19 * u)),
      ]),
    );
  }

  /// while the keyboard is up: the field across the top, the places under it, the results in a
  /// grid filling what is left above the keyboard
  Widget _wideSearch() {
    final chips = _chipPlaces;
    return LayoutBuilder(builder: (context, c) {
      final columns = c.maxWidth >= 1200 * u ? 3 : 2;
      final shown = _results.length;
      return Column(key: const ValueKey('navSearchWide'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: _searchField(size: 34)),
          SizedBox(width: 14 * u),
          // puts the keyboard away, and with it the wide layout
          _bigButtonFit('Cancel', () => _focus.unfocus(), key: 'navKeyboardCancel'),
          if (st.navDestination != null) ...[
            SizedBox(width: 12 * u),
            _bigButtonFit('Back', () {
              _focus.unfocus();
              setState(() => _newSearch = false);
            }, key: 'navSearchBack'),
          ],
        ]),
        if (chips.isNotEmpty) ...[
          SizedBox(height: 14 * u),
          _chips(chips),
        ],
        SizedBox(height: 14 * u),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          _resultsLabel,
          const Spacer(),
          if (shown > 0)
            Text('Tap one to see the route and start${shown > columns * 2 ? ' · scroll for more' : ''}',
                style: TextStyle(color: _grey, fontSize: 19 * u)),
        ]),
        SizedBox(height: 10 * u),
        Expanded(child: _resultsBody(columns: columns)),
      ]);
    });
  }

  Widget _result(Place p, {bool selected = false}) {
    final dist = st.gpsFix ? formatNavDistance(distanceMetres(st.gpsLat, st.gpsLon, p.lat, p.lon), st.isMetric) : '';
    return Material(
      color: selected ? const Color(0xFF24272B) : _row,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16 * u),
        side: selected ? BorderSide(color: _blue, width: 2 * u) : BorderSide.none,
      ),
      child: InkWell(
        key: ValueKey('navResult_${p.name}'),
        borderRadius: BorderRadius.circular(16 * u),
        onTap: () => _pick(p),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 20 * u, vertical: 16 * u),
          child: Row(children: [
            Icon(Icons.place_outlined, color: Colors.white70, size: 34 * u),
            SizedBox(width: 18 * u),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: 26 * u, fontWeight: FontWeight.bold)),
                SizedBox(height: 4 * u),
                Text(p.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: const Color(0xFFBFBFBF), fontSize: 19 * u)),
              ]),
            ),
            if (dist.isNotEmpty) ...[
              SizedBox(width: 12 * u),
              Text(dist, style: TextStyle(color: const Color(0xFFD0D0D0), fontSize: 21 * u, fontWeight: FontWeight.w600)),
            ],
          ]),
        ),
      ),
    );
  }

  // -- the route card --

  Widget _routeCard(Place p, {required bool justPicked}) {
    final error = _sendError ?? (st.navDestinationError?.isNotEmpty == true ? st.navDestinationError : null);
    // navd's figures are for this place once the comma has taken it as its destination
    final dest = st.navDestination;
    final routed = st.navValid && dest != null && (!justPicked || p.sameSpot(Place(name: '', address: '', lat: dest.$1, lon: dest.$2)));
    final waitedLong = _pickedAt != null && DateTime.now().difference(_pickedAt!) > navPlanningPatience;
    final Widget status;
    if (error != null) {
      status = _note(error, key: 'navError', color: const Color(0xFFFF6B6B));
    } else if (st.navigationEnabled == false) {
      status = _note('Turn on Navigation on the comma: it plans the route', key: 'navTurnOn', color: const Color(0xFFFFB020));
    } else if (routed) {
      final arrival = DateTime.now().add(Duration(seconds: st.navTimeRemaining.round()));
      status = Row(key: const ValueKey('navEta'), children: [
        _figure('ARRIVE', formatArrival(arrival)),
        SizedBox(width: 34 * u),
        _figure('TIME', formatNavDuration(st.navTimeRemaining)),
        SizedBox(width: 34 * u),
        _figure('DISTANCE', formatNavDistance(st.navDistanceRemaining, st.isMetric)),
      ]);
    } else {
      status = _note(
        waitedLong
            ? 'No route yet: the comma plans routes while driving, with a GPS fix'
            : 'Planning the route on the comma…',
        key: waitedLong ? 'navNoRoute' : 'navPlanning',
      );
    }
    return Container(
      key: const ValueKey('navRouteCard'),
      padding: EdgeInsets.all(26 * u),
      decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(24 * u)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: 32 * u, fontWeight: FontWeight.bold)),
        if (p.address.isNotEmpty) ...[
          SizedBox(height: 6 * u),
          Text(p.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: const Color(0xFFBFBFBF), fontSize: 22 * u)),
        ],
        SizedBox(height: 18 * u),
        status,
        SizedBox(height: 20 * u),
        Row(children: [
          Expanded(
            child: justPicked
                ? _bigButton('Start', widget.onClose, primary: true, key: 'navStart')
                : _bigButton('Back to driving', widget.onClose, primary: true, key: 'navBackToDriving'),
          ),
          SizedBox(width: 14 * u),
          Expanded(child: _bigButton(justPicked ? 'Cancel' : 'End route', _cancel, key: justPicked ? 'navCancel' : 'navEndRoute')),
        ]),
        SizedBox(height: 14 * u),
        Wrap(spacing: 10 * u, runSpacing: 10 * u, children: [
          _button('Save as Home', () => widget.settings.setNavHome(p), key: 'navSaveHome'),
          _button('Save as Work', () => widget.settings.setNavWork(p), key: 'navSaveWork'),
          if (!justPicked) _button('New destination', () => setState(() => _newSearch = true), key: 'navNewSearch'),
        ]),
      ]),
    );
  }

  Widget _figure(String label, String value) => Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(color: _grey, fontSize: 19 * u, fontWeight: FontWeight.w700, letterSpacing: 1 * u)),
            SizedBox(height: 4 * u),
            Text(value, style: TextStyle(color: Colors.white, fontSize: 38 * u, fontWeight: FontWeight.bold)),
          ]),
        ),
      );

  Widget _note(String text, {required String key, Color color = const Color(0xFFBFBFBF)}) =>
      Text(text, key: ValueKey(key), style: TextStyle(color: color, fontSize: 22 * u));

  Widget _bigButton(String text, VoidCallback onTap, {bool primary = false, required String key}) {
    return Material(
      color: primary ? _blue : const Color(0xFF2E3034),
      borderRadius: BorderRadius.circular(16 * u),
      child: InkWell(
        key: ValueKey(key),
        onTap: onTap,
        borderRadius: BorderRadius.circular(16 * u),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 20 * u),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(text, style: TextStyle(color: Colors.white, fontSize: 28 * u, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ),
    );
  }

  /// a big button as wide as its text (the wide search's Cancel and Back)
  Widget _bigButtonFit(String text, VoidCallback onTap, {required String key}) {
    return Material(
      color: const Color(0xFF2E3034),
      borderRadius: BorderRadius.circular(16 * u),
      child: InkWell(
        key: ValueKey(key),
        onTap: onTap,
        borderRadius: BorderRadius.circular(16 * u),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 30 * u, vertical: 22 * u),
          child: Text(text, style: TextStyle(color: const Color(0xFFD0D0D0), fontSize: 28 * u, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _button(String text, VoidCallback onTap, {required String key}) {
    return Material(
      color: const Color(0xFF2E3034),
      borderRadius: BorderRadius.circular(12 * u),
      child: InkWell(
        key: ValueKey(key),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12 * u),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16 * u, vertical: 10 * u),
          child: Text(text, style: TextStyle(color: Colors.white, fontSize: 19 * u, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}
