// opview app shell
// dark theme, single screen, no navigation needed

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/shell/app_shell.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/connection_manager.dart';
import 'package:opview/services/recorder/recorder.dart';
import 'package:opview/services/recorder/recorder_platform.dart';
import 'package:opview/services/system_service.dart';

class OpviewApp extends StatefulWidget {
  const OpviewApp({super.key});

  @override
  State<OpviewApp> createState() => _OpviewAppState();
}

class _OpviewAppState extends State<OpviewApp> with WidgetsBindingObserver {
  late final UIState _uiState;
  late final ConnectionManager _connectionManager;
  final AppSettings _settings = AppSettings();
  late final Recorder _recorder;

  // the app went fully into the background (not just PiP or the notification shade)
  final _lifecycle = LifecycleReconnect();

  // picture-in-picture is offered on Home only while there is something to show
  bool? _pipOffered;

  void _applyCameraMode() => _connectionManager.cameraMode = _settings.cameraMode;

  void _updatePipOffer() {
    final want = _uiState.isConnected;
    if (want == _pipOffered) return;
    _pipOffered = want;
    setPipEnabled(want);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _uiState = UIState();
    _connectionManager = ConnectionManager(_uiState);
    _connectionManager.start();
    _settings.load();
    _recorder = Recorder(platform: MethodChannelRecorder(), settings: _settings, uiState: _uiState);
    // nothing new is recorded in a picture-in-picture window (it would be the whole screen)
    pipMode.addListener(_applyForeground);
    // the camera choice in the settings goes to the connection
    _settings.addListener(_applyCameraMode);
    listenForPip();
    _uiState.addListener(_updatePipOffer);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uiState.removeListener(_updatePipOffer);
    pipMode.removeListener(_applyForeground);
    _recorder.dispose();
    _settings.removeListener(_applyCameraMode);
    // async cleanup — best-effort, State.dispose() is sync
    _connectionManager.dispose();
    _uiState.dispose();
    _settings.dispose();
    super.dispose();
  }

  AppLifecycleState _appState = AppLifecycleState.resumed;

  void _applyForeground() =>
      _recorder.setForeground(_appState == AppLifecycleState.resumed && !pipMode.value);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // inactive (the notification shade, a dialog) still shows the app
    _appState = state == AppLifecycleState.inactive ? AppLifecycleState.resumed : state;
    _applyForeground();
    switch (_lifecycle.onChange(state)) {
      case LifecycleAction.reconnect:
        debugPrint('[opview] app resumed, reconnecting');
        _connectionManager.reconnect();
      case LifecycleAction.pause:
        debugPrint('[opview] app paused, stopping');
        _connectionManager.pause();
      case LifecycleAction.none:
        break;
    }
  }


  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OPRivView',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
      ),
      home: ListenableBuilder(
        listenable: Listenable.merge([_uiState, _settings, pipMode]),
        // the floating window shows the camera view alone; otherwise the full screen
        // with the menu column and status bar
        builder: (context, _) => pipMode.value
            ? AugmentedRoadView(
                uiState: _uiState,
                videoRenderer: _connectionManager.videoRenderer,
                settings: _settings,
                pip: true,
              )
            : AppShell(
                uiState: _uiState,
                settings: _settings,
                videoRenderer: _connectionManager.videoRenderer,
                loadManualHost: _connectionManager.loadManualHost,
                onSetManualHost: _connectionManager.setManualHost,
                currentHost: () => _connectionManager.host,
                recorder: _recorder,
                sendNavDestination: _connectionManager.sendNavDestination,
              ),
      ),
    );
  }
}

enum LifecycleAction { none, pause, reconnect }

/// when to stop and restart the stream. A picture-in-picture window, the
/// notification shade or a dialog only make the app inactive, and the stream
/// keeps playing through them; only a real trip to the background pauses it,
/// and only coming back from that reconnects
class LifecycleReconnect {
  bool _paused = false;

  LifecycleAction onChange(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !_paused) {
      _paused = true;
      return LifecycleAction.pause;
    }
    if (state == AppLifecycleState.resumed && _paused) {
      _paused = false;
      return LifecycleAction.reconnect;
    }
    return LifecycleAction.none;
  }
}
