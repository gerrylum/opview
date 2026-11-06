// the app's one screen: the menu column on the left, the camera view (augmented road
// view) in the middle, and the status bar along the bottom under it
//
// laid out from the redesign mockup, a 1920x1000 screen; `unit` scales its pixels

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:opview/selfdrive/ui/gallery/clip_playback.dart';
import 'package:opview/selfdrive/ui/gallery/gallery_view.dart';
import 'package:opview/selfdrive/ui/navigate/navigate_view.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/settings/settings_page.dart';
import 'package:opview/selfdrive/ui/shell/menu_rail.dart';
import 'package:opview/selfdrive/ui/shell/status_bar.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/nav/shared_place.dart';
import 'package:opview/services/recorder/recorder.dart';
import 'package:opview/services/updater.dart';

const shellRefWidth = 1920.0;
const shellRefHeight = 1000.0;

/// mockup pixel size on a screen of [size]
double shellUnit(Size size) => min(size.width / shellRefWidth, size.height / shellRefHeight);

class AppShell extends StatefulWidget {
  final UIState uiState;
  final AppSettings settings;
  final RTCVideoRenderer? videoRenderer;
  final Future<String?> Function()? loadManualHost;
  final Future<void> Function(String? host)? onSetManualHost;
  final String? Function()? currentHost;

  /// Record and the Gallery; without it (tests of other parts) Record says it is unavailable
  final Recorder? recorder;

  /// plays a clip in the Gallery; replaceable in tests
  final ClipPlaybackFactory playback;

  /// Navigate: sends a destination to the comma (ConnectionManager.sendNavDestination);
  /// without it Navigate says it is unavailable
  final SendDestination? sendNavDestination;

  /// Navigate's search; MapTiler unless replaced (tests)
  final PlaceSearch? placeSearch;

  /// Navigate's map tiles (off in tests)
  final bool mapTiles;

  /// leaves the app; replaceable in tests
  final VoidCallback? onExit;

  /// Settings' Reconnect (ConnectionManager.reconnect)
  final VoidCallback? onReconnect;

  /// Settings' updates; the app's own unless replaced (tests)
  final Updater? updater;

  /// places shared from Google Maps (Share › OPRivView): each opens Navigate with it
  final SharedPlaces? sharedPlaces;

  /// reads a share; replaceable in tests (Google's links and MapTiler otherwise)
  final SharedPlaceResolver? resolveShared;

  const AppShell({
    super.key,
    required this.uiState,
    required this.settings,
    this.videoRenderer,
    this.loadManualHost,
    this.onSetManualHost,
    this.currentHost,
    this.recorder,
    this.playback = videoPlayerPlayback,
    this.sendNavDestination,
    this.placeSearch,
    this.mapTiles = true,
    this.onExit,
    this.onReconnect,
    this.updater,
    this.sharedPlaces,
    this.resolveShared,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

/// what Record shows on the rail now
RecordBadge? recordBadge(Recorder? r) {
  if (r == null) return null;
  if (r.recording) return RecordingBadge(r.clipLength, maxClipLength, paused: r.paused);
  if (r.showsSaved) return SavedBadge(r.savedLength ?? Duration.zero);
  if (r.state == RecordState.buffering) return BufferBadge(r.buffer);
  return null;
}

/// what is open over the camera area, if anything
enum ShellPage { gallery, navigate, settings }

/// how the paused clip names [page] (ScreenCapture's "Recording paused" card)
String shellPageLabel(ShellPage page) => switch (page) {
      ShellPage.gallery => 'Gallery',
      ShellPage.navigate => 'Navigate',
      ShellPage.settings => 'Settings',
    };

class _AppShellState extends State<AppShell> {
  ShellPage? _page;
  bool _hostIsManual = false;
  SettingsCategory _settingsAt = SettingsCategory.drivingView;

  // the latest share for Navigate, until it takes it; the count tells one share from the next
  String? _shareText;
  int _shareId = 0;
  bool _wasConnected = false;
  bool _explaining = false;

  UIState get uiState => widget.uiState;
  AppSettings get settings => widget.settings;
  Recorder? get recorder => widget.recorder;

  @override
  void initState() {
    super.initState();
    uiState.addListener(_onUiState);
    _onUiState();  // already connected
    widget.sharedPlaces?.addListener(_onShared);
    // one that arrived before this screen was built (starting up, or in picture-in-picture)
    WidgetsBinding.instance.addPostFrameCallback((_) => _onShared());
  }

  @override
  void didUpdateWidget(AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uiState != uiState) {
      oldWidget.uiState.removeListener(_onUiState);
      uiState.addListener(_onUiState);
    }
    if (oldWidget.sharedPlaces != widget.sharedPlaces) {
      oldWidget.sharedPlaces?.removeListener(_onShared);
      widget.sharedPlaces?.addListener(_onShared);
    }
  }

  @override
  void dispose() {
    uiState.removeListener(_onUiState);
    widget.sharedPlaces?.removeListener(_onShared);
    super.dispose();
  }

  // connected: start keeping the buffer (the first time ever, after the explainer)
  void _onUiState() {
    final connected = uiState.isConnected;
    if (connected && !_wasConnected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startBuffer());
    }
    _wasConnected = connected;
  }

  /// a place shared from Google Maps: Navigate opens and takes it
  void _onShared() {
    if (!mounted) return;
    final text = widget.sharedPlaces?.take();
    if (text == null) return;
    if (widget.sendNavDestination == null) {
      _note('Navigate is not available');
      return;
    }
    setState(() {
      _shareText = text;
      _shareId++;
    });
    _show(ShellPage.navigate);
  }

  Future<void> _startBuffer() async {
    final r = recorder;
    if (r == null || !mounted || settings.recordBufferSeconds == 0 || r.declined) return;
    if (!await _explained()) {
      r.declined = true;
      return;
    }
    await r.startBuffer();
  }

  /// the explainer before Android's own prompt, once; false for Not now
  Future<bool> _explained() async {
    if (settings.recordExplained) return true;
    if (_explaining || !mounted) return false;
    _explaining = true;
    final ok = await showRecordExplainer(context, bufferSeconds: settings.recordBufferSeconds);
    _explaining = false;
    if (ok) await settings.setRecordExplained(true);
    return ok;
  }

  Future<void> _record() async {
    final r = recorder;
    if (r == null) {
      _note('Recording is not available');
      return;
    }
    _show(null);  // Record shows the camera, which is what it records
    if (!r.recording && !await _explained()) return;
    await r.toggle();
    final error = r.lastError;
    if (error != null && mounted) {
      r.lastError = null;
      _note(error);
    }
  }

  /// opens [page] over the camera area (one at a time), or closes it with null; a clip being
  /// recorded meanwhile shows the last camera frame with "Recording paused"
  void _show(ShellPage? page) {
    if (page == _page) return;
    setState(() => _page = page);
    recorder?.setCoveredBy(page == null ? null : shellPageLabel(page));
  }

  void _toggle(ShellPage page) => _show(_page == page ? null : page);

  Future<void> _openSettings({SettingsCategory at = SettingsCategory.drivingView}) async {
    _settingsAt = at;
    // whether the comma's address was typed in, for the Comma device page
    final manual = await widget.loadManualHost?.call();
    if (!mounted) return;
    _hostIsManual = manual != null;
    _show(ShellPage.settings);
  }

  Future<void> _changeHost() async {
    final set = widget.onSetManualHost;
    if (set == null) return;
    await askForDeviceIp(context, loadManualHost: widget.loadManualHost, onSetManualHost: set);
    final manual = await widget.loadManualHost?.call();
    if (mounted) setState(() => _hostIsManual = manual != null);
  }

  void _note(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final r = recorder;
    // the rail's Record note and the Gallery follow the recorder
    return r == null ? _screen(context) : ListenableBuilder(listenable: r, builder: (context, _) => _screen(context));
  }

  Widget _screen(BuildContext context) {
    final r = recorder;
    return Scaffold(
      backgroundColor: Colors.black,
      // the keyboard covers the bottom of the screen rather than shrinking it: the app is sized
      // to the screen (shellUnit), so a shorter body would draw everything smaller. Navigate's
      // search makes room above the keyboard itself
      resizeToAvoidBottomInset: false,
      body: LayoutBuilder(builder: (context, constraints) {
        final unit = shellUnit(constraints.biggest);
        final railW = menuRailWidth * unit;
        // what Record captures: everything right of the menu (camera area and status bar)
        if (r != null) {
          final dpr = MediaQuery.of(context).devicePixelRatio;
          final crop = Rect.fromLTWH(railW * dpr, 0, (constraints.maxWidth - railW) * dpr, constraints.maxHeight * dpr);
          WidgetsBinding.instance.addPostFrameCallback((_) => r.setCrop(crop));
        }
        final active = switch (_page) {
          ShellPage.navigate => MenuItem.navigate,
          ShellPage.gallery => MenuItem.gallery,
          ShellPage.settings => MenuItem.settings,
          null => settings.detailsOpen ? MenuItem.details : null,
        };
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MenuRail(
                  unit: unit,
                  active: active,
                  record: recordBadge(r),
                  onSelect: (item) => _onMenu(context, item)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Stack(fit: StackFit.expand, children: [
                        // kept while a page is open, so the video does not restart
                        Offstage(
                          offstage: _page != null,
                          child: AugmentedRoadView(
                            uiState: uiState,
                            videoRenderer: widget.videoRenderer,
                            loadManualHost: widget.loadManualHost,
                            onSetManualHost: widget.onSetManualHost,
                            currentHost: widget.currentHost,
                            settings: settings,
                            details: settings.detailsOpen,
                            onOpenSettings: _openSettings,
                            mapTiles: widget.mapTiles,
                          ),
                        ),
                        if (_page == ShellPage.gallery && r != null) GalleryView(recorder: r, unit: unit, playback: widget.playback),
                        if (_page == ShellPage.navigate && widget.sendNavDestination != null)
                          NavigateView(
                            uiState: uiState,
                            settings: settings,
                            unit: unit,
                            send: widget.sendNavDestination!,
                            onClose: () => _show(null),
                            search: widget.placeSearch,
                            tiles: widget.mapTiles,
                            onAddKey: () => _openSettings(at: SettingsCategory.navigation),
                            sharedText: _shareText,
                            sharedId: _shareId,
                            onSharedTaken: () => _shareText = null,
                            resolveShared: widget.resolveShared,
                          ),
                        if (_page == ShellPage.settings)
                          SettingsPage(
                            key: ValueKey(_settingsAt),
                            initial: _settingsAt,
                            settings: settings,
                            uiState: uiState,
                            unit: unit,
                            updater: widget.updater ?? appUpdater,
                            recorder: r,
                            host: widget.currentHost?.call(),
                            hostIsManual: _hostIsManual,
                            onChangeHost: widget.onSetManualHost == null ? null : _changeHost,
                            onReconnect: widget.onReconnect,
                            build: opviewBuild,
                            onDone: () => _show(null),
                          ),
                      ]),
                    ),
                    if (settings.shows(DriveSection.statusBar))
                      StatusBar(uiState: uiState, clockMode: settings.clockMode, unit: unit),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  void _onMenu(BuildContext context, MenuItem item) {
    switch (item) {
      case MenuItem.settings:
        if (_page == ShellPage.settings) {
          _show(null);
        } else {
          _openSettings();
        }
      case MenuItem.exit:
        _confirmExit(context);
      case MenuItem.details:
        // a toggle: tap again to go back to the driving view
        if (_page != null) {
          _show(null);
          settings.setDetailsOpen(true);
        } else {
          settings.setDetailsOpen(!settings.detailsOpen);
        }
      case MenuItem.record:
        _record();
      case MenuItem.navigate:
        if (widget.sendNavDestination == null) {
          _note('Navigate is not available');
        } else {
          _toggle(ShellPage.navigate);
        }
      case MenuItem.gallery:
        if (recorder == null) {
          _note('Gallery is not available');
        } else {
          _toggle(ShellPage.gallery);
        }
    }
  }

  Future<void> _confirmExit(BuildContext context) async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16171A),
        title: const Text('Exit OPRivView?'),
        content: const Text('The stream from the comma stops. openpilot keeps driving on the comma as usual.'),
        actions: [
          TextButton(
            key: const ValueKey('exitCancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('exitConfirm'),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC92231)),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Exit'),
          ),
        ],
      ),
    );
    if (leave != true) return;
    final exit = widget.onExit;
    if (exit != null) {
      exit();
    } else {
      SystemNavigator.pop();
    }
  }
}

/// before Android's own screen-recording prompt, the first time: what Record does. True for Continue
Future<bool> showRecordExplainer(BuildContext context, {required int bufferSeconds}) async {
  final keep = bufferSeconds == 0
      ? 'It records from the moment you tap Record.'
      : 'It keeps the last ${recordBufferLabel(bufferSeconds).replaceAll('1 min', 'minute').replaceAll('2 min', '2 minutes')} ready, '
          'so tapping Record saves what just happened too.';
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('recordExplainer'),
      backgroundColor: const Color(0xFF16171A),
      title: const Row(children: [
        Icon(Icons.radio_button_checked, color: Color(0xFFFF4D4D)),
        SizedBox(width: 12),
        Flexible(child: Text("Record what's on screen")),
      ]),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('OPRivView records the camera view with everything drawn on it: path, speed, torque bar and '
            'alerts, plus the status bar.'),
        const SizedBox(height: 12),
        Text('$keep Clips stop at 5 minutes.'),
        const SizedBox(height: 12),
        const Text('Android asks once each time OPRivView starts, and shows its screen-recording icon while '
            'recording is ready. Nothing leaves the head unit unless you share it.',
            style: TextStyle(color: Color(0xFF8C8C8C))),
      ]),
      actions: [
        TextButton(key: const ValueKey('explainerNotNow'), onPressed: () => Navigator.of(context).pop(false), child: const Text('Not now')),
        FilledButton(key: const ValueKey('explainerContinue'), onPressed: () => Navigator.of(context).pop(true), child: const Text('Continue')),
      ],
    ),
  );
  return ok == true;
}
