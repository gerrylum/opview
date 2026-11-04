// a stand-in for the Android side of Record

import 'dart:async';
import 'dart:ui';

import 'package:opview/services/recorder/recorder_platform.dart';

class FakeRecorderPlatform implements RecorderPlatform {
  final String? dir;
  bool allow;
  final calls = <String>[];
  final _events = StreamController<RecorderEvent>.broadcast();
  bool capturing = false;
  bool paused = false;
  Duration buffer = Duration.zero;
  Rect? crop;
  Duration buffered = const Duration(seconds: 60);

  FakeRecorderPlatform({this.dir, this.allow = true});

  void emit(RecorderEvent e) => _events.add(e);

  @override
  Future<bool> start({required Duration buffer, required Rect crop}) async {
    calls.add('start');
    this.buffer = buffer;
    this.crop = crop;
    capturing = allow;
    return allow;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    capturing = false;
  }

  @override
  Future<void> setBuffer(Duration buffer) async {
    calls.add('setBuffer');
    this.buffer = buffer;
  }

  @override
  Future<void> setCrop(Rect crop) async {
    calls.add('setCrop');
    this.crop = crop;
  }

  @override
  Future<void> setPaused(bool paused) async {
    this.paused = paused;
  }

  @override
  Future<Duration?> startClip() async {
    calls.add('startClip');
    return capturing ? buffered : null;
  }

  @override
  Future<void> stopClip() async {
    calls.add('stopClip');
  }

  @override
  Future<String?> clipDir() async => dir;

  @override
  Future<void> share(String path) async {
    calls.add('share $path');
  }

  @override
  Stream<RecorderEvent> get events => _events.stream;
}
