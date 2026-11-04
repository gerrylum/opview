// the Gallery: recorded clips as a grid, newest first, with filters, bulk delete and the clip
// player. It fills the camera area (the menu and status bar stay). Sizes are in the redesign
// mockup's pixels, scaled by `unit` (design: claude/oprivview-record-gallery-design.md)

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/gallery/clip_player.dart';
import 'package:opview/selfdrive/ui/gallery/clip_playback.dart';
import 'package:opview/selfdrive/ui/shell/menu_rail.dart' show formatRecordingTime;
import 'package:opview/services/recorder/clip_store.dart';
import 'package:opview/services/recorder/recorder.dart';

enum ClipFilter { all, week, alerts, starred }

String clipFilterLabel(ClipFilter f) =>
    switch (f) { ClipFilter.all => 'All', ClipFilter.week => 'This week', ClipFilter.alerts => 'With alerts', ClipFilter.starred => 'Starred' };

List<Clip> filterClips(List<Clip> clips, ClipFilter f, DateTime now) => switch (f) {
      ClipFilter.all => clips,
      ClipFilter.week => [for (final c in clips) if (now.difference(c.start) < const Duration(days: 7)) c],
      ClipFilter.alerts => [for (final c in clips) if (c.hasAlert) c],
      ClipFilter.starred => [for (final c in clips) if (c.starred) c],
    };

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Today 5:43 PM", "Yesterday 9:15 PM", "Oct 30 7:44 AM"
String formatClipDate(DateTime t, DateTime now) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final time = '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  final day = DateTime(t.year, t.month, t.day), today = DateTime(now.year, now.month, now.day);
  final days = today.difference(day).inDays;
  if (days == 0) return 'Today $time';
  if (days == 1) return 'Yesterday $time';
  return '${_months[t.month - 1]} ${t.day} $time';
}

/// a grey rounded button, as in the mockups
Widget galleryButton(double u, String text, VoidCallback onTap, {Key? key, Color? color, bool danger = false}) {
  return Material(
    color: danger ? const Color(0xFFC92231) : const Color(0xFF2E3034),
    borderRadius: BorderRadius.circular(12 * u),
    child: InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(12 * u),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 22 * u, vertical: 11 * u),
        child: Text(text, style: TextStyle(color: color ?? Colors.white, fontSize: 22 * u, fontWeight: FontWeight.bold, height: 1.0)),
      ),
    ),
  );
}

class GalleryView extends StatefulWidget {
  final Recorder recorder;
  final double unit;
  final ClipPlaybackFactory playback;

  const GalleryView({super.key, required this.recorder, required this.unit, this.playback = videoPlayerPlayback});

  @override
  State<GalleryView> createState() => _GalleryViewState();
}

class _GalleryViewState extends State<GalleryView> {
  List<Clip>? _clips;
  ClipFilter _filter = ClipFilter.all;
  Clip? _open;
  bool _selecting = false;
  final _selected = <String>{};
  int _seenVersion = -1;

  Recorder get _rec => widget.recorder;

  @override
  void initState() {
    super.initState();
    _rec.addListener(_recorderChanged);
    _load();
  }

  @override
  void dispose() {
    _rec.removeListener(_recorderChanged);
    super.dispose();
  }

  void _recorderChanged() {
    if (_rec.clipsVersion != _seenVersion) _load();
  }

  Future<void> _load() async {
    _seenVersion = _rec.clipsVersion;
    final store = await _rec.store();
    final clips = store == null ? <Clip>[] : await store.list();
    if (!mounted) return;
    setState(() {
      _clips = clips;
      final open = _open;
      if (open != null) _open = clips.where((c) => c.id == open.id).firstOrNull;
      _selected.retainAll(clips.map((c) => c.id));
    });
  }

  Future<void> _star(Clip clip, bool starred) async {
    final store = await _rec.store();
    if (store == null) return;
    final updated = await store.setStarred(clip, starred);
    if (!mounted) return;
    setState(() {
      _clips = [for (final c in _clips ?? <Clip>[]) c.id == clip.id ? updated : c];
      if (_open?.id == clip.id) _open = updated;
    });
  }

  Future<void> _delete(List<Clip> clips) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF16171A),
        title: Text(clips.length == 1 ? 'Delete this clip?' : 'Delete ${clips.length} clips?'),
        content: const Text('They are removed from the head unit.'),
        actions: [
          TextButton(key: const ValueKey('deleteCancel'), onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('deleteConfirm'),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC92231)),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final store = await _rec.store();
    if (store == null) return;
    for (final c in clips) {
      await store.delete(c);
    }
    _open = null;
    _selecting = false;
    _selected.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final open = _open;
    if (open != null) {
      return ClipPlayer(
        key: ValueKey('player_${open.id}'),
        clip: open,
        unit: widget.unit,
        playback: widget.playback,
        onBack: () => setState(() => _open = null),
        onStar: (s) => _star(open, s),
        onShare: () => _rec.platform.share(open.video.path),
        onDelete: () => _delete([open]),
      );
    }
    final u = widget.unit;
    final all = _clips;
    final now = DateTime.now();
    final shown = all == null ? <Clip>[] : filterClips(all, _filter, now);
    final used = (all ?? const <Clip>[]).fold<int>(0, (s, c) => s + c.bytes);
    final limit = _rec.settings.storageLimitGb * 1024 * 1024 * 1024;
    return Container(
      key: const ValueKey('galleryView'),
      color: const Color(0xFF0B0C0D),
      padding: EdgeInsets.fromLTRB(20 * u, 26 * u, 20 * u, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Text('Gallery', style: TextStyle(color: Colors.white, fontSize: 34 * u, fontWeight: FontWeight.bold, height: 1.0)),
            SizedBox(width: 18 * u),
            Text(all == null ? '' : '${all.length} ${all.length == 1 ? 'clip' : 'clips'}',
                style: TextStyle(color: const Color(0xFF8C8C8C), fontSize: 22 * u, height: 1.0)),
            const Spacer(),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('${formatBytes(used)} of ${_rec.settings.storageLimitGb} GB',
                      key: const ValueKey('galleryUsage'),
                      style: TextStyle(color: const Color(0xFFBFBFBF), fontSize: 21 * u, height: 1.0)),
                  SizedBox(width: 14 * u),
                  Container(
                    width: 220 * u,
                    height: 10 * u,
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(color: const Color(0xFF2E3034), borderRadius: BorderRadius.circular(5 * u)),
                    child: FractionallySizedBox(
                      widthFactor: limit <= 0 ? 0 : (used / limit).clamp(0.0, 1.0),
                      heightFactor: 1,
                      child: DecoratedBox(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(5 * u))),
                    ),
                  ),
                ]),
              ),
            ),
            SizedBox(width: 16 * u),
            if (_selecting) ...[
              galleryButton(u, 'Delete (${_selected.length})', () {
                final pick = [for (final c in all ?? <Clip>[]) if (_selected.contains(c.id)) c];
                if (pick.isNotEmpty) _delete(pick);
              }, key: const ValueKey('galleryDeleteSelected'), danger: _selected.isNotEmpty),
              SizedBox(width: 12 * u),
              galleryButton(u, 'Cancel', () => setState(() {
                    _selecting = false;
                    _selected.clear();
                  }), key: const ValueKey('gallerySelectCancel')),
            ] else
              galleryButton(u, 'Select', () => setState(() => _selecting = true), key: const ValueKey('gallerySelect')),
          ]),
          SizedBox(height: 18 * u),
          Row(children: [
            for (final f in ClipFilter.values) ...[
              _chip(f),
              SizedBox(width: 10 * u),
            ],
            const Spacer(),
            Flexible(
              flex: 3,
              child: Text('Over ${_rec.settings.storageLimitGb} GB the oldest unstarred clips are removed',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(color: const Color(0xFF8C8C8C), fontSize: 19 * u)),
            ),
          ]),
          SizedBox(height: 18 * u),
          Expanded(
            child: all == null
                ? const SizedBox.shrink()
                : shown.isEmpty
                    ? Center(
                        child: Text(
                          all.isEmpty ? 'No clips yet. Tap Record to save the last minute and what follows' : 'No clips here',
                          key: const ValueKey('galleryEmpty'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: const Color(0xFF8C8C8C), fontSize: 24 * u),
                        ),
                      )
                    : GridView.builder(
                        padding: EdgeInsets.only(bottom: 20 * u),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          mainAxisSpacing: 26 * u,
                          crossAxisSpacing: 22 * u,
                          childAspectRatio: 1.25,
                        ),
                        itemCount: shown.length,
                        itemBuilder: (context, i) => _card(shown[i], now),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _chip(ClipFilter f) {
    final u = widget.unit;
    final on = f == _filter;
    return InkWell(
      key: ValueKey('galleryFilter_${f.name}'),
      onTap: () => setState(() => _filter = f),
      borderRadius: BorderRadius.circular(22 * u),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 20 * u, vertical: 9 * u),
        decoration: BoxDecoration(color: on ? const Color(0xFF2E3034) : const Color(0xFF1A1B1D), borderRadius: BorderRadius.circular(22 * u)),
        child: Text(clipFilterLabel(f),
            style: TextStyle(color: on ? Colors.white : const Color(0xFF9A9A9A), fontSize: 21 * u, fontWeight: FontWeight.w600, height: 1.0)),
      ),
    );
  }

  Widget _badge(String text, Color bg) {
    final u = widget.unit;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10 * u, vertical: 4 * u),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8 * u)),
      child: Text(text, style: TextStyle(color: Colors.white, fontSize: 17 * u, fontWeight: FontWeight.bold, height: 1.0)),
    );
  }

  Widget _card(Clip clip, DateTime now) {
    final u = widget.unit;
    final selected = _selected.contains(clip.id);
    return InkWell(
      key: ValueKey('clip_${clip.id}'),
      onTap: () => setState(() {
        if (_selecting) {
          selected ? _selected.remove(clip.id) : _selected.add(clip.id);
        } else {
          _open = clip;
        }
      }),
      borderRadius: BorderRadius.circular(16 * u),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16 * u),
              child: Stack(fit: StackFit.expand, children: [
                Image.file(
                  clip.thumbnail,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: const Color(0xFF1C1D1F),
                    child: Icon(Icons.movie_outlined, color: const Color(0xFF5A5B5E), size: 48 * u),
                  ),
                ),
                Positioned(right: 10 * u, bottom: 10 * u, child: _badge(formatRecordingTime(clip.duration), const Color(0xBF000000))),
                if (clip.hasAlert) Positioned(left: 10 * u, top: 10 * u, child: _badge('ALERT', const Color(0xE6C92231))),
                if (clip.starred)
                  Positioned(
                    right: 10 * u,
                    top: 6 * u,
                    child: Text('★', key: ValueKey('star_${clip.id}'), style: TextStyle(color: const Color(0xFFFFC83D), fontSize: 30 * u)),
                  ),
                if (_selecting)
                  Container(
                    decoration: BoxDecoration(
                      color: selected ? const Color(0x553D8BFF) : const Color(0x33000000),
                      border: Border.all(color: selected ? const Color(0xFF3D8BFF) : Colors.transparent, width: 4 * u),
                      borderRadius: BorderRadius.circular(16 * u),
                    ),
                    alignment: Alignment.topLeft,
                    padding: EdgeInsets.all(10 * u),
                    child: Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked, color: Colors.white, size: 34 * u),
                  ),
              ]),
            ),
          ),
          SizedBox(height: 10 * u),
          Text(formatClipDate(clip.start, now),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white, fontSize: 23 * u, fontWeight: FontWeight.w600, height: 1.0)),
          SizedBox(height: 6 * u),
          Text(formatBytes(clip.bytes), style: TextStyle(color: const Color(0xFF8C8C8C), fontSize: 18 * u, height: 1.0)),
        ],
      ),
    );
  }
}
