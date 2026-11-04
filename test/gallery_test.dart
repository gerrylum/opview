// the Gallery and the clip player

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/gallery/clip_playback.dart';
import 'package:opview/selfdrive/ui/gallery/clip_player.dart';
import 'package:opview/selfdrive/ui/gallery/gallery_view.dart';
import 'package:opview/selfdrive/ui/shell/menu_rail.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/recorder/clip_store.dart';
import 'package:opview/services/recorder/recorder.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fake_recorder.dart';

class FakePlayback extends ChangeNotifier implements ClipPlayback {
  @override
  Duration position = Duration.zero;
  @override
  Duration duration = const Duration(seconds: 134);
  @override
  bool playing = false;
  @override
  bool ready = false;
  final seeks = <Duration>[];

  @override
  Future<void> init() async {
    ready = true;
    notifyListeners();
  }

  @override
  double get aspectRatio => 1770 / 1000;

  @override
  Future<void> play() async {
    playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> seekTo(Duration d) async {
    seeks.add(d);
    position = d;
    notifyListeners();
  }

  @override
  Widget view() => const ColoredBox(key: ValueKey('fakeVideo'), color: Colors.grey);

  @override
  Future<void> dispose() async => super.dispose();
}

/// let the (in-memory) clip store's futures finish
Future<void> _io(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump();
  }
}

void _screen(WidgetTester tester, double w, double h) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  test('clip dates', () {
    final now = DateTime(2026, 11, 4, 18, 0);
    expect(formatClipDate(DateTime(2026, 11, 4, 17, 43), now), 'Today 5:43 PM');
    expect(formatClipDate(DateTime(2026, 11, 3, 21, 15), now), 'Yesterday 9:15 PM');
    expect(formatClipDate(DateTime(2026, 10, 30, 7, 44), now), 'Oct 30 7:44 AM');
    expect(formatClipDate(DateTime(2026, 10, 30, 0, 5), now), 'Oct 30 12:05 AM');
    expect(formatClipDate(DateTime(2026, 10, 30, 12, 5), now), 'Oct 30 12:05 PM');
  });

  test('filters', () {
    final now = DateTime(2026, 11, 4);
    Clip c(int daysAgo, {bool alert = false, bool starred = false}) => Clip(
          video: File('/x/$daysAgo.mp4'),
          start: now.subtract(Duration(days: daysAgo)),
          duration: Duration.zero,
          starred: starred,
          events: alert ? const [DriveEvent(Duration.zero, DriveEventKind.alert)] : const [],
        );
    final clips = [c(0, alert: true), c(3, starred: true), c(10)];
    expect(filterClips(clips, ClipFilter.all, now).length, 3);
    expect(filterClips(clips, ClipFilter.week, now).length, 2);
    expect(filterClips(clips, ClipFilter.alerts, now).single.start, clips[0].start);
    expect(filterClips(clips, ClipFilter.starred, now).single.start, clips[1].start);
  });

  test('scrubber positions', () {
    const len = Duration(seconds: 100);
    expect(ScrubberPainter.xFor(Duration.zero, len, 500), 0);
    expect(ScrubberPainter.xFor(const Duration(seconds: 50), len, 500), 250);
    expect(ScrubberPainter.xFor(const Duration(seconds: 200), len, 500), 500);
    expect(ScrubberPainter.xFor(const Duration(seconds: 5), Duration.zero, 500), 0);
  });

  group('rail', () {
    for (final (badge, text) in [
      (const BufferBadge(Duration(seconds: 60)), 'last 1:00'),
      (const RecordingBadge(Duration(seconds: 134), Duration(minutes: 5)), '2:14'),
      (const SavedBadge(Duration(seconds: 134)), '✓ Saved'),
    ]) {
      testWidgets('Record shows $text', (tester) async {
        _screen(tester, 1920, 1000);
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: Row(children: [MenuRail(unit: 1, record: badge, onSelect: (_) {})])),
        ));
        expect(find.text(text), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('gallery', () {
    late FakeRecorderPlatform platform;
    late MemoryClipStore store;
    late Recorder recorder;
    late FakePlayback playback;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      platform = FakeRecorderPlatform(dir: '/memory');
      store = MemoryClipStore();
      recorder = Recorder(platform: platform, settings: AppSettings(), uiState: UIState(), store: store);
      playback = FakePlayback();
      final now = DateTime.now();
      for (final (i, alert, starred) in [(0, true, false), (1, false, true), (2, false, false)]) {
        final start = now.subtract(Duration(hours: i * 30));
        await store.save(Clip(
          video: File('/memory/${start.millisecondsSinceEpoch}.mp4'),
          start: start,
          duration: Duration(seconds: 60 + i * 30),
          buffered: const Duration(seconds: 60),
          starred: starred,
          events: alert ? const [DriveEvent(Duration(seconds: 70), DriveEventKind.alert)] : const [],
          bytes: 1000 * (i + 1),
        ));
      }
    });
    tearDown(() => recorder.dispose());

    Future<void> show(WidgetTester tester, {double w = 1770, double h = 916}) async {
      _screen(tester, w, h);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: GalleryView(recorder: recorder, unit: w / 1770, playback: (_) => playback)),
      ));
      // the clips are read from disk
      await _io(tester);
    }

    testWidgets('clips newest first, with alert, star, length and usage', (tester) async {
      await show(tester);
      expect(find.textContaining('3 clips'), findsOneWidget);
      final cards = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('clip_'));
      expect(cards, findsNWidgets(3));
      expect(find.text('ALERT'), findsOneWidget);
      expect(find.text('★'), findsOneWidget);
      expect(find.text('1:00'), findsOneWidget);
      expect(find.text('2:00'), findsOneWidget);
      expect(find.textContaining('of 10 GB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('filters', (tester) async {
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('galleryFilter_alerts')));
      await tester.pump();
      expect(find.text('ALERT'), findsOneWidget);
      expect(find.text('1:30'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('galleryFilter_starred')));
      await tester.pump();
      expect(find.text('1:30'), findsOneWidget);
      expect(find.text('1:00'), findsNothing);
    });

    testWidgets('select and delete', (tester) async {
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('gallerySelect')));
      await tester.pump();
      final first = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('clip_')).first;
      await tester.tap(first);
      await tester.pump();
      expect(find.text('Delete (1)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('galleryDeleteSelected')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('deleteConfirm')));
      await tester.pump();
      await _io(tester);
      await tester.pumpAndSettle();
      expect(store.clips.length, 2);
      expect(find.textContaining('2 clips'), findsOneWidget);
    });

    testWidgets('the player: plays, seeks on the scrubber, stars, shares, goes back', (tester) async {
      await show(tester);
      await tester.tap(find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('clip_')).first);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('clipPlayer')), findsOneWidget);
      expect(find.byKey(const ValueKey('fakeVideo')), findsOneWidget);
      expect(playback.playing, isTrue);
      // tap the middle of the scrubber
      await tester.tap(find.byKey(const ValueKey('clipScrubber')));
      expect(playback.seeks.single.inSeconds, closeTo(67, 2));
      await tester.tap(find.byKey(const ValueKey('clipShare')));
      expect(platform.calls.last, startsWith('share '));
      await tester.tap(find.byKey(const ValueKey('clipStar')));
      await _io(tester);
      expect(find.text('★ Starred'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('clipBack')));
      await tester.pump();
      expect(find.byKey(const ValueKey('galleryView')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lays out on the small head unit shapes', (tester) async {
      for (final (w, h) in const [(1770.0, 916.0), (1208.0, 440.0), (944.0, 555.0)]) {
        await show(tester, w: w, h: h);
        expect(tester.takeException(), isNull, reason: '${w}x$h');
      }
    });

    testWidgets('no clips yet', (tester) async {
      store.clips.clear();
      await show(tester);
      expect(find.byKey(const ValueKey('galleryEmpty')), findsOneWidget);
    });
  });
}
