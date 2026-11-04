// augmented road view — the camera area of the driving screen
// video and overlay share one zoom + horizon offset, as on the device
//
// one layout (enhanced_layout.dart) draws everything over the camera; which of its
// sections show is chosen in Settings > Display. The menu column and the status bar
// around it belong to the app shell (shell/app_shell.dart)

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:opview/common/transformations.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/onroad/pip_layout.dart';
import 'package:opview/selfdrive/ui/settings/settings_dialog.dart';
import 'package:opview/services/app_settings.dart';

// which build this is, shown on the Connecting screen; set at build time with
// flutter build apk --dart-define=OPVIEW_BUILD=0.1.1-comma3x.N
const opviewBuild = String.fromEnvironment('OPVIEW_BUILD', defaultValue: 'dev build');

class AugmentedRoadView extends StatefulWidget {
  final UIState uiState;
  final RTCVideoRenderer? videoRenderer;

  // manual device IP, for networks where mDNS discovery does not work
  final Future<String?> Function()? loadManualHost;
  final Future<void> Function(String? host)? onSetManualHost;

  // viewer-side settings (sections, speed limit, ...); null = everything at its default
  final AppSettings? settings;

  // address of the comma in use, for the settings menu
  final String? Function()? currentHost;

  // Android has shrunk the app to a picture-in-picture window: show PipLayout, no gestures
  final bool pip;

  const AugmentedRoadView({
    super.key,
    required this.uiState,
    this.videoRenderer,
    this.loadManualHost,
    this.onSetManualHost,
    this.settings,
    this.currentHost,
    this.pip = false,
  });

  @override
  State<AugmentedRoadView> createState() => _AugmentedRoadViewState();
}

class _AugmentedRoadViewState extends State<AugmentedRoadView> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(builder: (context, constraints) {
        final screenW = constraints.maxWidth;
        final screenH = constraints.maxHeight;
        final scale = screenH / 1080.0;
        final settings = widget.settings;
        final speedLimitDisplay = settings?.speedLimitDisplay ?? SpeedLimitDisplay.auto;
        // read by the layout through UIState.showRoadName
        widget.uiState.roadNameEnabled = settings?.showRoadName ?? true;

        if (widget.pip) {
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
            child: PipLayout(
              uiState: widget.uiState,
              speedLimitDisplay: speedLimitDisplay,
              frameFor: _fullScreenFrame,
              videoBuilder: _videoLayer,
            ),
          );
        }

        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
          child: Stack(
            fit: StackFit.expand,
            children: [
              EnhancedLayout(
                uiState: widget.uiState,
                clockMode: settings?.clockMode ?? ClockMode.h12,
                speedLimitDisplay: speedLimitDisplay,
                hiddenSections: settings?.hiddenSections ?? const <DriveSection>{},
                frameFor: _fullScreenFrame,
                videoBuilder: _videoLayer,
              ),

              // connected, but the telemetry has stopped: the overlay is old until it
              // comes back or the session is rebuilt (connection_manager.dart)
              if (widget.uiState.isConnected && widget.uiState.dataStale)
                Positioned(
                  top: screenH * 0.36,
                  left: 0,
                  right: 0,
                  child: Center(child: DataPausedTag(scale: scale)),
                ),

              // connecting overlay with rolling status log
              if (!widget.uiState.isConnected)
                Container(
                  color: const Color(0xCC000000),
                  alignment: Alignment.center,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Connecting…',
                          style: TextStyle(
                            color: const Color(0x99FFFFFF),
                            fontSize: 40 * scale,
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                        Text(
                          'OPRivView $opviewBuild',
                          style: TextStyle(color: const Color(0x66FFFFFF), fontSize: 18 * scale),
                        ),
                        SizedBox(height: 20 * scale),
                        ...widget.uiState.connectionLog.map((line) => Text(
                          line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: const Color(0x66FFFFFF),
                            fontSize: 16 * scale,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w300,
                          ),
                        )),
                        if (widget.onSetManualHost != null) ...[
                          SizedBox(height: 20 * scale),
                          TextButton(
                            onPressed: () => askForDeviceIp(context,
                                loadManualHost: widget.loadManualHost, onSetManualHost: widget.onSetManualHost!),
                            child: Text(
                              'Set device IP',
                              style: TextStyle(color: const Color(0x99FFFFFF), fontSize: 20 * scale),
                            ),
                          ),
                        ],
                        if (settings != null)
                          TextButton(
                            onPressed: () => openSettingsMenu(context, settings,
                                loadManualHost: widget.loadManualHost,
                                onSetManualHost: widget.onSetManualHost,
                                currentHost: widget.currentHost),
                            child: Text(
                              'Settings',
                              style: TextStyle(color: const Color(0x99FFFFFF), fontSize: 20 * scale),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }

  /// video layer: the camera image zoomed and shifted exactly as the overlay is,
  /// or black placeholder
  Widget _videoLayer(FrameTransform frame) {
    if (widget.videoRenderer == null) {
      return Container(color: Colors.black);
    }
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: frame.videoLeft,
          top: frame.videoTop,
          width: frame.videoWidth,
          height: frame.videoHeight,
          // the stream is the whole camera frame scaled down (1152x720 for 1928x1208),
          // so cover only trims a fraction of a percent
          child: RTCVideoView(
            widget.videoRenderer!,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          ),
        ),
      ],
    );
  }

  /// the Classic framing (zoom 1.1 road, 2.0 wide on a 1080 px tall screen) over the
  /// whole screen with no border inset, for layouts that draw their own border
  FrameTransform _fullScreenFrame(double w, double h) {
    final isWideCamera = widget.uiState.streamType == 'wideRoad';
    final deviceCamera = _lookupCamera();
    return calcFrameTransform(
      camera: isWideCamera ? deviceCamera.ecam : deviceCamera.fcam,
      calibration: isWideCamera ? _computeWideViewFromCalib() : _computeViewFromCalib(),
      deviceZoom: isWideCamera ? 2.0 : 1.1,
      scale: h / 1080.0,
      x: 0,
      y: 0,
      w: w,
      h: h,
    );
  }

  /// look up camera by device type + sensor, fallback to default
  DeviceCameraConfig _lookupCamera() {
    final st = widget.uiState;
    if (st.deviceType.isNotEmpty && st.sensor.isNotEmpty) {
      return deviceCameras[(st.deviceType, st.sensor)] ?? defaultDeviceCamera;
    }
    return defaultDeviceCamera;
  }

  /// road camera: view_from_calib = VIEW_FRAME_FROM_DEVICE_FRAME @ device_from_calib
  List<List<double>> _computeViewFromCalib() {
    final st = widget.uiState;
    if (st.rpyCalib.length != 3 || st.calStatus != 'calibrated') {
      return viewFrameFromDeviceFrame;
    }
    final deviceFromCalib = rotFromEuler(st.rpyCalib);
    return matmul3x3(viewFrameFromDeviceFrame, deviceFromCalib);
  }

  /// wide camera: view_from_wide_calib = VIEW_FRAME_FROM_DEVICE_FRAME @ wide_from_device @ device_from_calib
  /// (augmented_road_view.py:157-159)
  List<List<double>> _computeWideViewFromCalib() {
    final st = widget.uiState;
    if (st.rpyCalib.length != 3 || st.calStatus != 'calibrated') {
      return viewFrameFromDeviceFrame;
    }
    final deviceFromCalib = rotFromEuler(st.rpyCalib);
    if (st.wideFromDeviceEuler.length == 3) {
      final wideFromDevice = rotFromEuler(st.wideFromDeviceEuler);
      return matmul3x3(viewFrameFromDeviceFrame, matmul3x3(wideFromDevice, deviceFromCalib));
    }
    // fallback: same as road calibration
    return matmul3x3(viewFrameFromDeviceFrame, deviceFromCalib);
  }
}

/// small tag over the road while the telemetry is paused
class DataPausedTag extends StatelessWidget {
  final double scale;

  const DataPausedTag({super.key, required this.scale});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        key: const ValueKey('dataPausedTag'),
        padding: EdgeInsets.symmetric(horizontal: 26 * scale, vertical: 14 * scale),
        decoration: BoxDecoration(
          color: const Color(0xD9141414),
          borderRadius: BorderRadius.circular(40 * scale),
          border: Border.all(color: const Color(0x80FF9A3C), width: 2 * scale),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16 * scale,
              height: 16 * scale,
              decoration: const BoxDecoration(color: Color(0xFFFF9A3C), shape: BoxShape.circle),
            ),
            SizedBox(width: 14 * scale),
            Text(
              'Data paused \u00B7 reconnecting',
              style: TextStyle(color: Colors.white, fontSize: 30 * scale, fontWeight: FontWeight.w600, height: 1.0),
            ),
          ],
        ),
      ),
    );
  }
}

/// the settings menu, with the comma's address and a way to change it; from the menu
/// column and from the connecting screen
Future<void> openSettingsMenu(
  BuildContext context,
  AppSettings settings, {
  Future<String?> Function()? loadManualHost,
  Future<void> Function(String? host)? onSetManualHost,
  String? Function()? currentHost,
}) async {
  final manualHost = await loadManualHost?.call();
  if (!context.mounted) return;
  await showSettingsDialog(
    context,
    settings,
    host: currentHost?.call(),
    hostIsManual: manualHost != null,
    onChangeHost: onSetManualHost == null
        ? null
        : () => askForDeviceIp(context, loadManualHost: loadManualHost, onSetManualHost: onSetManualHost),
    build: opviewBuild,
  );
}

/// ask for the device IP; empty clears it and goes back to auto-discovery
Future<void> askForDeviceIp(
  BuildContext context, {
  Future<String?> Function()? loadManualHost,
  required Future<void> Function(String? host) onSetManualHost,
}) async {
  final current = await loadManualHost?.call() ?? '';
  if (!context.mounted) return;
  final controller = TextEditingController(text: current);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Device IP'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(hintText: 'e.g. 192.168.1.50 (empty = auto)'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Save')),
      ],
    ),
  );
  controller.dispose();
  if (result != null) await onSetManualHost(result);
}
