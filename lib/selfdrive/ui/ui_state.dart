// UI state — the single source of truth
// ported from openpilot selfdrive/ui/ui_state.py
//
// one ChangeNotifier, fed by telemetry parser.
// data-driven refresh: notifyListeners on modelV2 arrival.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

// -- constants --

const uiBorderSize = 30;
const setSpeedNA = 255;
const kmToMile = 0.621371;
const msToKph = 3.6;
const msToMph = 2.23694;

// -- engagement status (matches ui_state.py UIStatus) --

enum UIStatus { disengaged, engaged, override_, latOnly, longOnly }

// -- sunnypilot (speed_limit/common.py Mode, lateral_mode.py) --

/// SpeedLimitMode param: 0 off, 1 information, 2 warning, 3 assist
const speedLimitModeOff = 0;
const speedLimitModeWarning = 2;

/// opendbc RivianFlags.ANGLE_HARNESS
const rivianAngleHarnessFlag = 2;

/// consecutive zero-CAN-torque carOutput samples before calling it angle steering.
/// the device uses 10 frames at 100 Hz (0.1 s); webrtcd sends carOutput at 20 Hz for opview
const zeroTorqueHold = 3;

/// mici torque_bar.py DEFAULT_MAX_LAT_ACCEL, m/s^2
const defaultMaxLatAccel = 3.0;

/// how the wheel icon is tinted while MADS steers an angle-capable Rivian
enum LateralMode { angle, torque }

// -- state --

class UIState extends ChangeNotifier {
  // engagement
  UIStatus status = UIStatus.disengaged;
  bool started = false;

  // carState
  double vEgo = 0.0;
  double vEgoCluster = 0.0;
  double vCruiseCluster = 0.0;
  bool vEgoClusterSeen = false;
  double steeringAngleDeg = 0.0;

  // selfdriveState
  bool enabled = false;
  bool engageable = false;
  bool experimentalMode = false;
  String alertText1 = '';
  String alertText2 = '';
  int alertSize = 0;     // 0=none, 1=small, 2=mid, 3=full
  int alertStatus = 0;   // 0=normal, 1=userPrompt, 2=critical
  String openpilotState = '';

  // controlsState
  double vCruiseDEPRECATED = 0.0;
  double curvature = 0.0;
  double desiredCurvature = 0.0;
  String lateralControlKind = '';  // which lateralControlState is set, e.g. 'torqueState'

  // carOutput.actuatorsOutput.torque, -1..1
  double torqueOutput = 0.0;

  // driverMonitoringState
  bool dmSeen = false;
  bool dmActive = false;             // camera-based monitoring is running
  bool dmFaceDetected = false;
  double dmAwarenessPercent = 100.0;
  double dmRotationDeg = 90.0;       // which way the head is turned, smoothed; 90 = straight ahead

  // modelV2.meta.disengagePredictions: largest value of each list
  bool confidenceSeen = false;
  double brakeDisengageProb = 0.0;
  double steerOverrideProb = 0.0;
  double confidenceFiltered = -0.5;  // smoothed confidence; below 0 while disengaged

  // modelV2 — raw lists from cereal
  List<double> pathX = [];
  List<double> pathY = [];
  List<double> pathZ = [];
  List<List<double>> laneLineX = [[], [], [], []];
  List<List<double>> laneLineY = [[], [], [], []];
  List<List<double>> laneLineZ = [[], [], [], []];
  List<double> laneLineProbs = [0, 0, 0, 0];
  List<List<double>> roadEdgeX = [[], []];
  List<List<double>> roadEdgeY = [[], []];
  List<List<double>> roadEdgeZ = [[], []];
  List<double> roadEdgeStds = [0, 0];
  List<double> accelerationX = [];

  // liveCalibration
  List<double> rpyCalib = [];
  List<double> wideFromDeviceEuler = [];
  String calStatus = '';
  List<double> calibHeight = [];

  // radarState
  Map<String, dynamic>? leadOne;
  Map<String, dynamic>? leadTwo;

  // longitudinalPlan
  bool allowThrottle = true;

  // throttle blend — smooth fade between throttle/no-throttle path colors
  // first-order filter: tau=0.25s, updated at modelV2 rate (~20Hz)
  double throttleBlend = 1.0; // 1.0 = full throttle colors, 0.0 = no-throttle

  // deviceState / roadCameraState — for camera intrinsics lookup
  String deviceType = '';
  String sensor = '';

  // is_metric (default true, like stock); replaced by the device's IsMetric once opviewParams arrives
  bool isMetric = true;

  // opviewParams — device settings sent by webrtcd (dys-a) once a second
  bool paramsSeen = false;
  int speedLimitMode = speedLimitModeOff;
  bool roadNameToggle = false;
  bool forceTorqueSteer = false;
  bool trueVEgoUI = false;
  bool liveSpeedCorrection = false;
  int cruiseSpeedOffsetKph = 0;
  bool showTurnSignals = false;
  bool showBlindSpot = false;

  // selfdriveStateSP.mads + onroadEvents — sunnypilot border colours
  bool madsSeen = false;
  String madsState = 'disabled';
  bool madsEnabled = false;
  bool madsAvailable = false;
  bool overrideLongitudinal = false;

  // carState turn signals / blind spot
  bool leftBlinker = false;
  bool rightBlinker = false;
  bool leftBlindspot = false;
  bool rightBlindspot = false;
  DateTime? leftSignalSince;   // when the blinker came on, for the arrow pulse
  DateTime? rightSignalSince;

  // longitudinalPlanSP.speedLimit — speeds in m/s
  double speedLimit = 0.0;
  double speedLimitLast = 0.0;
  double speedLimitOffset = 0.0;
  bool speedLimitValid = false;
  bool speedLimitLastValid = false;
  double speedLimitFinalLast = 0.0;
  String speedLimitSource = 'none';
  String speedLimitAssistState = 'disabled';

  // liveMapDataSP — speeds in m/s, distance in m
  bool speedLimitAheadValid = false;
  double speedLimitAhead = 0.0;
  double speedLimitAheadDistance = 0.0;
  String roadName = '';

  // carParams / carControl / carOutput — for the Rivian angle/torque wheel tint
  String brand = '';
  int carFlags = 0;
  bool latActive = false;
  int _zeroTorqueCount = zeroTorqueHold;
  LateralMode? lateralMode;

  // active camera: 'road' or 'wideRoad' (switches on experimental mode)
  String streamType = 'road';

  // connection state — drives "Connecting..." overlay + screen wake lock
  bool isConnected = false;

  // rolling status log shown on the connecting overlay (newest last)
  final List<String> connectionLog = [];
  static const _maxLogLines = 8;

  void addConnectionStatus(String msg) {
    connectionLog.add(msg);
    if (connectionLog.length > _maxLogLines) connectionLog.removeAt(0);
  }

  /// monotonic version counter — incremented on each notify.
  /// used by painters to detect state changes in shouldRepaint.
  int version = 0;

  /// notify listeners and bump version
  void _notify() {
    version++;
    notifyListeners();
  }

  /// force immediate notify (for connection state changes)
  void notifyNow() {
    _notify();
  }

  // -- apply methods: one per cereal service --

  void applyCarState(Map<String, dynamic> data) {
    vEgo = (data['vEgo'] as num?)?.toDouble() ?? 0.0;
    vEgoCluster = (data['vEgoCluster'] as num?)?.toDouble() ?? 0.0;
    vCruiseCluster = (data['vCruiseCluster'] as num?)?.toDouble() ?? 0.0;
    if (!vEgoClusterSeen && vEgoCluster != 0.0) vEgoClusterSeen = true;
    steeringAngleDeg = (data['steeringAngleDeg'] as num?)?.toDouble() ?? 0.0;
    final left = data['leftBlinker'] as bool? ?? false;
    final right = data['rightBlinker'] as bool? ?? false;
    if (left && !leftBlinker) leftSignalSince = DateTime.now();
    if (right && !rightBlinker) rightSignalSince = DateTime.now();
    leftBlinker = left;
    rightBlinker = right;
    leftBlindspot = data['leftBlindspot'] as bool? ?? false;
    rightBlindspot = data['rightBlindspot'] as bool? ?? false;
    // no notify — picked up on next modelV2
  }

  void applySelfdriveState(Map<String, dynamic> data) {
    enabled = data['enabled'] as bool? ?? false;
    engageable = data['engageable'] as bool? ?? false;
    experimentalMode = data['experimentalMode'] as bool? ?? false;
    alertText1 = data['alertText1'] as String? ?? '';
    alertText2 = data['alertText2'] as String? ?? '';
    alertSize = _alertSizeFromString(data['alertSize']);
    alertStatus = _alertStatusFromString(data['alertStatus']);
    openpilotState = data['state'] as String? ?? '';

    // update engagement status
    started = true;
    _updateStatus();
    // no notify — picked up on next modelV2
  }

  void applyControlsState(Map<String, dynamic> data) {
    vCruiseDEPRECATED = (data['vCruiseDEPRECATED'] as num?)?.toDouble() ?? 0.0;
    curvature = (data['curvature'] as num?)?.toDouble() ?? 0.0;
    desiredCurvature = (data['desiredCurvature'] as num?)?.toDouble() ?? 0.0;
    final lat = data['lateralControlState'];
    lateralControlKind = (lat is Map && lat.isNotEmpty) ? '${lat.keys.first}' : '';
    // no notify — picked up on next modelV2
  }

  void applyModelV2(Map<String, dynamic> data) {
    _fillDoubles(pathX, data['position']?['x']);
    _fillDoubles(pathY, data['position']?['y']);
    _fillDoubles(pathZ, data['position']?['z']);

    final lanes = data['laneLines'] as List? ?? [];
    for (int i = 0; i < 4 && i < lanes.length; i++) {
      _fillDoubles(laneLineX[i], lanes[i]['x']);
      _fillDoubles(laneLineY[i], lanes[i]['y']);
      _fillDoubles(laneLineZ[i], lanes[i]['z']);
    }
    _fillDoublesFixed(laneLineProbs, data['laneLineProbs'], 4);

    final edges = data['roadEdges'] as List? ?? [];
    for (int i = 0; i < 2 && i < edges.length; i++) {
      _fillDoubles(roadEdgeX[i], edges[i]['x']);
      _fillDoubles(roadEdgeY[i], edges[i]['y']);
      _fillDoubles(roadEdgeZ[i], edges[i]['z']);
    }
    _fillDoublesFixed(roadEdgeStds, data['roadEdgeStds'], 2);
    _fillDoubles(accelerationX, data['acceleration']?['x']);

    // confidence ball (mici confidence_ball.py); sent by webrtcd only on newer opview branches
    final predictions = data['meta']?['disengagePredictions'];
    if (predictions is Map) {
      confidenceSeen = true;
      brakeDisengageProb = _largest(predictions['brakeDisengageProbs']);
      steerOverrideProb = _largest(predictions['steerOverrideProbs']);
    }
    // first-order filter, tau 0.5 s at ~20 Hz
    confidenceFiltered += 0.09 * (confidenceTarget - confidenceFiltered);

    // smooth throttle blend: first-order filter (tau=0.25s at ~20Hz → k≈0.167)
    const k = 0.167; // dt / (tau + dt) = 0.05 / (0.25 + 0.05)
    final target = allowThrottle ? 1.0 : 0.0;
    throttleBlend = throttleBlend + k * (target - throttleBlend);

    _notify();  // data-driven: render on modelV2 arrival
  }

  void applyLiveCalibration(Map<String, dynamic> data) {
    _fillDoubles(rpyCalib, data['rpyCalib']);
    _fillDoubles(wideFromDeviceEuler, data['wideFromDeviceEuler']);
    calStatus = data['calStatus'] as String? ?? '';
    _fillDoubles(calibHeight, data['height']);
    // no notify — picked up on next modelV2
  }

  void applyRadarState(Map<String, dynamic> data) {
    leadOne = data['leadOne'] as Map<String, dynamic>?;
    leadTwo = data['leadTwo'] as Map<String, dynamic>?;
    // no notify — picked up on next modelV2
  }

  void applyLongitudinalPlan(Map<String, dynamic> data) {
    allowThrottle = data['allowThrottle'] as bool? ?? true;
    // no notify — picked up on next modelV2
  }

  void applyDeviceState(Map<String, dynamic> data) {
    deviceType = data['deviceType'] as String? ?? '';
    started = data['started'] as bool? ?? started;
    // no notify — picked up on next modelV2
  }

  void applyRoadCameraState(Map<String, dynamic> data) {
    sensor = data['sensor'] as String? ?? '';
    // no notify — picked up on next modelV2
  }

  /// engagement status; once sunnypilot's MADS state has arrived, follow
  /// sunnypilot ui_state.py UIStateSP.update_status
  void _updateStatus() {
    final override = openpilotState == 'preEnabled' || openpilotState == 'overriding';
    if (!madsSeen) {
      status = override ? UIStatus.override_ : (enabled ? UIStatus.engaged : UIStatus.disengaged);
      return;
    }
    if (openpilotState == 'preEnabled') {
      status = UIStatus.override_;
    } else if (openpilotState == 'overriding' && (!madsAvailable || overrideLongitudinal)) {
      status = UIStatus.override_;
    } else if (madsState == 'paused' || madsState == 'overriding') {
      status = UIStatus.override_;
    } else if (!madsAvailable) {
      status = enabled ? UIStatus.engaged : UIStatus.disengaged;
    } else if (madsEnabled && enabled) {
      status = UIStatus.engaged;
    } else if (madsEnabled) {
      status = UIStatus.latOnly;
    } else if (enabled) {
      status = UIStatus.longOnly;
    } else {
      status = UIStatus.disengaged;
    }
  }

  // -- sunnypilot apply methods --

  void applySelfdriveStateSP(Map<String, dynamic> data) {
    final mads = data['mads'] as Map<String, dynamic>? ?? const {};
    madsSeen = true;
    madsState = mads['state'] as String? ?? 'disabled';
    madsEnabled = mads['enabled'] as bool? ?? false;
    madsAvailable = mads['available'] as bool? ?? false;
    _updateStatus();
    // no notify — picked up on next modelV2
  }

  /// onroadEvents is a list of events; only overrideLongitudinal matters here
  void applyOnroadEvents(List<dynamic> events) {
    overrideLongitudinal = events.any((e) => e is Map && e['overrideLongitudinal'] == true);
    _updateStatus();
  }

  void applyOpviewParams(Map<String, dynamic> data) {
    paramsSeen = true;
    isMetric = data['IsMetric'] as bool? ?? isMetric;
    speedLimitMode = (data['SpeedLimitMode'] as num?)?.toInt() ?? speedLimitModeOff;
    roadNameToggle = data['RoadNameToggle'] as bool? ?? false;
    forceTorqueSteer = data['RivianForceTorqueSteer'] as bool? ?? false;
    trueVEgoUI = data['TrueVEgoUI'] as bool? ?? false;
    liveSpeedCorrection = data['SPLiveSpeedCorrectionEnabled'] as bool? ?? false;
    cruiseSpeedOffsetKph = (data['SPCruiseSpeedOffset'] as num?)?.toInt() ?? 0;
    showTurnSignals = data['ShowTurnSignals'] as bool? ?? false;
    showBlindSpot = data['BlindSpot'] as bool? ?? false;
    // car make and flags (carParams is only published every ~50 s)
    brand = data['CarBrand'] as String? ?? brand;
    carFlags = (data['CarFlags'] as num?)?.toInt() ?? carFlags;
    // no notify — picked up on next modelV2
  }

  void applyLongitudinalPlanSP(Map<String, dynamic> data) {
    final sl = data['speedLimit'] as Map<String, dynamic>? ?? const {};
    final resolver = sl['resolver'] as Map<String, dynamic>? ?? const {};
    final assist = sl['assist'] as Map<String, dynamic>? ?? const {};
    speedLimit = (resolver['speedLimit'] as num?)?.toDouble() ?? 0.0;
    speedLimitLast = (resolver['speedLimitLast'] as num?)?.toDouble() ?? 0.0;
    speedLimitOffset = (resolver['speedLimitOffset'] as num?)?.toDouble() ?? 0.0;
    speedLimitValid = resolver['speedLimitValid'] as bool? ?? false;
    speedLimitLastValid = resolver['speedLimitLastValid'] as bool? ?? false;
    speedLimitFinalLast = (resolver['speedLimitFinalLast'] as num?)?.toDouble() ?? 0.0;
    speedLimitSource = resolver['source'] as String? ?? 'none';
    speedLimitAssistState = assist['state'] as String? ?? 'disabled';
    // no notify — picked up on next modelV2
  }

  void applyLiveMapDataSP(Map<String, dynamic> data) {
    speedLimitAheadValid = data['speedLimitAheadValid'] as bool? ?? false;
    speedLimitAhead = (data['speedLimitAhead'] as num?)?.toDouble() ?? 0.0;
    speedLimitAheadDistance = (data['speedLimitAheadDistance'] as num?)?.toDouble() ?? 0.0;
    roadName = data['roadName'] as String? ?? '';
    // no notify — picked up on next modelV2
  }

  void applyCarParams(Map<String, dynamic> data) {
    brand = data['brand'] as String? ?? '';
    carFlags = (data['flags'] as num?)?.toInt() ?? 0;
  }

  /// mici driver_state.py get_driver_data + _update_state
  void applyDriverMonitoringState(Map<String, dynamic> data) {
    dmSeen = true;
    var pitch = 0.0, yaw = 0.0;
    final vision = data['visionPolicyState'];
    if (vision is Map) {
      // current openpilot: one state per monitoring policy
      dmActive = data['activePolicy'] == 'vision';
      dmFaceDetected = vision['faceDetected'] as bool? ?? false;
      dmAwarenessPercent = (vision['awarenessPercent'] as num?)?.toDouble() ?? 100.0;
      final pose = vision['pose'];
      if (pose is Map) {
        pitch = (pose['pitch'] as num?)?.toDouble() ?? 0.0;
        yaw = (pose['yaw'] as num?)?.toDouble() ?? 0.0;
      }
    } else {
      // older openpilot: flat fields and no head pose
      dmActive = data['isActiveMode'] as bool? ?? true;
      dmFaceDetected = data['faceDetected'] as bool? ?? false;
      dmAwarenessPercent = ((data['awarenessStatus'] as num?)?.toDouble() ?? 1.0) * 100;
    }

    // the device adds 6 degrees of upward pitch and undoes the yaw sign flip
    final isRhd = data['isRHD'] as bool? ?? false;
    pitch += 6 * math.pi / 180;
    yaw *= isRhd ? 1 : -1;
    final target = math.atan2(pitch * 2, yaw) * 180 / math.pi;
    // smooth, turning the short way round
    final diff = (target - dmRotationDeg + 180) % 360 - 180;
    dmRotationDeg += 0.35 * diff;
  }

  /// attention has started to run down (driver_state.py AWARENESS_UNFULL_PERCENT)
  bool get dmAwarenessUnfull => dmActive && dmAwarenessPercent < 95;

  void applyCarControl(Map<String, dynamic> data) {
    latActive = data['latActive'] as bool? ?? false;
  }

  /// lateral_mode.py: on an angle-capable Rivian while MADS steers, the car sends no CAN
  /// torque when it steers on its angle channel
  void applyCarOutput(Map<String, dynamic> data) {
    final out = data['actuatorsOutput'];
    torqueOutput = out is Map ? ((out['torque'] as num?)?.toDouble() ?? 0.0) : 0.0;
    final angleCapable = brand == 'rivian' && (carFlags & rivianAngleHarnessFlag) != 0;
    if (!angleCapable || !latActive) {
      lateralMode = null;
      return;
    }
    if (forceTorqueSteer) {
      _zeroTorqueCount = 0;
      lateralMode = LateralMode.torque;
      return;
    }
    final actuators = data['actuatorsOutput'] as Map<String, dynamic>? ?? const {};
    final torque = (actuators['torqueOutputCan'] as num?)?.toDouble() ?? 0.0;
    if (torque == 0) {
      _zeroTorqueCount = _zeroTorqueCount + 1 > zeroTorqueHold ? zeroTorqueHold : _zeroTorqueCount + 1;
    } else {
      _zeroTorqueCount = 0;
    }
    lateralMode = _zeroTorqueCount >= zeroTorqueHold ? LateralMode.angle : LateralMode.torque;
  }

  // -- derived values --

  /// how confident the model is that no takeover is coming, 0..1; -0.5 while
  /// disengaged so the ball slides off the bottom (confidence_ball.py)
  double get confidenceTarget {
    switch (status) {
      case UIStatus.disengaged:
        return -0.5;
      case UIStatus.latOnly:
        return 1 - steerOverrideProb;
      case UIStatus.longOnly:
        return 1 - brakeDisengageProb;
      case UIStatus.engaged:
      case UIStatus.override_:
        return (1 - brakeDisengageProb) * (1 - steerOverrideProb);
    }
  }

  /// steering effort for the comma four style torque bar, -1..1 (mici torque_bar.py).
  /// angle and curvature control have no torque, so the device estimates it from
  /// lateral acceleration; it also removes road roll, which opview is not sent
  double get torqueBarValue {
    if (lateralControlKind == 'angleState' || lateralControlKind == 'curvatureState') {
      if (!latActive) return 0.0;
      final desiredLateralAccel = desiredCurvature * vEgo * vEgo;
      return (desiredLateralAccel / defaultMaxLatAccel).clamp(-1.0, 1.0).toDouble();
    }
    return (-torqueOutput).clamp(-1.0, 1.0).toDouble();
  }

  /// speed conversion for the current unit
  double get speedConv => isMetric ? msToKph : msToMph;

  /// show the speed limit sign (speed_limit.py: SpeedLimitMode != off)
  bool get showSpeedLimit => paramsSeen && speedLimitMode != speedLimitModeOff;

  /// show the road name pill (road_name.py)
  bool get showRoadName => roadNameToggle && roadName.isNotEmpty;

  /// display speed in current unit (km/h or mph); sunnypilot speed_renderer.py:
  /// the dash speed unless "Always Display True Speed" is on, then the wheel speed,
  /// less the learned over-read when live speed correction is on
  double get displaySpeed {
    double v;
    if (vEgoClusterSeen && !trueVEgoUI) {
      v = vEgoCluster;
    } else if (liveSpeedCorrection) {
      v = vEgo - cruiseSpeedOffsetKph / msToKph;
    } else {
      v = vEgo;
    }
    final conv = isMetric ? msToKph : msToMph;
    final s = v * conv;
    return s > 0 ? s : 0;
  }

  /// raw cruise speed in kph (before unit conversion)
  double get _rawSetSpeed => vCruiseCluster != 0.0 ? vCruiseCluster : vCruiseDEPRECATED;

  /// is cruise actively set
  bool get isCruiseSet => _rawSetSpeed > 0 && _rawSetSpeed < setSpeedNA;

  /// cruise set speed in current unit
  double get setSpeed {
    final s = _rawSetSpeed;
    if (!isCruiseSet) return s;
    return isMetric ? s : s * kmToMile;
  }

  /// is cruise available (not -1)
  bool get isCruiseAvailable => _rawSetSpeed != -1;

  // -- helpers --

  /// largest number in [source]; 1 if it is missing or empty, as on the device
  double _largest(dynamic source) {
    if (source is! List || source.isEmpty) return 1.0;
    var best = 0.0;
    for (final e in source) {
      final v = (e as num?)?.toDouble() ?? 0.0;
      if (v > best) best = v;
    }
    return best;
  }

  /// Clear [target] and refill from [source] — reuses the existing list.
  void _fillDoubles(List<double> target, dynamic source) {
    target.clear();
    if (source is List) {
      for (final e in source) {
        target.add((e as num?)?.toDouble() ?? 0.0);
      }
    }
  }

  /// Clear [target] and refill from [source], ensuring exactly [n] elements.
  void _fillDoublesFixed(List<double> target, dynamic source, int n) {
    target.clear();
    if (source is List) {
      for (int i = 0; i < n && i < source.length; i++) {
        target.add((source[i] as num?)?.toDouble() ?? 0.0);
      }
    }
    while (target.length < n) {
      target.add(0.0);
    }
  }

  int _alertSizeFromString(dynamic v) {
    if (v is int) return v;
    if (v is String) {
      switch (v) {
        case 'none': return 0;
        case 'small': return 1;
        case 'mid': return 2;
        case 'full': return 3;
      }
    }
    return 0;
  }

  int _alertStatusFromString(dynamic v) {
    if (v is int) return v;
    if (v is String) {
      switch (v) {
        case 'normal': return 0;
        case 'userPrompt': return 1;
        case 'critical': return 2;
      }
    }
    return 0;
  }

}
