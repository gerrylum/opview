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

/// m/s², opendbc ACCELERATION_DUE_TO_GRAVITY
const gravity = 9.81;

/// how the wheel icon is tinted while MADS steers an angle-capable Rivian
enum LateralMode { angle, torque }

/// the app's speed limit setting: auto shows it once the comma has sent a limit
/// this drive, always shows it (dashes without data), off never shows it
enum SpeedLimitDisplay { auto, always, off }

// -- state --

/// lateral acceleration (m/s²) that fills the lane guard band: the Rivian tune's limit
const laneGuardFullScale = 0.4;

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

  // carState, for the Detailed layout
  double aEgo = 0.0;
  double steeringRateDeg = 0.0;
  double steeringTorque = 0.0;   // driver torque, in the car's own CAN units
  bool gasPressed = false;
  bool brakePressed = false;
  String gearShifter = '';
  bool cruiseEnabled = false;

  // carControl.actuators.steeringAngleDeg: the angle openpilot is asking for. Cars that
  // steer by torque alone leave it at 0; the Rivian branches always fill it in
  double targetSteeringAngleDeg = 0.0;

  // selfdriveState
  bool enabled = false;
  bool engageable = false;
  bool experimentalMode = false;
  String alertText1 = '';
  String alertText2 = '';
  int alertSize = 0;     // 0=none, 1=small, 2=mid, 3=full
  int alertStatus = 0;   // 0=normal, 1=userPrompt, 2=critical
  String openpilotState = '';
  String personality = '';  // relaxed / standard / aggressive

  // controlsState
  double vCruiseDEPRECATED = 0.0;
  double curvature = 0.0;
  double desiredCurvature = 0.0;
  String lateralControlKind = '';  // which lateralControlState is set, e.g. 'torqueState'
  bool lateralSaturated = false;

  // carOutput.actuatorsOutput.torque, -1..1
  double torqueOutput = 0.0;

  // driverMonitoringState
  /// connected, but no telemetry for a moment: the overlay is showing old data
  bool dataStale = false;

  bool dmSeen = false;
  bool dmActive = false;             // camera-based monitoring is running
  bool dmFaceDetected = false;
  double dmAwarenessPercent = 100.0;
  double dmRotationDeg = 90.0;       // which way the head is turned, smoothed; 90 = straight ahead
  String dmPolicy = '';              // which monitoring policy is in charge, e.g. 'vision'

  // modelV2.meta.disengagePredictions: largest value of each list (the comma sends
  // them on branches whose webrtcd includes them)
  bool confidenceSeen = false;
  double brakeDisengageProb = 0.0;
  double steerOverrideProb = 0.0;
  double confidenceFiltered = 1.0;  // smoothed, 0..1

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
  int calPerc = 0;
  List<double> calibHeight = [];

  // radarState
  Map<String, dynamic>? leadOne;
  Map<String, dynamic>? leadTwo;

  /// when the lead last had a radar match; radard re-matches 20 times a second and
  /// the match drops out briefly, so the Detailed badge holds it for [leadRadarHold]
  DateTime? leadRadarSeenAt;
  static const leadRadarHold = Duration(seconds: 1);

  /// time source, replaceable in tests
  DateTime Function() clock = DateTime.now;

  // longitudinalPlan
  bool allowThrottle = true;

  // throttle blend — smooth fade between throttle/no-throttle path colors
  // first-order filter: tau=0.25s, updated at modelV2 rate (~20Hz)
  double throttleBlend = 1.0; // 1.0 = full throttle colors, 0.0 = no-throttle

  // deviceState / roadCameraState — for camera intrinsics lookup
  String deviceType = '';

  // deviceState, for the Detailed layout's device health
  bool deviceSeen = false;
  double cpuTempC = 0.0;        // hottest core
  int memoryUsagePercent = 0;
  double freeSpacePercent = 100.0;
  String networkStrength = 'unknown';  // unknown / poor / moderate / good / great
  double powerDrawW = 0.0;
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

  /// a speed limit has arrived at some point since connecting
  bool speedLimitSeen = false;

  // liveMapDataSP — speeds in m/s, distance in m
  bool speedLimitAheadValid = false;
  double speedLimitAhead = 0.0;
  double speedLimitAheadDistance = 0.0;
  String roadName = '';

  // carParams / carControl / carOutput — for the Rivian angle/torque wheel tint
  String brand = '';
  int carFlags = 0;

  /// the car's measured maximum lateral acceleration (carParams.maxLateralAccel, 2.5 m/s² on a
  /// Rivian): full scale on the torque bar. webrtcd sends it with the params once it has it
  double maxLateralAccel = defaultMaxLatAccel;

  /// road roll from vehicleParameters (radians, positive is the road leaning right); the torque
  /// bar takes out what the camber alone asks for
  double roll = 0.0;
  bool latActive = false;
  bool longActive = false;

  /// openpilot has driven the throttle and brakes at least once (carControl.longActive)
  bool longActiveSeen = false;

  // Navigate: where the truck is (gpsLocationExternal), navd's route (navRoute) and next turn (navInstruction)
  bool gpsSeen = false;
  bool gpsFix = false;
  double gpsLat = 0.0, gpsLon = 0.0;
  double gpsBearing = 0.0;   // degrees clockwise from north, held while nearly stopped
  double gpsSpeed = 0.0;     // m/s
  double gpsAccuracy = 0.0;  // m

  bool navValid = false;     // navd has a route and sent an instruction
  String navPrimary = '', navSecondary = '';
  String navManeuverType = '', navManeuverModifier = '';
  double navManeuverDistance = 0.0, navDistanceRemaining = 0.0, navTimeRemaining = 0.0;
  DateTime? navInstructionAt;

  /// navd's route as (lat, lon), thinned by webrtcd; empty without a route
  List<(double, double)> navRoute = const [];

  /// the comma's Navigation setting (navd only runs with it on); null before opviewParams has said
  bool? navigationEnabled;

  /// where navd is routing to (the comma's NavDestination), or null
  (double, double)? navDestination;

  /// the comma's answer to the last destination we sent: null while none, '' when it took it
  String? navDestinationError;

  // carControlSP.laneGuard — EVPilot's lane guard (comma: selfdrive/controls/lib/lane_guard.py).
  // Comma branches without it never send it, and the torque bar stays plain
  bool laneGuardSeen = false;
  bool laneGuardEnabled = false;   // the LaneGuardEnabled setting
  bool laneGuardActive = false;    // guarding: openpilot steering, the driver not, above 8 m/s
  String laneGuardPaused = 'none'; // none / driverSteering / laneChange / slow
  double laneGuardCurvature = 0.0; // 1/m added to the model's, positive pushes right
  String laneGuardSource = 'none'; // what the push is away from: none / laneLine / roadEdge
  bool laneGuardLeftLine = false, laneGuardRightLine = false;  // lane lines guarded
  bool laneGuardLeftEdge = false, laneGuardRightEdge = false;  // road edges guarded
  double laneGuardLeftGap = 0.0, laneGuardRightGap = 0.0;      // m, body to the nearest guarded one

  /// the comma's own answer to whether openpilot runs the throttle and brakes
  /// (opviewParams OpenpilotLongitudinalControl); null on comma branches that do not send it
  bool? opLongitudinalControl;

  /// openpilot runs the throttle and brakes. Current openpilot has no Chill or Experimental
  /// mode: the path takes the acceleration colours and the wide camera is used at low speed
  /// whenever this is true (model_renderer.py, augmented_road_view.py). Without the comma's
  /// answer: experimental mode on older branches, or openpilot having braked or accelerated
  bool get longitudinalControl => opLongitudinalControl ?? (experimentalMode || longActiveSeen);
  double accelCommand = 0.0;  // carControl.actuators.accel, m/s^2
  int _zeroTorqueCount = zeroTorqueHold;
  LateralMode? lateralMode;

  // the last ten seconds of lateral and longitudinal acceleration, one sample per
  // modelV2 (about 20 a second), oldest first; for the Detailed layout's traces
  final latAccelWantHistory = <double>[];
  final latAccelGotHistory = <double>[];
  final accelCommandHistory = <double>[];
  final accelActualHistory = <double>[];

  // active camera: 'road' or 'wideRoad' (wide at low speed under openpilot longitudinal control)
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
    aEgo = (data['aEgo'] as num?)?.toDouble() ?? 0.0;
    steeringRateDeg = (data['steeringRateDeg'] as num?)?.toDouble() ?? 0.0;
    steeringTorque = (data['steeringTorque'] as num?)?.toDouble() ?? 0.0;
    gasPressed = data['gasPressed'] as bool? ?? false;
    brakePressed = data['brakePressed'] as bool? ?? false;
    gearShifter = data['gearShifter'] as String? ?? '';
    final cruise = data['cruiseState'];
    cruiseEnabled = cruise is Map && cruise['enabled'] == true;
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
    personality = data['personality'] as String? ?? '';

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
    final latState = (lat is Map && lat.isNotEmpty) ? lat.values.first : null;
    lateralSaturated = latState is Map && latState['saturated'] == true;
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

    // confidence (mici confidence_ball.py)
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

    _recordHistory();
    _notify();  // data-driven: render on modelV2 arrival
  }

  void applyLiveCalibration(Map<String, dynamic> data) {
    _fillDoubles(rpyCalib, data['rpyCalib']);
    _fillDoubles(wideFromDeviceEuler, data['wideFromDeviceEuler']);
    calStatus = data['calStatus'] as String? ?? '';
    calPerc = (data['calPerc'] as num?)?.toInt() ?? calPerc;
    _fillDoubles(calibHeight, data['height']);
    // no notify — picked up on next modelV2
  }

  void applyRadarState(Map<String, dynamic> data) {
    leadOne = data['leadOne'] as Map<String, dynamic>?;
    leadTwo = data['leadTwo'] as Map<String, dynamic>?;
    if (isLeadPresent(leadOne) && leadOne!['radar'] == true) leadRadarSeenAt = clock();
    // no notify — picked up on next modelV2
  }

  void applyLongitudinalPlan(Map<String, dynamic> data) {
    allowThrottle = data['allowThrottle'] as bool? ?? true;
    // no notify — picked up on next modelV2
  }

  void applyDeviceState(Map<String, dynamic> data) {
    deviceType = data['deviceType'] as String? ?? '';
    started = data['started'] as bool? ?? started;
    deviceSeen = true;
    final temps = data['cpuTempC'];
    if (temps is List && temps.isNotEmpty) {
      cpuTempC = temps.map((t) => (t as num?)?.toDouble() ?? 0.0).reduce(math.max);
    }
    memoryUsagePercent = (data['memoryUsagePercent'] as num?)?.toInt() ?? memoryUsagePercent;
    freeSpacePercent = (data['freeSpacePercent'] as num?)?.toDouble() ?? freeSpacePercent;
    networkStrength = data['networkStrength'] as String? ?? 'unknown';
    powerDrawW = (data['powerDrawW'] as num?)?.toDouble() ?? powerDrawW;
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
    final maxLat = (data['CarMaxLateralAccel'] as num?)?.toDouble();
    if (maxLat != null && maxLat.isFinite && maxLat > 0.1) maxLateralAccel = maxLat;
    final navOn = data['NavigationEnabled'];
    if (navOn is bool) navigationEnabled = navOn;
    if (data.containsKey('NavDestination')) {
      final d = data['NavDestination'];
      navDestination = d is Map && d['latitude'] is num && d['longitude'] is num
          ? ((d['latitude'] as num).toDouble(), (d['longitude'] as num).toDouble())
          : null;
    }
    final opLong = data['OpenpilotLongitudinalControl'];
    if (opLong is bool) opLongitudinalControl = opLong;
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
    if ((speedLimitValid && speedLimit > 0) || (speedLimitLastValid && speedLimitLast > 0)) speedLimitSeen = true;
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
    final maxLat = (data['maxLateralAccel'] as num?)?.toDouble();
    if (maxLat != null && maxLat.isFinite && maxLat > 0.1) maxLateralAccel = maxLat;
  }

  /// vehicleParameters (liveParameters on older openpilot): the road's roll, for the torque bar
  void applyVehicleParameters(Map<String, dynamic> data) {
    roll = (data['roll'] as num?)?.toDouble() ?? 0.0;
    // no notify — picked up on next modelV2
  }

  /// mici driver_state.py get_driver_data + _update_state
  void applyDriverMonitoringState(Map<String, dynamic> data) {
    dmSeen = true;
    var pitch = 0.0, yaw = 0.0;
    final vision = data['visionPolicyState'];
    if (vision is Map) {
      // current openpilot: one state per monitoring policy
      dmActive = data['activePolicy'] == 'vision';
      dmPolicy = data['activePolicy'] as String? ?? '';
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
    longActive = data['longActive'] as bool? ?? false;
    if (longActive) longActiveSeen = true;
    accelCommand = (data['actuators']?['accel'] as num?)?.toDouble() ?? 0.0;
    targetSteeringAngleDeg = (data['actuators']?['steeringAngleDeg'] as num?)?.toDouble() ?? 0.0;
  }

  void applyGps(Map<String, dynamic> data) {
    final lat = (data['latitude'] as num?)?.toDouble(), lon = (data['longitude'] as num?)?.toDouble();
    final fix = data['hasFix'] as bool? ?? (lat != null && lon != null && (lat != 0 || lon != 0));
    gpsSeen = true;
    gpsFix = fix && lat != null && lon != null;
    if (!gpsFix) return;
    gpsLat = lat!;
    gpsLon = lon!;
    gpsSpeed = (data['speed'] as num?)?.toDouble() ?? 0.0;
    gpsAccuracy = (data['horizontalAccuracy'] as num?)?.toDouble() ?? 0.0;
    // the bearing wanders when stopped: keep the last one below walking speed
    final bearing = (data['bearingDeg'] as num?)?.toDouble();
    if (bearing != null && gpsSpeed > 1.5) gpsBearing = bearing;
  }

  void applyNavInstruction(Map<String, dynamic> data, {required bool valid}) {
    navValid = valid;
    navInstructionAt = DateTime.now();
    if (!valid) return;
    navPrimary = data['maneuverPrimaryText'] as String? ?? '';
    navSecondary = data['maneuverSecondaryText'] as String? ?? '';
    navManeuverType = data['maneuverType'] as String? ?? '';
    navManeuverModifier = data['maneuverModifier'] as String? ?? '';
    navManeuverDistance = (data['maneuverDistance'] as num?)?.toDouble() ?? 0.0;
    navDistanceRemaining = (data['distanceRemaining'] as num?)?.toDouble() ?? 0.0;
    navTimeRemaining = (data['timeRemaining'] as num?)?.toDouble() ?? 0.0;
  }

  /// [[lat, lon], ...] from webrtcd's opview_slim, or navd's own [{latitude, longitude}, ...]
  void applyNavRoute(Map<String, dynamic> data) {
    final out = <(double, double)>[];
    for (final c in (data['coordinates'] as List? ?? const [])) {
      if (c is List && c.length >= 2 && c[0] is num && c[1] is num) {
        out.add(((c[0] as num).toDouble(), (c[1] as num).toDouble()));
      } else if (c is Map && c['latitude'] is num && c['longitude'] is num) {
        out.add(((c['latitude'] as num).toDouble(), (c['longitude'] as num).toDouble()));
      }
    }
    navRoute = out;
  }

  void applyNavDestinationResult(Map<String, dynamic> data) {
    navDestinationError = data['ok'] == true ? '' : (data['error'] as String? ?? 'The comma refused the destination');
  }

  /// a route is being followed: the comma has a destination and navd sent a turn
  bool get navigating => navDestination != null && navValid;

  void applyCarControlSP(Map<String, dynamic> data) {
    final lg = data['laneGuard'];
    if (lg is! Map) return;
    laneGuardSeen = true;
    laneGuardEnabled = lg['enabled'] as bool? ?? false;
    laneGuardActive = lg['active'] as bool? ?? false;
    laneGuardPaused = lg['pausedReason'] as String? ?? 'none';
    laneGuardCurvature = (lg['curvature'] as num?)?.toDouble() ?? 0.0;
    laneGuardSource = lg['source'] as String? ?? 'none';
    laneGuardLeftLine = lg['leftLineGuarded'] as bool? ?? false;
    laneGuardRightLine = lg['rightLineGuarded'] as bool? ?? false;
    laneGuardLeftEdge = lg['leftEdgeGuarded'] as bool? ?? false;
    laneGuardRightEdge = lg['rightEdgeGuarded'] as bool? ?? false;
    laneGuardLeftGap = (lg['leftGap'] as num?)?.toDouble() ?? 0.0;
    laneGuardRightGap = (lg['rightGap'] as num?)?.toDouble() ?? 0.0;
  }

  /// the lane guard band and marks are on the torque bar: lane guard is on and openpilot steers
  bool get showsLaneGuard => laneGuardSeen && laneGuardEnabled && latActive;

  /// lane guard's push as a share of its limit, -1..1 (the Rivian tune's 0.4 m/s² is full);
  /// positive pushes right, the same way round as [torqueBarValue]
  double get laneGuardPush =>
      (laneGuardCurvature * vEgo * vEgo / laneGuardFullScale).clamp(-1.0, 1.0).toDouble();

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

  /// the radar's primary lead car, or null when there is none
  Map<String, dynamic>? get activeLead {
    final lead = leadOne;
    return isLeadPresent(lead) ? lead : null;
  }

  /// the lead has been matched to a radar track within the last [leadRadarHold]
  bool get leadRadarRecent {
    final seen = leadRadarSeenAt;
    return activeLead != null && seen != null && clock().difference(seen) <= leadRadarHold;
  }

  /// how openpilot is steering right now, or null when it is not steering.
  /// an angle-capable Rivian switches between the two while driving; other cars
  /// report the controller they use
  LateralMode? get steeringMode {
    if (!latActive) return null;
    if (lateralMode != null) return lateralMode;
    if (lateralControlKind == 'angleState') return LateralMode.angle;
    if (lateralControlKind == 'torqueState') return LateralMode.torque;
    return null;
  }

  /// steering effort for the Enhanced layout's torque bar, -1..1, worked out as the comma's own
  /// bar does (mici torque_bar.py). Angle and curvature control (every EVPilot Rivian: controlsd
  /// publishes angleState) have no torque to show, so it is estimated: the lateral acceleration
  /// the car is making, plus what it is still short of, less what the road's camber does on its
  /// own (faded in from 5 to 15 m/s, where roll is trustworthy), over the car's maximum
  double get torqueBarValue {
    if (lateralControlKind == 'angleState' || lateralControlKind == 'curvatureState') {
      if (!latActive) return 0.0;
      final v2 = vEgo * vEgo;
      final actual = curvature * v2;
      final desired = desiredCurvature * v2;
      final rollFade = ((vEgo - 5) / 10).clamp(0.0, 1.0);
      final rollCompensation = roll * gravity * rollFade;
      final value = (actual - rollCompensation + (desired - actual)) / maxLateralAccel;
      return value.clamp(-1.0, 1.0).toDouble();
    }
    return (-torqueOutput).clamp(-1.0, 1.0).toDouble();
  }

  /// speed conversion for the current unit
  double get speedConv => isMetric ? msToKph : msToMph;

  /// show the speed limit sign (speed_limit.py: SpeedLimitMode != off)
  bool get showSpeedLimit => paramsSeen && speedLimitMode != speedLimitModeOff;

  /// the speed limit sign or pill, under the app's speed limit setting; never while
  /// speed limits are turned off on the comma
  bool speedLimitVisible(SpeedLimitDisplay setting) {
    if (setting == SpeedLimitDisplay.off || !showSpeedLimit) return false;
    if (setting == SpeedLimitDisplay.always || speedLimitSeen) return true;
    return (speedLimitValid && speedLimit > 0) || (speedLimitLastValid && speedLimitLast > 0);
  }

  /// show the road name pill (road_name.py)
  /// the app's road name setting (AppSettings.showRoadName); the comma's own RoadNameToggle no longer decides
  bool roadNameEnabled = true;

  /// show the road name pill: turned on in the app, and the comma's maps have a name for this road
  bool get showRoadName => roadNameEnabled && roadName.isNotEmpty;

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

  /// how confident the driving model is that no takeover is coming, 0..1
  /// (confidence_ball.py): steering only counts steer overrides, cruise only
  /// counts brake disengages, engaged counts both
  double get confidenceTarget {
    switch (status) {
      case UIStatus.latOnly:
        return 1 - steerOverrideProb;
      case UIStatus.longOnly:
        return 1 - brakeDisengageProb;
      case UIStatus.disengaged:
      case UIStatus.engaged:
      case UIStatus.override_:
        return (1 - brakeDisengageProb) * (1 - steerOverrideProb);
    }
  }

  /// sideways acceleration openpilot wants and what the car is doing, m/s^2, from
  /// controlsState's curvatures; the same in angle and torque mode
  double get latAccelWant => desiredCurvature * vEgo * vEgo;
  double get latAccelGot => curvature * vEgo * vEgo;

  /// samples kept for the Detailed layout's traces: ten seconds at the model rate
  static const historyLength = 200;

  void _recordHistory() {
    void push(List<double> list, double v) {
      list.add(v.isFinite ? v : 0.0);
      if (list.length > historyLength) list.removeAt(0);
    }
    push(latAccelWantHistory, latActive ? latAccelWant : 0.0);
    push(latAccelGotHistory, latAccelGot);
    push(accelCommandHistory, longActive ? accelCommand : 0.0);
    push(accelActualHistory, aEgo);
  }

  // -- helpers --

  /// the largest number in a list, 0 for none
  double _largest(dynamic list) {
    var m = 0.0;
    if (list is List) {
      for (final v in list) {
        final d = (v as num?)?.toDouble() ?? 0.0;
        if (d > m) m = d;
      }
    }
    return m;
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

/// whether a radarState lead (leadOne/leadTwo) reports a car. Upstream
/// openpilot calls the flag `status`; newer cereal (comma four forks) renamed it
/// to `present`. Accept either.
bool isLeadPresent(Map<String, dynamic>? lead) =>
    lead != null && (lead['present'] == true || lead['status'] == true);
