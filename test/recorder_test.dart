// Record: the clips on disk, the recorder's states, and what happened during a clip

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/recorder/clip_store.dart';
import 'package:opview/services/recorder/recorder.dart';
import 'package:opview/services/recorder/recorder_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fake_recorder.dart';

const _crop = Rect.fromLTWH(150, 0, 1770, 1000);

Future<File> _video(Directory dir, int startMs, {int bytes = 1000}) async {
  final f = File('${dir.path}/$startMs.mp4');
  await f.writeAsBytes(List.filled(bytes, 0));
  return f;
}

void main() {
  late Directory dir;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('clips');
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('clip store', () {
    test('lists newest first, with what the sidecar says', () async {
      final store = ClipStore(dir);
      await _video(dir, 1000);
      final v = await _video(dir, 5000, bytes: 3000);
      await store.save(Clip(
        video: v,
        start: DateTime.fromMillisecondsSinceEpoch(5000),
        duration: const Duration(seconds: 134),
        buffered: const Duration(seconds: 60),
        starred: true,
        events: const [DriveEvent(Duration(seconds: 70), DriveEventKind.alert)],
      ));
      final clips = await store.list();
      expect(clips.map((c) => c.id), ['5000', '1000']);
      final c = clips.first;
      expect(c.duration, const Duration(seconds: 134));
      expect(c.buffered, const Duration(seconds: 60));
      expect(c.starred, isTrue);
      expect(c.hasAlert, isTrue);
      expect(c.bytes, 3000);
      // no sidecar: still listed, from its name
      expect(clips.last.start, DateTime.fromMillisecondsSinceEpoch(1000));
      expect(clips.last.starred, isFalse);
    });

    test('a broken sidecar still lists the clip', () async {
      final v = await _video(dir, 7000);
      await File(v.path.replaceAll('.mp4', '.json')).writeAsString('{not json');
      final clips = await ClipStore(dir).list();
      expect(clips.single.id, '7000');
    });

    test('star and delete', () async {
      final store = ClipStore(dir);
      final v = await _video(dir, 2000);
      await File(v.path.replaceAll('.mp4', '.jpg')).writeAsBytes([1, 2, 3]);
      var clip = (await store.list()).single;
      clip = await store.setStarred(clip, true);
      expect((await store.list()).single.starred, isTrue);
      expect(jsonDecode(await clip.meta.readAsString())['starred'], isTrue);
      await store.delete(clip);
      expect(await store.list(), isEmpty);
      expect(await dir.list().toList(), isEmpty);
    });

    test('over the limit the oldest unstarred clips go, starred ones stay', () {
      Clip c(int ms, int bytes, {bool starred = false}) => Clip(
            video: File('${dir.path}/$ms.mp4'),
            start: DateTime.fromMillisecondsSinceEpoch(ms),
            duration: Duration.zero,
            bytes: bytes,
            starred: starred,
          );
      final clips = [c(5, 100), c(4, 100), c(3, 100, starred: true), c(2, 100), c(1, 100)];  // newest first
      expect(clipsToRemove(clips, 500), isEmpty);
      expect(clipsToRemove(clips, 300).map((x) => x.id), ['1', '2']);
      expect(clipsToRemove(clips, 100).map((x) => x.id), ['1', '2', '4', '5']);  // the starred one is kept even so
    });

    test('sizes', () {
      expect(formatBytes(96 * 1024 * 1024), '96 MB');
      expect(formatBytes((1.6 * 1024 * 1024 * 1024).round()), '1.6 GB');
    });
  });

  group('what happened during a clip', () {
    test('engaging, disengaging and alerts are logged and timed from the clip start', () {
      var now = DateTime(2026, 11, 4, 17, 43);
      final log = DriveEventLog(clock: () => now);
      final st = UIState()
        ..isConnected = true
        ..status = UIStatus.disengaged;
      log.observe(st);
      final start = now;
      now = now.add(const Duration(seconds: 10));
      log.observe(st..status = UIStatus.engaged);
      now = now.add(const Duration(seconds: 20));
      log.observe(st
        ..alertText1 = 'TAKE CONTROL IMMEDIATELY'
        ..alertSize = 3
        ..alertStatus = 2);
      log.observe(st);  // the same alert again is not a new one
      now = now.add(const Duration(seconds: 5));
      log.observe(st
        ..alertSize = 0
        ..alertText1 = ''
        ..status = UIStatus.disengaged);
      expect(log.between(start, const Duration(minutes: 1)), const [
        DriveEvent(Duration(seconds: 10), DriveEventKind.engaged),
        DriveEvent(Duration(seconds: 30), DriveEventKind.alert),
        DriveEvent(Duration(seconds: 35), DriveEventKind.disengaged),
      ]);
      expect(log.between(start.add(const Duration(seconds: 20)), const Duration(seconds: 12)),
          const [DriveEvent(Duration(seconds: 10), DriveEventKind.alert)]);
    });
  });

  group('recorder', () {
    late FakeRecorderPlatform platform;
    late AppSettings settings;
    late UIState st;
    late DateTime now;
    Recorder make() => Recorder(platform: platform, settings: settings, uiState: st, clock: () => now);

    setUp(() {
      platform = FakeRecorderPlatform(dir: dir.path);
      settings = AppSettings();
      st = UIState()..isConnected = true;
      now = DateTime(2026, 11, 4, 17, 43);
    });

    test('the buffer starts once connected, with the crop and the chosen length', () async {
      final r = make();
      await r.startBuffer();
      expect(platform.calls, isEmpty);  // no crop yet
      r.setCrop(_crop);
      st.isConnected = false;
      await r.startBuffer();
      expect(platform.calls, isEmpty);
      st.isConnected = true;
      await r.startBuffer();
      expect(r.state, RecordState.buffering);
      expect(platform.buffer, const Duration(seconds: 60));
      expect(platform.crop, _crop);
    });

    test('refused: no buffer this launch, Record asks again', () async {
      platform.allow = false;
      final r = make()..setCrop(_crop);
      await r.startBuffer();
      expect(r.state, RecordState.off);
      expect(r.declined, isTrue);
      await r.startBuffer();
      expect(platform.calls.where((c) => c == 'start').length, 1);
      platform.allow = true;
      await r.toggle();
      expect(r.recording, isTrue);
    });

    test('Record: the clip includes the buffered minute, and stops on a second tap', () async {
      final r = make()..setCrop(_crop);
      await r.startBuffer();
      await r.toggle();
      expect(r.recording, isTrue);
      expect(r.clipStart, now.subtract(const Duration(seconds: 60)));
      expect(r.clipLength, const Duration(seconds: 60));
      now = now.add(const Duration(minutes: 10));
      expect(r.clipLength, maxClipLength);  // held at 5:00
      await r.toggle();
      expect(platform.calls.last, 'stopClip');
    });

    test('a saved clip gets its sidecar, the rail says Saved, the limit is kept', () async {
      settings.storageLimitGb = 5;
      final r = make()..setCrop(_crop);
      await r.startBuffer();
      await r.toggle();
      final start = now.subtract(const Duration(seconds: 60));
      st.status = UIStatus.disengaged;
      r.log.observe(st);
      now = now.add(const Duration(seconds: 20));
      st.status = UIStatus.engaged;
      r.log.observe(st);
      now = now.add(const Duration(seconds: 54));
      final v = await _video(dir, start.millisecondsSinceEpoch);
      final version = r.clipsVersion;
      platform.emit(ClipSavedEvent(SavedClip(v.path, start, const Duration(seconds: 134), const Duration(seconds: 60))));
      await Future<void>.delayed(const Duration(milliseconds: 300));  // the sidecar is written
      expect(r.recording, isFalse);
      expect(r.state, RecordState.buffering);
      expect(r.showsSaved, isTrue);
      expect(r.savedLength, const Duration(seconds: 134));
      expect(r.clipsVersion, version + 1);
      final clip = (await ClipStore(dir).list()).single;
      expect(clip.buffered, const Duration(seconds: 60));
      expect(clip.events, const [DriveEvent(Duration(seconds: 80), DriveEventKind.engaged)]);
      now = now.add(savedNoteFor);
      expect(r.showsSaved, isFalse);
      r.dispose();
    });

    test('with Keep the last off, the capture runs only for the clip', () async {
      settings.recordBufferSeconds = 0;
      final r = make()..setCrop(_crop);
      await r.startBuffer();
      expect(platform.calls, isEmpty);
      await r.toggle();
      expect(r.recording, isTrue);
      final v = await _video(dir, now.millisecondsSinceEpoch);
      platform.emit(ClipSavedEvent(SavedClip(v.path, now, const Duration(seconds: 30), Duration.zero)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(platform.calls.last, 'stop');
      expect(r.state, RecordState.off);
      r.dispose();
    });

    test('leaving the app stops a clip and pauses; the Gallery pauses', () async {
      final r = make()..setCrop(_crop);
      await r.startBuffer();
      await r.toggle();
      r.setForeground(false);
      expect(platform.calls.last, 'stopClip');
      expect(platform.paused, isTrue);
      r.setForeground(true);
      expect(platform.paused, isFalse);
      r.setCameraHidden(true);
      expect(platform.paused, isTrue);
    });

    test('changing Keep the last follows into the capture', () async {
      final r = make()..setCrop(_crop);
      await r.startBuffer();
      await settings.setRecordBufferSeconds(120);
      expect(platform.buffer, const Duration(seconds: 120));
      await settings.setRecordBufferSeconds(0);
      expect(platform.calls.last, 'stop');
      expect(r.state, RecordState.off);
      await settings.setRecordBufferSeconds(30);
      await pumpEventQueue();
      expect(r.state, RecordState.buffering);
      expect(platform.buffer, const Duration(seconds: 30));
    });

    test('stopped from Android\'s controls: off until Record is tapped', () async {
      final r = make()..setCrop(_crop);
      await r.startBuffer();
      platform.emit(CaptureEndedEvent());
      await pumpEventQueue();
      expect(r.state, RecordState.off);
      expect(r.declined, isTrue);
    });
  });

  group('settings', () {
    test('Keep the last and the storage limit are remembered, odd values fall back', () async {
      final a = AppSettings();
      await a.load();
      expect(a.recordBufferSeconds, 60);
      expect(a.storageLimitGb, 10);
      expect(a.recordExplained, isFalse);
      await a.setRecordBufferSeconds(120);
      await a.setStorageLimitGb(20);
      await a.setRecordExplained(true);
      final b = AppSettings();
      await b.load();
      expect([b.recordBufferSeconds, b.storageLimitGb, b.recordExplained], [120, 20, true]);
      SharedPreferences.setMockInitialValues({'record_buffer_s': 45, 'record_storage_gb': 7});
      final c = AppSettings();
      await c.load();
      expect([c.recordBufferSeconds, c.storageLimitGb], [60, 10]);
    });
  });
}
