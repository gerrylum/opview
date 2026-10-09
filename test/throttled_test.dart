// readouts that refresh less often than the camera, and the telemetry channel settings

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/throttled.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/system/webrtc/webrtc_client.dart';

void main() {
  testWidgets('a throttled readout rebuilds every few updates, not every one', (tester) async {
    final state = UIState();
    var builds = 0;
    Widget app() => Directionality(
          textDirection: TextDirection.ltr,
          child: ThrottledByVersion(
            state: state,
            every: 4,
            builder: (_) {
              builds++;
              return Text('${state.vEgo}');
            },
          ),
        );

    await tester.pumpWidget(app());
    expect(builds, 1);

    // 20 model updates, each followed by a frame: about one rebuild per 4
    for (var i = 0; i < 20; i++) {
      state.vEgo = i.toDouble();
      state.applyModelV2({});
      await tester.pumpWidget(app());
    }
    expect(builds, 6);  // the first build, then updates 4, 8, 12, 16, 20

    // a rebuild without new data (a setting changed) is never held back
    await tester.pumpWidget(app());
    expect(builds, 7);
    expect(find.text('19.0'), findsOneWidget);
  });

  testWidgets('a different state rebuilds straight away', (tester) async {
    var builds = 0;
    Widget app(UIState s) => Directionality(
          textDirection: TextDirection.ltr,
          child: ThrottledByVersion(state: s, builder: (_) => Text('${builds++}')),
        );
    await tester.pumpWidget(app(UIState()));
    await tester.pumpWidget(app(UIState()..applyModelV2({})));
    expect(builds, 2);
  });

  test('telemetry channel: unordered, a lost message is not re-sent', () {
    final c = dataChannelConfig();
    expect(c.ordered, false);
    expect(c.maxRetransmits, 0);
  });
}
