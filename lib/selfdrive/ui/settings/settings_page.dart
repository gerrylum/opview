// Settings, as a page in the camera area like the Gallery (Gerry 2026-11-05: idea A, mockups
// opview-mici/preview/settings2/S1-S6). Categories down the left, a fixed header with Done:
//   Driving view    a picture of the screen to tap parts on and off, the same as switches, the
//                   speed limit sign
//   Display         brightness, clock, keep the screen on
//   Recording       Keep the last, storage limit, what is stored, delete unstarred clips
//   Navigation      the driver's MapTiler key, the comma's navigation and GPS, Home / Work, recent
//                   places, map style
//   Comma device    the connection, the comma's own settings (read only), camera, reconnect
//   Updates & about in-app updates, version, licences
// Sizes are in the redesign mockup's pixels (1920x1000), scaled by `unit`

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:opview/selfdrive/ui/shell/menu_rail.dart' show formatRecordingTime;
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/nav/maptiler.dart';
import 'package:opview/services/nav/places.dart';
import 'package:opview/services/recorder/clip_store.dart';
import 'package:opview/services/recorder/recorder.dart';
import 'package:opview/services/updater.dart';

enum SettingsCategory { drivingView, display, recording, navigation, comma, about }

String settingsCategoryLabel(SettingsCategory c) => switch (c) {
      SettingsCategory.drivingView => 'Driving view',
      SettingsCategory.display => 'Display',
      SettingsCategory.recording => 'Recording',
      SettingsCategory.navigation => 'Navigation',
      SettingsCategory.comma => 'Comma device',
      SettingsCategory.about => 'Updates & about',
    };

IconData _categoryIcon(SettingsCategory c) => switch (c) {
      SettingsCategory.drivingView => Icons.desktop_windows_outlined,
      SettingsCategory.display => Icons.wb_sunny_outlined,
      SettingsCategory.recording => Icons.radio_button_checked,
      SettingsCategory.navigation => Icons.navigation_outlined,
      SettingsCategory.comma => Icons.memory,
      SettingsCategory.about => Icons.info_outline,
    };

/// the Driving view switches, grouped by where they sit on the screen
const drivingViewGroups = <(String, List<DriveSection?>)>[
  // null is the speed limit sign (Settings' speed limit choice, not a section)
  ('TOP', [DriveSection.speed, null, DriveSection.roadName, DriveSection.driver, DriveSection.confidence]),
  ('BOTTOM', [DriveSection.steering, DriveSection.lead, DriveSection.torque, DriveSection.statusBar]),
  ('WHILE NAVIGATING', [DriveSection.turnBanner, DriveSection.miniMap]),
];

const _bg = Color(0xFF0B0C0D);
const _card = Color(0xFF17181A);
const _label = Color(0xFF8C8C8C);
const _value = Color(0xFFBFBFBF);
const _green = Color(0xFF3ADB6D);
const _blue = Color(0xFF3D8BFF);
const _amber = Color(0xFFFFB020);

class SettingsPage extends StatefulWidget {
  final AppSettings settings;
  final UIState uiState;
  final double unit;
  final VoidCallback onDone;
  final Recorder? recorder;
  final Updater updater;

  /// the comma's address and whether it was typed in; [onChangeHost] asks for a new one
  final String? host;
  final bool hostIsManual;
  final VoidCallback? onChangeHost;
  final VoidCallback? onReconnect;

  /// tries a MapTiler key before it is saved: null when it works, otherwise why not (a real
  /// request to MapTiler unless replaced, in tests)
  final Future<String?> Function(String key)? checkMapKey;

  /// this build's name, under the categories
  final String? build;

  final SettingsCategory initial;

  const SettingsPage({
    super.key,
    required this.settings,
    required this.uiState,
    required this.unit,
    required this.onDone,
    required this.updater,
    this.recorder,
    this.host,
    this.hostIsManual = false,
    this.onChangeHost,
    this.onReconnect,
    this.checkMapKey,
    this.build,
    this.initial = SettingsCategory.drivingView,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late SettingsCategory _cat = widget.initial;

  // what the Recording page shows about the clips, read when it opens
  List<Clip>? _clips;

  double get u => widget.unit;
  AppSettings get s => widget.settings;
  UIState get st => widget.uiState;

  @override
  void initState() {
    super.initState();
    if (_cat == SettingsCategory.recording) _loadClips();
  }

  Future<void> _loadClips() async {
    final store = await widget.recorder?.store();
    final clips = store == null ? <Clip>[] : await store.list();
    if (mounted) setState(() => _clips = clips);
  }

  void _open(SettingsCategory c) {
    setState(() => _cat = c);
    if (c == SettingsCategory.recording) _loadClips();
  }

  @override
  Widget build(BuildContext context) {
    // follows the settings, the updater (the update card's progress), and the comma on the
    // pages that show its readouts
    final readsComma = _cat == SettingsCategory.comma || _cat == SettingsCategory.navigation;
    return ListenableBuilder(
      listenable: Listenable.merge(
          [s, widget.updater, if (widget.recorder != null) widget.recorder!, if (readsComma) st]),
      builder: (context, _) => Container(
        key: const ValueKey('settingsPage'),
        color: _bg,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _categories(),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(30 * u, 26 * u, 30 * u, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(
                    child: Text(settingsCategoryLabel(_cat),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white, fontSize: 32 * u, fontWeight: FontWeight.bold, height: 1.0)),
                  ),
                  _button('Done', widget.onDone, primary: true, key: 'settingsDone'),
                ]),
                SizedBox(height: 18 * u),
                Expanded(
                  child: SingleChildScrollView(
                    key: ValueKey('settingsBody_${_cat.name}'),
                    padding: EdgeInsets.only(bottom: 26 * u),
                    child: _body(),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _categories() {
    final updateWaiting = widget.updater.status == UpdateStatus.available;
    return Container(
      width: 360 * u,
      padding: EdgeInsets.fromLTRB(18 * u, 26 * u, 18 * u, 20 * u),
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: Color(0x0FFFFFFF)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(10 * u, 0, 0, 18 * u),
          child: Text('Settings', style: TextStyle(color: Colors.white, fontSize: 34 * u, fontWeight: FontWeight.bold, height: 1.0)),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final c in SettingsCategory.values)
                Padding(
                  padding: EdgeInsets.only(bottom: 6 * u),
                  child: Material(
                    color: c == _cat ? const Color(0xFF2A2C30) : Colors.transparent,
                    borderRadius: BorderRadius.circular(16 * u),
                    child: InkWell(
                      key: ValueKey('settingsCat_${c.name}'),
                      borderRadius: BorderRadius.circular(16 * u),
                      onTap: () => _open(c),
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 18 * u, vertical: 16 * u),
                        child: Row(children: [
                          Icon(_categoryIcon(c), color: c == _cat ? Colors.white : const Color(0xFF9A9A9A), size: 32 * u),
                          SizedBox(width: 16 * u),
                          Expanded(
                            child: Text(settingsCategoryLabel(c),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: c == _cat ? Colors.white : _value,
                                  fontSize: 24 * u,
                                  fontWeight: c == _cat ? FontWeight.bold : FontWeight.w500,
                                  height: 1.0,
                                )),
                          ),
                          if (c == SettingsCategory.about && updateWaiting)
                            Container(
                              key: const ValueKey('settingsUpdateDot'),
                              width: 12 * u,
                              height: 12 * u,
                              decoration: const BoxDecoration(color: _amber, shape: BoxShape.circle),
                            ),
                        ]),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        if (widget.build != null)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 12 * u),
            child: Text('OPRivView · ${widget.build}', style: TextStyle(color: const Color(0xFF6E6E6E), fontSize: 17 * u)),
          ),
      ]),
    );
  }

  Widget _body() => switch (_cat) {
        SettingsCategory.drivingView => _drivingView(),
        SettingsCategory.display => _display(),
        SettingsCategory.recording => _recording(),
        SettingsCategory.navigation => _navigation(),
        SettingsCategory.comma => _comma(),
        SettingsCategory.about => _about(),
      };

  // -- Driving view --

  bool _shown(DriveSection? section) => section == null ? s.speedLimitDisplay != SpeedLimitDisplay.off : s.shows(section);

  void _toggle(DriveSection? section) {
    if (section == null) {
      s.setSpeedLimitDisplay(s.speedLimitDisplay == SpeedLimitDisplay.off ? SpeedLimitDisplay.auto : SpeedLimitDisplay.off);
    } else {
      s.setShows(section, !s.shows(section));
    }
  }

  String _sectionName(DriveSection? section) => switch (section) {
        null => 'Speed limit sign',
        DriveSection.turnBanner => 'Turn banner',
        DriveSection.miniMap => 'Mini map',
        final x => driveSectionLabel(x),
      };

  Widget _drivingView() {
    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < 1100 * u;
      final picture = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        DrivingViewPicture(settings: s, unit: u, onToggle: _toggle, shown: _shown),
        SizedBox(height: 10 * u),
        Text('Tap a part of the screen to hide or show it', style: TextStyle(color: _label, fontSize: 19 * u)),
        SizedBox(height: 16 * u),
        _cardBox('SPEED LIMIT SIGN', [
          _choices<SpeedLimitDisplay>('speedLimit', SpeedLimitDisplay.values, s.speedLimitDisplay, speedLimitDisplayLabel, s.setSpeedLimitDisplay),
        ], sub: 'Auto shows it once the comma has a limit'),
      ]);
      final list = _cardBox(null, [
        for (final (title, sections) in drivingViewGroups) ...[
          _groupLabel(title),
          for (final section in sections) _switchRow(_sectionName(section), _shown(section), () => _toggle(section), key: 'section_${section?.name ?? 'speedLimit'}'),
          SizedBox(height: 6 * u),
        ],
      ]);
      if (narrow) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [picture, SizedBox(height: 20 * u), list]);
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 820 * u, child: picture),
        SizedBox(width: 26 * u),
        Expanded(child: list),
      ]);
    });
  }

  // -- Display --

  Widget _display() => _columns([
        _cardBox('BRIGHTNESS', [_brightness()], sub: 'Auto follows the head unit. Set here, it applies while OPRivView is open'),
        _cardBox('CLOCK', [
          _choices<ClockMode>('clock', const [ClockMode.h12, ClockMode.h24], s.clockMode == ClockMode.h24 ? ClockMode.h24 : ClockMode.h12,
              (m) => m == ClockMode.h24 ? '24 h' : '12 h', s.setClockMode),
        ], sub: 'In the status bar'),
        _cardBox('KEEP THE SCREEN ON', [
          _switchRow('While connected to the comma', s.keepScreenOn, () => s.setKeepScreenOn(!s.keepScreenOn), key: 'keepScreenOn'),
        ], sub: 'Off lets the head unit dim and sleep as usual'),
      ]);

  Widget _brightness() {
    final auto = s.brightness == null;
    final value = s.brightness ?? s.manualBrightness;
    return Row(children: [
      Icon(Icons.wb_sunny_outlined, size: 24 * u, color: Colors.white54),
      Expanded(
        child: Opacity(
          opacity: auto ? 0.4 : 1,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 8 * u,
              activeTrackColor: Colors.white,
              inactiveTrackColor: const Color(0xFF3A3B3D),
              thumbColor: Colors.white,
              overlayShape: SliderComponentShape.noOverlay,
              thumbShape: RoundSliderThumbShape(enabledThumbRadius: 15 * u),
            ),
            child: Slider(
              key: const ValueKey('brightnessSlider'),
              value: value,
              min: minBrightness,
              max: 1,
              onChanged: (v) => s.setBrightness(v),  // moving it takes brightness off Auto
            ),
          ),
        ),
      ),
      SizedBox(
        width: 70 * u,
        child: Text('${(value * 100).round()}%',
            textAlign: TextAlign.right, style: TextStyle(color: Colors.white.withValues(alpha: auto ? 0.4 : 1), fontSize: 22 * u, fontWeight: FontWeight.bold)),
      ),
      SizedBox(width: 14 * u),
      _button('Auto', () => s.setBrightness(auto ? s.manualBrightness : null), primary: auto, key: 'brightnessAuto'),
    ]);
  }

  // -- Recording --

  Widget _recording() {
    final r = widget.recorder;
    final clips = _clips;
    final bytes = (clips ?? const <Clip>[]).fold<int>(0, (a, c) => a + c.bytes);
    final unstarred = (clips ?? const <Clip>[]).where((c) => !c.starred).toList();
    final String state = r == null
        ? 'not available'
        : switch (r.state) {
            RecordState.recording => 'recording a clip',
            RecordState.buffering => 'keeping the last ${recordBufferLabel(s.recordBufferSeconds)}',
            RecordState.off => r.declined ? 'not allowed this launch' : 'off',
          };
    return _columns([
      _cardBox('KEEP THE LAST', [
        _choices<int>('recordBuffer', recordBufferChoices, s.recordBufferSeconds, recordBufferLabel, s.setRecordBufferSeconds),
      ], sub: 'Saved with the clip when you tap Record. Off records only from the tap'),
      _cardBox('STORAGE LIMIT', [
        _choices<int>('storageLimit', storageLimitChoices, s.storageLimitGb, (gb) => '$gb GB', s.setStorageLimitGb),
      ], sub: 'Over it the oldest unstarred clips are removed; starred clips are kept'),
      _cardBox('ON THE HEAD UNIT', [
        _valueRow('Clips', clips == null ? '…' : '${clips.length} · ${formatBytes(bytes)}', key: 'recordingClips'),
        _valueRow('Screen recording', state, color: r == null || r.state == RecordState.off ? _value : _green),
      ]),
      _cardBox('CLIPS', [
        _valueRow('Clips stop at', formatRecordingTime(maxClipLength)),
        _row('Delete all unstarred clips',
            _button('Delete…', unstarred.isEmpty ? null : () => _deleteUnstarred(unstarred), key: 'deleteUnstarred'),
            sub: clips == null ? null : '${unstarred.length} of ${clips.length}'),
      ]),
    ]);
  }

  Future<void> _deleteUnstarred(List<Clip> clips) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16171A),
        title: Text('Delete ${clips.length} unstarred ${clips.length == 1 ? 'clip' : 'clips'}?'),
        content: const Text('Starred clips are kept.'),
        actions: [
          TextButton(key: const ValueKey('deleteUnstarredCancel'), onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('deleteUnstarredConfirm'),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC92231)),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final r = widget.recorder;
    final store = await r?.store();
    if (store == null) return;
    for (final c in clips) {
      await store.delete(c);
    }
    r!.clipsVersion++;
    await _loadClips();
  }

  // -- Navigation --

  Widget _navigation() {
    final dest = st.navDestination;
    Place? named;
    if (dest != null) {
      final probe = Place(name: '', address: '', lat: dest.$1, lon: dest.$2);
      for (final p in [if (s.navHome != null) s.navHome!, if (s.navWork != null) s.navWork!, ...s.navRecents]) {
        if (p.sameSpot(probe)) {
          named = p;
          break;
        }
      }
    }
    final navOn = st.navigationEnabled;
    final key = s.mapTilerKey;
    return _columns([
      _cardBox('MAPTILER KEY', [
        Row(children: [
          Container(
            width: 14 * u,
            height: 14 * u,
            decoration: BoxDecoration(color: key == null ? _amber : _green, shape: BoxShape.circle),
          ),
          SizedBox(width: 12 * u),
          Expanded(
            child: Text(key == null ? 'Not set: the map and search are off' : 'Your key ··· ${key.length > 4 ? key.substring(key.length - 4) : key}',
                key: const ValueKey('mapKeyStatus'),
                maxLines: 2,
                style: TextStyle(color: Colors.white, fontSize: 24 * u, fontWeight: FontWeight.bold)),
          ),
          SizedBox(width: 12 * u),
          if (key == null)
            _button('Add key…', _editMapKey, primary: true, key: 'mapKeyAdd')
          else ...[
            _button('Change…', _editMapKey, key: 'mapKeyChange'),
            SizedBox(width: 10 * u),
            _button('Remove', () => s.setMapTilerKey(null), key: 'mapKeyRemove'),
          ],
        ]),
      ], sub: mapTilerKeyHelp),
      _cardBox('ON THE COMMA', [
        _valueRow('Navigation', navOn == null ? '–' : (navOn ? 'on' : 'off: turn it on on the comma'),
            color: navOn == true ? _green : (navOn == false ? _amber : _value), sub: 'The comma plans the route (needs prime and a GPS fix)'),
        _valueRow('GPS', !st.gpsSeen ? '–' : (st.gpsFix ? 'fix · ±${st.gpsAccuracy.round()} m' : 'no fix'), color: st.gpsFix ? _green : _value),
        _valueRow('Route', dest == null ? 'none' : 'to ${named?.name ?? '${dest.$1.toStringAsFixed(4)}, ${dest.$2.toStringAsFixed(4)}'}'),
      ]),
      _cardBox('SAVED PLACES', [
        _placeRow('Home', s.navHome, () => s.setNavHome(null), 'clearHome'),
        _placeRow('Work', s.navWork, () => s.setNavWork(null), 'clearWork'),
      ], sub: 'Save them from a destination\'s card in Navigate'),
      _cardBox('RECENT PLACES', [
        if (s.navRecents.isEmpty) Text('None yet', style: TextStyle(color: _label, fontSize: 21 * u)),
        for (final p in s.navRecents) _row(p.name, const SizedBox.shrink(), sub: p.address),
        _row('Clear recent places', _button('Clear', s.navRecents.isEmpty ? null : s.clearNavRecents, key: 'clearRecents')),
      ]),
      _cardBox('MAP', [
        _choices<MapStyle>('mapStyle', MapStyle.values, s.mapStyle, mapStyleLabel, s.setMapStyle),
        _valueRow('Map data', '© MapTiler © OpenStreetMap'),
      ], sub: 'Navigate\'s map and the mini map while driving'),
    ]);
  }

  /// asks for a MapTiler key, tries it, and saves it once it works
  Future<void> _editMapKey() async {
    final field = TextEditingController();
    final check = widget.checkMapKey;
    http.Client? client;
    String? error;
    var checking = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, setDialog) {
        Future<void> save() async {
          setDialog(() {
            checking = true;
            error = null;
          });
          final k = field.text.trim();
          final why = check != null ? await check(k) : await checkMapTilerKey(client ??= http.Client(), k);
          if (!dialogContext.mounted) return;
          if (why == null) {
            await s.setMapTilerKey(k);
            if (dialogContext.mounted) Navigator.of(dialogContext).pop();
          } else {
            setDialog(() {
              checking = false;
              error = why;
            });
          }
        }

        Future<void> paste() async {
          final clip = await Clipboard.getData(Clipboard.kTextPlain);
          final t = clip?.text?.trim();
          if (t != null && t.isNotEmpty) setDialog(() => field.text = t);
        }

        return AlertDialog(
          key: const ValueKey('mapKeyDialog'),
          backgroundColor: const Color(0xFF16171A),
          title: const Text('MapTiler key'),
          content: SizedBox(
            width: 640,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text(mapTilerKeyHelp, style: TextStyle(color: _label)),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('mapKeyField'),
                    controller: field,
                    autofocus: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    onSubmitted: (_) => checking ? null : save(),
                    decoration: const InputDecoration(hintText: 'Paste your key'),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(key: const ValueKey('mapKeyPaste'), onPressed: paste, child: const Text('Paste')),
              ]),
              if (checking) ...[
                const SizedBox(height: 14),
                const Text('Trying the key with MapTiler…', style: TextStyle(color: _label)),
              ],
              if (error != null) ...[
                const SizedBox(height: 14),
                Text(error!, key: const ValueKey('mapKeyError'), style: const TextStyle(color: Color(0xFFFF6B6B))),
              ],
            ]),
          ),
          actions: [
            TextButton(key: const ValueKey('mapKeyCancel'), onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
            FilledButton(key: const ValueKey('mapKeySave'), onPressed: checking ? null : save, child: const Text('Test & save')),
          ],
        );
      }),
    );
    client?.close();
    // the controller is left to go with the dialog: it is still drawn while the dialog fades out
  }

  Widget _placeRow(String label, Place? p, VoidCallback clear, String key) =>
      _row(label, p == null ? _valueText('Not set') : _button('Clear', clear, key: key), sub: p == null ? null : (p.address.isEmpty ? p.name : p.address));

  // -- Comma device --

  Widget _comma() {
    final address = widget.host;
    final lane = st.laneGuardSeen ? (st.laneGuardEnabled ? 'on' : 'off') : '–';
    final nav = st.navigationEnabled == null ? '–' : (st.navigationEnabled! ? 'on' : 'off');
    return _columns([
      _cardBox('CONNECTION', [
        Row(children: [
          Container(
            width: 14 * u,
            height: 14 * u,
            decoration: BoxDecoration(color: st.isConnected ? _green : const Color(0xFF6E6E6E), shape: BoxShape.circle),
          ),
          SizedBox(width: 12 * u),
          Expanded(
            child: Text(st.isConnected ? 'Connected' : 'Not connected',
                style: TextStyle(color: Colors.white, fontSize: 26 * u, fontWeight: FontWeight.bold)),
          ),
          if (widget.onChangeHost != null) _button('Change', widget.onChangeHost, key: 'changeHost'),
        ]),
        Text(address ?? 'Not found yet', key: const ValueKey('commaAddress'), style: TextStyle(color: _value, fontSize: 22 * u)),
        Text(address == null ? 'searching the network' : (widget.hostIsManual ? 'entered by hand' : 'found automatically'),
            style: TextStyle(color: _label, fontSize: 19 * u)),
      ]),
      _cardBox('ON THE COMMA', [
        _valueRow('Lane guard', lane, color: lane == 'on' ? _green : _value),
        _valueRow('Navigation', nav, color: nav == 'on' ? _green : _value),
        _valueRow('Units', st.paramsSeen ? (st.isMetric ? 'kilometres' : 'miles') : '–'),
        if (st.brand.isNotEmpty) _valueRow('Car', st.brand),
      ], sub: 'Read from the comma; change them there'),
      _cardBox('CAMERA', [
        _choices<CameraMode>('camera', CameraMode.values, s.cameraMode, cameraModeLabel, s.setCameraMode),
      ], sub: 'Auto switches to the wide camera at low speed while openpilot controls speed, as the comma does; '
          'each switch briefly restarts the video. Road and Wide never switch'),
      _cardBox('TROUBLESHOOTING', [
        _row('Reconnect now', _button('Reconnect', widget.onReconnect, key: 'reconnect'), sub: 'Restarts the stream from the comma'),
      ]),
    ]);
  }

  // -- Updates & about --

  Widget _about() => _columns([
        _cardBox('UPDATE', [_updateCard()]),
        _cardBox('ABOUT', [
          _valueRow('Version', widget.updater.installed),
          _valueRow('Source', 'gerrylum/opview'),
          _row('Licences', _button('View', () => showLicensePage(context: context, applicationName: 'OPRivView'), key: 'licences')),
          _valueRow('Map data', '© MapTiler © OpenStreetMap'),
        ]),
      ]);

  Widget _updateCard() {
    final up = widget.updater;
    final release = up.latest;
    String title;
    String sub;
    Widget action;
    Color dot = const Color(0xFF6E6E6E);
    switch (up.status) {
      case UpdateStatus.idle:
        title = up.installed;
        sub = 'Installed';
        action = _button('Check', up.check, key: 'updateCheck');
      case UpdateStatus.checking:
        title = up.installed;
        sub = 'Checking GitHub…';
        action = _button('Check', null);
      case UpdateStatus.upToDate:
        title = up.installed;
        sub = 'Up to date';
        dot = _green;
        action = _button('Check', up.check, key: 'updateCheck');
      case UpdateStatus.available:
      case UpdateStatus.installing:
        title = '${release?.version ?? 'Update'} available';
        sub = up.message.isNotEmpty ? up.message : 'Installed ${up.installed}. Android asks you to confirm the install';
        dot = _amber;
        action = _button('Update', up.status == UpdateStatus.installing ? null : up.downloadAndInstall, primary: true, key: 'updateInstall');
      case UpdateStatus.downloading:
        String mb(int b) => (b / 1048576).toStringAsFixed(1);
        title = 'Downloading update';
        sub = up.total > 0 ? '${mb(up.received)} of ${mb(up.total)} MB' : '${mb(up.received)} MB';
        action = _button('Cancel', up.cancel, key: 'updateCancel');
      case UpdateStatus.failed:
        title = up.installed;
        sub = up.message;
        action = _button('Retry', up.check, key: 'updateCheck');
    }
    final notes = (up.status == UpdateStatus.available && release != null) ? releaseNoteLines(release.notes) : const <String>[];
    final frac = up.total > 0 ? (up.received / up.total).clamp(0.0, 1.0).toDouble() : 0.0;
    return Column(key: const ValueKey('updatesRow'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Container(width: 14 * u, height: 14 * u, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
        SizedBox(width: 12 * u),
        Expanded(
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: 26 * u, fontWeight: FontWeight.bold)),
        ),
        SizedBox(width: 12 * u),
        action,
      ]),
      if (up.status == UpdateStatus.downloading) ...[
        SizedBox(height: 10 * u),
        ClipRRect(
          borderRadius: BorderRadius.circular(4 * u),
          child: SizedBox(
            height: 8 * u,
            child: Container(
              color: const Color(0xFF3A3B3D),
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(widthFactor: frac, heightFactor: 1, child: const ColoredBox(color: Colors.white)),
            ),
          ),
        ),
      ],
      SizedBox(height: 8 * u),
      Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: _label, fontSize: 19 * u)),
      for (final line in notes)
        Padding(
          padding: EdgeInsets.only(top: 6 * u),
          child: Text('• $line', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: const Color(0xFFD0D0D0), fontSize: 21 * u)),
        ),
    ]);
  }

  // -- pieces --

  /// cards in two columns, or one on a narrow screen
  Widget _columns(List<Widget> cards) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 900 * u) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final card in cards) Padding(padding: EdgeInsets.only(bottom: 20 * u), child: card),
        ]);
      }
      Widget col(int start) => Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = start; i < cards.length; i += 2) Padding(padding: EdgeInsets.only(bottom: 20 * u), child: cards[i]),
            ]),
          );
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [col(0), SizedBox(width: 20 * u), col(1)]);
    });
  }

  Widget _cardBox(String? title, List<Widget> children, {String? sub}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 24 * u, vertical: 20 * u),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(20 * u)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null) _groupLabel(title),
        if (sub != null) ...[
          Text(sub, style: TextStyle(color: _label, fontSize: 18 * u, height: 1.3)),
          SizedBox(height: 12 * u),
        ] else if (title != null)
          SizedBox(height: 6 * u),
        ...children,
      ]),
    );
  }

  Widget _groupLabel(String text) => Padding(
        padding: EdgeInsets.only(bottom: 8 * u),
        child: Text(text, style: TextStyle(color: _label, fontSize: 19 * u, fontWeight: FontWeight.w700, letterSpacing: 1 * u)),
      );

  Widget _row(String label, Widget right, {String? sub}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 9 * u),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: 24 * u, fontWeight: FontWeight.w500)),
            if (sub != null) ...[
              SizedBox(height: 3 * u),
              Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: _label, fontSize: 18 * u)),
            ],
          ]),
        ),
        SizedBox(width: 14 * u),
        right,
      ]),
    );
  }

  Widget _valueText(String text, {Color color = _value, String? key}) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 360 * u),
        child: Text(text,
            key: key == null ? null : ValueKey(key),
            textAlign: TextAlign.right,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 22 * u)),
      );

  Widget _valueRow(String label, String value, {Color color = _value, String? sub, String? key}) =>
      _row(label, _valueText(value, color: color, key: key), sub: sub);

  Widget _switchRow(String label, bool on, VoidCallback onTap, {required String key}) {
    return InkWell(
      key: ValueKey(key),
      onTap: onTap,
      borderRadius: BorderRadius.circular(10 * u),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 7 * u),
        child: Row(children: [
          Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: 22 * u))),
          SizedBox(width: 12 * u),
          _switch(on),
        ]),
      ),
    );
  }

  Widget _switch(bool on) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 58 * u,
        height: 34 * u,
        padding: EdgeInsets.all(4 * u),
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        decoration: BoxDecoration(color: on ? _green : const Color(0xFF3A3B3D), borderRadius: BorderRadius.circular(17 * u)),
        child: Container(width: 26 * u, height: 26 * u, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
      );

  /// a row of choices; the current one is lit
  Widget _choices<T>(String group, List<T> values, T current, String Function(T) labelOf, void Function(T) onPick) {
    return Container(
      padding: EdgeInsets.all(5 * u),
      decoration: BoxDecoration(color: const Color(0xFF1C1D1F), borderRadius: BorderRadius.circular(14 * u)),
      child: Row(children: [
        for (final v in values)
          Expanded(
            child: InkWell(
              key: ValueKey('choice_${group}_${labelOf(v)}'),
              onTap: () => onPick(v),
              borderRadius: BorderRadius.circular(10 * u),
              child: Container(
                padding: EdgeInsets.symmetric(vertical: 12 * u),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: v == current ? const Color(0xFF3A3D42) : null, borderRadius: BorderRadius.circular(10 * u)),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(labelOf(v),
                      maxLines: 1,
                      style: TextStyle(color: v == current ? Colors.white : const Color(0xFF9A9A9A), fontSize: 23 * u, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _button(String text, VoidCallback? onTap, {bool primary = false, String? key}) {
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: Material(
        color: primary ? _blue : const Color(0xFF2E3034),
        borderRadius: BorderRadius.circular(12 * u),
        child: InkWell(
          key: key == null ? null : ValueKey(key),
          onTap: onTap,
          borderRadius: BorderRadius.circular(12 * u),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 22 * u, vertical: 11 * u),
            child: Text(text, style: TextStyle(color: Colors.white, fontSize: 22 * u, fontWeight: FontWeight.bold, height: 1.0)),
          ),
        ),
      ),
    );
  }
}

/// a drawing of the driving screen with each part outlined: tap one to hide or show it
class DrivingViewPicture extends StatelessWidget {
  final AppSettings settings;
  final double unit;
  final void Function(DriveSection?) onToggle;
  final bool Function(DriveSection?) shown;

  const DrivingViewPicture({super.key, required this.settings, required this.unit, required this.onToggle, required this.shown});

  /// where each part sits on an 820x463 picture (the camera area and status bar, as in the mockup)
  static const parts = <(DriveSection?, String, Rect)>[
    (DriveSection.speed, 'Speed', Rect.fromLTWH(164, 37, 302, 79)),
    (null, 'Limit', Rect.fromLTWH(480, 37, 176, 79)),
    (DriveSection.roadName, 'Road name', Rect.fromLTWH(318, 5, 184, 26)),
    (DriveSection.driver, 'Driver', Rect.fromLTWH(681, 21, 56, 56)),
    (DriveSection.confidence, 'Ball', Rect.fromLTWH(743, 21, 56, 56)),
    (DriveSection.steering, 'Steering', Rect.fromLTWH(21, 326, 112, 78)),
    (DriveSection.lead, 'Lead', Rect.fromLTWH(688, 326, 112, 78)),
    (DriveSection.torque, 'Torque bar', Rect.fromLTWH(232, 354, 358, 56)),
    (DriveSection.statusBar, 'Status bar', Rect.fromLTWH(4, 424, 812, 37)),
  ];

  @override
  Widget build(BuildContext context) {
    final u = unit;
    return Container(
      key: const ValueKey('drivingViewPicture'),
      width: 820 * u,
      height: 463 * u,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16 * u),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF3B4A55), Color(0xFF2C3B2C), Color(0xFF26282A)],
          stops: [0, 0.45, 0.9],
        ),
      ),
      clipBehavior: ui.Clip.antiAlias,  // Clip alone is the recorder's clip here
      child: Stack(children: [
        // the road and the camera area's border
        Positioned.fill(child: CustomPaint(painter: _RoadPainter(unit: u))),
        for (final (section, label, r) in parts)
          Positioned(
            left: r.left * u,
            top: r.top * u,
            width: r.width * u,
            height: r.height * u,
            child: _part(section, label, shown(section)),
          ),
      ]),
    );
  }

  Widget _part(DriveSection? section, String label, bool on) {
    final u = unit;
    return Material(
      color: on ? const Color(0x2E3D8BFF) : const Color(0x8C000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10 * u),
        side: BorderSide(color: on ? _blue : const Color(0xFF8C8C8C), width: 2.5 * u),
      ),
      child: InkWell(
        key: ValueKey('preview_${section?.name ?? 'speedLimit'}'),
        borderRadius: BorderRadius.circular(10 * u),
        onTap: () => onToggle(section),
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(3 * u),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(on ? label : '✕ $label',
                  style: TextStyle(color: on ? Colors.white : const Color(0xFFBFBFBF), fontSize: 16 * u, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoadPainter extends CustomPainter {
  final double unit;
  const _RoadPainter({required this.unit});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height * 0.915;  // above the status bar
    final road = Path()
      ..moveTo(w * 0.47, h * 0.42)
      ..lineTo(w * 0.53, h * 0.42)
      ..lineTo(w * 0.86, h)
      ..lineTo(w * 0.14, h)
      ..close();
    canvas.drawPath(road, Paint()..color = const Color(0xFF55585B));
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(2 * unit, 2 * unit, w - 4 * unit, h - 2 * unit), Radius.circular(14 * unit)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4 * unit
        ..color = const Color(0xFF17C653),
    );
    canvas.drawRect(Rect.fromLTWH(0, h, w, size.height - h), Paint()..color = const Color(0xFF0E0F10));
  }

  @override
  bool shouldRepaint(_RoadPainter old) => old.unit != unit;
}
