// playing a clip: video_player on the head unit, replaceable in tests

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

abstract class ClipPlayback implements Listenable {
  Future<void> init();
  Duration get position;
  Duration get duration;
  bool get playing;
  bool get ready;
  double get aspectRatio;
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration d);
  Widget view();
  Future<void> dispose();
}

typedef ClipPlaybackFactory = ClipPlayback Function(File video);

ClipPlayback videoPlayerPlayback(File video) => _VideoPlayerPlayback(VideoPlayerController.file(video));

class _VideoPlayerPlayback extends ChangeNotifier implements ClipPlayback {
  final VideoPlayerController c;
  _VideoPlayerPlayback(this.c) {
    c.addListener(notifyListeners);
  }

  @override
  Future<void> init() => c.initialize();

  @override
  Duration get position => c.value.position;

  @override
  Duration get duration => c.value.duration;

  @override
  bool get playing => c.value.isPlaying;

  @override
  bool get ready => c.value.isInitialized;

  @override
  double get aspectRatio => c.value.isInitialized ? c.value.aspectRatio : 16 / 9;

  @override
  Future<void> play() => c.play();

  @override
  Future<void> pause() => c.pause();

  @override
  Future<void> seekTo(Duration d) => c.seekTo(d);

  @override
  Widget view() => VideoPlayer(c);

  @override
  Future<void> dispose() async {
    c.removeListener(notifyListeners);
    await c.dispose();
    super.dispose();
  }
}
