// Record: keeps the last minute (or what Settings says) ready while connected, and makes a clip
// from it and what follows when Record is tapped, stopping at 5:00
// (design: claude/oprivview-record-gallery-design.md; the capture itself is ScreenCapture.kt)

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/recorder/clip_store.dart';
import 'package:opview/services/recorder/recorder_platform.dart';

/// clips stop by themselves at this length (ScreenCapture.kt MAX_CLIP_US)
const maxClipLength = Duration(minutes: 5);

/// how long the rail says Saved after a clip
const savedNoteFor = Duration(seconds: 4);

/// what happened while driving, kept long enough to cover any clip
class DriveEventLog {
  final DateTime Function() clock;
  final _events = <(DateTime, DriveEventKind)>[];
  bool? _engaged;
  String _alert = '';

  DriveEventLog({DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  void observe(UIState st) {
    final engaged = st.isConnected && st.status != UIStatus.disengaged;
    final now = clock();
    if (_engaged != null && engaged != _engaged) {
      _events.add((now, engaged ? DriveEventKind.engaged : DriveEventKind.disengaged));
    }
    _engaged = engaged;
    final alert = st.alertSize > 0 && st.alertStatus > 0 ? st.alertText1 : '';
    if (alert.isNotEmpty && alert != _alert) _events.add((now, DriveEventKind.alert));
    _alert = alert;
    final keepFrom = now.subtract(maxClipLength * 3);
    _events.removeWhere((e) => e.$1.isBefore(keepFrom));
  }

  /// the events inside a clip, timed from its start
  List<DriveEvent> between(DateTime start, Duration length) => [
        for (final (t, kind) in _events)
          if (!t.isBefore(start) && t.difference(start) <= length) DriveEvent(t.difference(start), kind),
      ];
}

enum RecordState { off, buffering, recording }

class Recorder extends ChangeNotifier {
  final RecorderPlatform platform;
  final AppSettings settings;
  final UIState uiState;
  final DateTime Function() clock;
  final DriveEventLog log;

  RecordState state = RecordState.off;

  /// when the running clip begins (including what was buffered)
  DateTime? clipStart;

  /// the last clip written, shown on the rail for [savedNoteFor]
  DateTime? savedAt;
  Duration? savedLength;

  /// the last thing that went wrong, for a note
  String? lastError;

  /// goes up each time the clips change, so the Gallery reloads
  int clipsVersion = 0;

  /// the user said Not now (or Android refused) this launch: no buffer until Record is tapped
  bool declined = false;

  ClipStore? _store;
  StreamSubscription<RecorderEvent>? _sub;
  Timer? _ticker;
  Rect? _crop;
  bool _foreground = true;
  bool _cameraHidden = false;
  bool _starting = false;
  int _bufferSeconds;

  /// [store] replaces the clips folder on the head unit (tests)
  Recorder({required this.platform, required this.settings, required this.uiState, DateTime Function()? clock, ClipStore? store})
      : _store = store,
        clock = clock ?? DateTime.now,
        log = DriveEventLog(clock: clock),
        _bufferSeconds = settings.recordBufferSeconds {
    _sub = platform.events.listen(_onEvent);
    uiState.addListener(_onUiState);
    settings.addListener(_onSettings);
  }

  bool get recording => state == RecordState.recording;
  Duration get buffer => Duration(seconds: settings.recordBufferSeconds);

  /// how long the running clip is so far, held at 5:00
  Duration get clipLength {
    final s = clipStart;
    if (s == null) return Duration.zero;
    final d = clock().difference(s);
    return d > maxClipLength ? maxClipLength : d;
  }

  /// the rail says Saved for a few seconds after a clip
  bool get showsSaved => savedAt != null && clock().difference(savedAt!) < savedNoteFor && !recording;

  Future<ClipStore?> store() async {
    final s = _store;
    if (s != null) return s;
    final dir = await platform.clipDir();
    if (dir == null) return null;
    return _store = ClipStore(Directory(dir));
  }

  // -- what the app tells it --

  /// the camera area and status bar, in physical pixels inside the app's window
  void setCrop(Rect crop) {
    if (crop == _crop) return;
    _crop = crop;
    if (state != RecordState.off) platform.setCrop(crop);
  }

  /// the app is in front (not in the background or a picture-in-picture window)
  void setForeground(bool value) {
    if (value == _foreground) return;
    _foreground = value;
    if (!value && recording) stopClip();
    _applyPause();
  }

  /// something covers the camera area (the Gallery): nothing new goes into the video meanwhile
  void setCameraHidden(bool value) {
    if (value == _cameraHidden) return;
    _cameraHidden = value;
    _applyPause();
  }

  void _applyPause() {
    if (state != RecordState.off) platform.setPaused(!_foreground || _cameraHidden);
  }

  /// start keeping the buffer (asks Android the first time this launch); call when connected
  Future<void> startBuffer() async {
    if (state != RecordState.off || declined || _starting || settings.recordBufferSeconds == 0) return;
    final crop = _crop;
    if (crop == null || !_foreground || !uiState.isConnected) return;
    await _startCapture(crop);
  }

  Future<bool> _startCapture(Rect crop) async {
    _starting = true;
    try {
      final ok = await platform.start(buffer: buffer, crop: crop);
      if (!ok) {
        declined = true;
        notifyListeners();
        return false;
      }
      state = RecordState.buffering;
      _applyPause();
      notifyListeners();
      return true;
    } finally {
      _starting = false;
    }
  }

  /// Record tapped: start a clip with what is buffered, or stop the one running
  Future<void> toggle() async {
    if (recording) return stopClip();
    final crop = _crop;
    if (crop == null || _starting) return;
    if (state == RecordState.off && !await _startCapture(crop)) return;
    final before = await platform.startClip();
    if (before == null) {
      lastError = 'Recording is not running';
      notifyListeners();
      return;
    }
    declined = false;
    clipStart = clock().subtract(before);
    state = RecordState.recording;
    _tick();
    notifyListeners();
  }

  Future<void> stopClip() async {
    if (!recording) return;
    await platform.stopClip();
  }

  // -- what the head unit tells it --

  Future<void> _onEvent(RecorderEvent e) async {
    switch (e) {
      case ClipSavedEvent(:final clip):
        await _saved(clip);
      case ClipFailedEvent(:final message):
        lastError = message;
        if (recording) _clipEnded();
        notifyListeners();
      case CaptureEndedEvent():
        state = RecordState.off;
        clipStart = null;
        declined = true;
        notifyListeners();
    }
  }

  Future<void> _saved(SavedClip saved) async {
    _clipEnded();
    savedAt = clock();
    savedLength = saved.duration;
    final s = await store();
    if (s != null) {
      final clip = Clip(
        video: File(saved.path),
        start: saved.start,
        duration: saved.duration,
        buffered: saved.buffered,
        events: log.between(saved.start, saved.duration),
      );
      await s.save(clip);
      await s.enforceLimit(settings.storageLimitGb * 1024 * 1024 * 1024);
    }
    clipsVersion++;
    // with no buffer the capture only ran for the clip
    if (settings.recordBufferSeconds == 0 && state != RecordState.off) {
      await platform.stop();
      state = RecordState.off;
    }
    _tick();
    notifyListeners();
  }

  void _clipEnded() {
    clipStart = null;
    if (state == RecordState.recording) state = RecordState.buffering;
  }

  // the rail's clock: once a second while recording or showing Saved
  void _tick() {
    _ticker?.cancel();
    if (!recording && !showsSaved) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
      if (!recording && !showsSaved) {
        _ticker?.cancel();
        _ticker = null;
      }
    });
  }

  void _onUiState() => log.observe(uiState);

  void _onSettings() {
    final s = settings.recordBufferSeconds;
    if (s == _bufferSeconds) return;
    _bufferSeconds = s;
    if (state == RecordState.off) {
      declined = false;
      startBuffer();
    } else if (s == 0 && !recording) {
      platform.stop();
      state = RecordState.off;
      notifyListeners();
    } else {
      platform.setBuffer(buffer);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    uiState.removeListener(_onUiState);
    settings.removeListener(_onSettings);
    super.dispose();
  }
}
