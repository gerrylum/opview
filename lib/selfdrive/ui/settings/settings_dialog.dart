// settings dialog — opened by a long press on the driving display

import 'package:flutter/material.dart';
import 'package:opview/services/app_settings.dart';

Future<void> showSettingsDialog(BuildContext context, AppSettings settings) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('opview settings'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 16, bottom: 4),
                child: Text('Layout'),
              ),
              for (final layout in OnroadLayout.values)
                ListTile(
                  dense: true,
                  title: Text(onroadLayoutLabel(layout)),
                  trailing: settings.layout == layout ? const Icon(Icons.check) : null,
                  onTap: () => settings.setLayout(layout),
                ),
              const Padding(
                padding: EdgeInsets.only(left: 16, top: 12, bottom: 4),
                child: Text('Clock'),
              ),
              for (final mode in ClockMode.values)
                ListTile(
                  dense: true,
                  title: Text(clockModeLabel(mode)),
                  trailing: settings.clockMode == mode ? const Icon(Icons.check) : null,
                  onTap: () => settings.setClockMode(mode),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    ),
  );
}
