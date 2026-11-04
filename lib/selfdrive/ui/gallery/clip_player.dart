// one clip: the video (overlay burned in), a scrubber with what happened during it, and
// Star, Share, Delete. Sizes are in the redesign mockup's pixels, scaled by `unit`

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/gallery/clip_playback.dart';
import 'package:opview/selfdrive/ui/gallery/gallery_view.dart' show formatClipDate, galleryButton;
import 'package:opview/selfdrive/ui/shell/menu_rail.dart' show formatRecordingTime;
import 'package:opview/services/recorder/clip_store.dart';

const scrubDisengaged = Color(0xFF6E6E6E);
const scrubAlert = Color(0xFFC92231);
const scrubEngaged = Color(0xFF17C653);
const _starColor = Color(0xFFFFC83D);

Color scrubColor(DriveEventKind k) => switch (k) {
      DriveEventKind.disengaged => scrubDisengaged,
      DriveEventKind.alert => scrubAlert,
      DriveEventKind.engaged => scrubEngaged,
    };

class ClipPlayer extends StatefulWidget {
  final Clip clip;
  final double unit;
  final ClipPlaybackFactory playback;
  final VoidCallback onBack;
  final ValueChanged<bool> onStar;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  const ClipPlayer({
    super.key,
    required this.clip,
    required this.unit,
    required this.playback,
    required this.onBack,
    required this.onStar,
    required this.onShare,
    required this.onDelete,
  });

  @override
  State<ClipPlayer> createState() => _ClipPlayerState();
}

class _ClipPlayerState extends State<ClipPlayer> {
  late ClipPlayback _p;
  String? _error;

  @override
  void initState() {
    super.initState();
    _p = widget.playback(widget.clip.video);
    _p.addListener(_changed);
    _p.init().then((_) {
      if (mounted) _p.play();
    }).catchError((Object e) {
      if (mounted) setState(() => _error = 'This clip can\'t be played');
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _p.removeListener(_changed);
    _p.dispose();
    super.dispose();
  }

  Duration get _length => _p.ready && _p.duration > Duration.zero ? _p.duration : widget.clip.duration;

  @override
  Widget build(BuildContext context) {
    final u = widget.unit;
    final clip = widget.clip;
    return Container(
      key: const ValueKey('clipPlayer'),
      color: const Color(0xFF0B0C0D),
      padding: EdgeInsets.all(20 * u),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            galleryButton(u, '‹ Gallery', widget.onBack, key: const ValueKey('clipBack')),
            SizedBox(width: 16 * u),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                  Text(formatClipDate(clip.start, DateTime.now()),
                      style: TextStyle(color: Colors.white, fontSize: 30 * u, fontWeight: FontWeight.bold, height: 1.0)),
                  SizedBox(width: 14 * u),
                  Text('${formatRecordingTime(clip.duration)} · ${formatBytes(clip.bytes)}',
                      style: TextStyle(color: const Color(0xFF8C8C8C), fontSize: 22 * u, height: 1.0)),
                ]),
              ),
            ),
            SizedBox(width: 16 * u),
            galleryButton(u, clip.starred ? '★ Starred' : '☆ Star', () => widget.onStar(!clip.starred),
                key: const ValueKey('clipStar'), color: clip.starred ? _starColor : null),
            SizedBox(width: 12 * u),
            galleryButton(u, 'Share', widget.onShare, key: const ValueKey('clipShare')),
            SizedBox(width: 12 * u),
            galleryButton(u, 'Delete', widget.onDelete, key: const ValueKey('clipDelete')),
          ]),
          SizedBox(height: 14 * u),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: _p.aspectRatio,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14 * u),
                  child: GestureDetector(
                    onTap: () => _p.playing ? _p.pause() : _p.play(),
                    child: Stack(fit: StackFit.expand, children: [
                      Container(color: Colors.black, child: _p.ready ? _p.view() : null),
                      if (_error != null)
                        Center(child: Text(_error!, style: TextStyle(color: Colors.white70, fontSize: 24 * u)))
                      else if (!_p.playing)
                        Center(
                          child: Container(
                            key: const ValueKey('clipPlay'),
                            width: 110 * u,
                            height: 110 * u,
                            decoration: const BoxDecoration(color: Color(0x8C000000), shape: BoxShape.circle),
                            child: Icon(Icons.play_arrow, color: Colors.white, size: 64 * u),
                          ),
                        ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: 14 * u),
          Row(children: [
            SizedBox(
              width: 100 * u,
              child: Text(formatRecordingTime(_p.position),
                  style: TextStyle(color: Colors.white, fontSize: 24 * u, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            Expanded(
              child: LayoutBuilder(builder: (context, c) {
                void seek(double x) {
                  final f = (x / c.maxWidth).clamp(0.0, 1.0);
                  _p.seekTo(_length * f);
                }

                return GestureDetector(
                  key: const ValueKey('clipScrubber'),
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => seek(d.localPosition.dx),
                  onHorizontalDragUpdate: (d) => seek(d.localPosition.dx),
                  child: SizedBox(
                    height: 40 * u,
                    child: CustomPaint(
                      painter: ScrubberPainter(
                        position: _p.position,
                        length: _length,
                        buffered: clip.buffered,
                        events: clip.events,
                        unit: u,
                      ),
                    ),
                  ),
                );
              }),
            ),
            SizedBox(width: 20 * u),
            Text(formatRecordingTime(_length), style: TextStyle(color: const Color(0xFF8C8C8C), fontSize: 24 * u)),
          ]),
          SizedBox(height: 8 * u),
          Wrap(spacing: 26 * u, children: [
            for (final (c, t) in const [
              (scrubDisengaged, 'disengaged'),
              (scrubAlert, 'alert'),
              (scrubEngaged, 'engaged'),
              (Color(0xFF5A5B5E), 'from before Record'),
            ])
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 8 * u, height: 18 * u, color: c),
                SizedBox(width: 8 * u),
                Text(t, style: TextStyle(color: const Color(0xFF9A9A9A), fontSize: 20 * u)),
              ]),
          ]),
        ],
      ),
    );
  }
}

/// the scrubber: track, the buffered part shaded, played part white, a tick at each event, the thumb
class ScrubberPainter extends CustomPainter {
  final Duration position;
  final Duration length;
  final Duration buffered;
  final List<DriveEvent> events;
  final double unit;

  const ScrubberPainter({required this.position, required this.length, required this.buffered, required this.events, required this.unit});

  /// where [d] falls on a scrubber [width] wide
  static double xFor(Duration d, Duration length, double width) =>
      length <= Duration.zero ? 0 : (d.inMicroseconds / length.inMicroseconds).clamp(0.0, 1.0) * width;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, cy = size.height / 2, h = 12 * unit;
    final r = Radius.circular(h / 2);
    canvas.drawRRect(RRect.fromLTRBR(0, cy - h / 2, w, cy + h / 2, r), Paint()..color = const Color(0xFF2E3034));
    if (buffered > Duration.zero) {
      canvas.drawRRect(RRect.fromLTRBR(0, cy - h / 2, xFor(buffered, length, w), cy + h / 2, r),
          Paint()..color = const Color(0x1FFFFFFF));
    }
    final at = xFor(position, length, w);
    canvas.drawRRect(RRect.fromLTRBR(0, cy - h / 2, at, cy + h / 2, r), Paint()..color = Colors.white);
    for (final e in events) {
      final x = xFor(e.at, length, w);
      canvas.drawRRect(
        RRect.fromLTRBR(x - 3 * unit, cy - 14 * unit, x + 3 * unit, cy + 14 * unit, Radius.circular(3 * unit)),
        Paint()..color = scrubColor(e.kind),
      );
    }
    canvas.drawCircle(Offset(at, cy), 16 * unit, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(ScrubberPainter old) =>
      old.position != position || old.length != length || old.buffered != buffered || old.events != events || old.unit != unit;
}
