// menu column down the left of the screen: the OPR logo, then Navigate, Details,
// Record, Settings and Gallery, with Exit at the bottom
//
// sizes are in the redesign mockup's pixels (a 1920x1000 screen), scaled by `unit`

import 'package:flutter/material.dart';

/// width of the column in mockup pixels
const menuRailWidth = 150.0;

const _railColor = Color(0xFF0E0F10);
const _itemColor = Color(0xFFE6E6E6);
const _activeBackground = Color(0x1AFFFFFF);
const _recordColor = Color(0xFFFF4D4D);
const _exitColor = Color(0xFFA6A6A6);

const _noteColor = Color(0xFF9A9A9A);
const _savedColor = Color(0xFF3ADB6D);

/// what Record shows under its name
sealed class RecordBadge {
  const RecordBadge();
}

/// keeping the last [length] ready: "● last 1:00"
class BufferBadge extends RecordBadge {
  final Duration length;
  const BufferBadge(this.length);
}

/// a clip running: red, "2:14" over "of 5:00"
class RecordingBadge extends RecordBadge {
  final Duration length;
  final Duration cap;
  const RecordingBadge(this.length, this.cap);
}

/// a clip just written: "✓ Saved" over "2:14 clip"
class SavedBadge extends RecordBadge {
  final Duration length;
  const SavedBadge(this.length);
}

/// the menu's entries, top to bottom
enum MenuItem { navigate, details, record, settings, gallery, exit }

String menuItemLabel(MenuItem item) {
  switch (item) {
    case MenuItem.navigate:
      return 'Navigate';
    case MenuItem.details:
      return 'Details';
    case MenuItem.record:
      return 'Record';
    case MenuItem.settings:
      return 'Settings';
    case MenuItem.gallery:
      return 'Gallery';
    case MenuItem.exit:
      return 'Exit';
  }
}

IconData menuItemIcon(MenuItem item) {
  switch (item) {
    case MenuItem.navigate:
      return Icons.navigation_outlined;
    case MenuItem.details:
      return Icons.insights;
    case MenuItem.record:
      return Icons.radio_button_checked;
    case MenuItem.settings:
      return Icons.settings_outlined;
    case MenuItem.gallery:
      return Icons.grid_view;
    case MenuItem.exit:
      return Icons.power_settings_new;
  }
}

class MenuRail extends StatelessWidget {
  final double unit;

  /// the screen showing now, highlighted; null on the plain driving view
  final MenuItem? active;

  /// what Record shows under its name; it turns red while a clip runs
  final RecordBadge? record;

  final void Function(MenuItem item) onSelect;

  const MenuRail({super.key, required this.unit, this.active, this.record, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('menuRail'),
      width: menuRailWidth * unit,
      color: _railColor,
      padding: EdgeInsets.fromLTRB(0, 14 * unit, 0, 20 * unit),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(26 * unit),
            child: Image.asset(
              'assets/icons/oprivview_logo.png',
              key: const ValueKey('menuLogo'),
              width: (menuRailWidth - 30) * unit,
              height: (menuRailWidth - 30) * unit,
              filterQuality: FilterQuality.medium,
            ),
          ),
          SizedBox(height: 10 * unit),
          // a short screen scrolls the entries rather than overflowing
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final item in const [
                    MenuItem.navigate,
                    MenuItem.details,
                    MenuItem.record,
                    MenuItem.settings,
                    MenuItem.gallery,
                  ])
                    _item(item),
                ],
              ),
            ),
          ),
          _item(MenuItem.exit),
        ],
      ),
    );
  }

  Widget _item(MenuItem item) {
    final badge = item == MenuItem.record ? record : null;
    final color = badge is RecordingBadge ? _recordColor : (item == MenuItem.exit ? _exitColor : _itemColor);
    return Padding(
      padding: EdgeInsets.only(bottom: 6 * unit),
      child: Material(
        color: item == active ? _activeBackground : Colors.transparent,
        borderRadius: BorderRadius.circular(22 * unit),
        child: InkWell(
          key: ValueKey('menu_${item.name}'),
          borderRadius: BorderRadius.circular(22 * unit),
          onTap: () => onSelect(item),
          child: SizedBox(
            width: (menuRailWidth - 24) * unit,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 12 * unit),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(menuItemIcon(item), color: color, size: 50 * unit),
                  SizedBox(height: 8 * unit),
                  Text(
                    menuItemLabel(item),
                    style: TextStyle(color: color, fontSize: 20 * unit, fontWeight: FontWeight.w600, height: 1.0),
                  ),
                  if (badge != null) ...[
                    SizedBox(height: 4 * unit),
                    _badge(badge),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _badge(RecordBadge badge) {
    TextStyle style(Color c, double size, FontWeight w) =>
        TextStyle(color: c, fontSize: size * unit, fontWeight: w, height: 1.0, fontFeatures: const [FontFeature.tabularFigures()]);
    final lines = switch (badge) {
      BufferBadge(:final length) => <Widget>[
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 9 * unit,
              height: 9 * unit,
              decoration: const BoxDecoration(color: _noteColor, shape: BoxShape.circle),
            ),
            SizedBox(width: 5 * unit),
            Text('last ${formatRecordingTime(length)}', style: style(_noteColor, 17, FontWeight.bold)),
          ]),
        ],
      RecordingBadge(:final length, :final cap) => <Widget>[
          Text(formatRecordingTime(length), key: const ValueKey('recordTime'), style: style(_recordColor, 21, FontWeight.w800)),
          SizedBox(height: 3 * unit),
          Text('of ${formatRecordingTime(cap)}', style: style(_noteColor, 15, FontWeight.w600)),
        ],
      SavedBadge(:final length) => <Widget>[
          Text('✓ Saved', key: const ValueKey('recordSaved'), style: style(_savedColor, 18, FontWeight.w800)),
          SizedBox(height: 3 * unit),
          Text('${formatRecordingTime(length)} clip', style: style(_noteColor, 15, FontWeight.w600)),
        ],
    };
    return FittedBox(fit: BoxFit.scaleDown, child: Column(mainAxisSize: MainAxisSize.min, children: lines));
  }
}

/// "2:14", or "1:02:14" past an hour
String formatRecordingTime(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
