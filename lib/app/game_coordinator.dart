import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../domain/activity_region.dart';
import '../domain/coyote_protocol.dart';
import '../domain/ems_protocol.dart';
import '../domain/game_engine.dart';
import '../domain/game_mode.dart';
import '../domain/pose_sample.dart';
import '../services/ems_device.dart';
import '../services/coyote_device.dart';
import '../services/output_device.dart';
import '../services/simulation_device.dart';
import '../services/pose_camera.dart';
import '../services/settings_store.dart';

class GameCoordinator extends ChangeNotifier {
  GameCoordinator({
    GameEngine? engine,
    EmsDeviceController? ems,
    CoyoteDeviceController? coyote,
    OutputDeviceController? output,
    bool enableEms = false,
    PoseCamera Function(int Function())? cameraFactory,
    SettingsStore? store,
    Future<void> Function(bool)? keepAwake,
    bool autoTick = true,
  }) : _store = store ?? LocalSettingsStore(),
       _keepAwake =
           keepAwake ?? ((enabled) => WakelockPlus.toggle(enable: enabled)) {
    final outputEnabled =
        enableEms || ems != null || coyote != null || output != null;
    this.output = outputEnabled
        ? (output ?? OutputDeviceController(yokonex: ems, coyote: coyote))
        : null;
    this.engine =
        engine ?? GameEngine(sink: this.output ?? MemoryTriggerSink());
    camera =
        (cameraFactory ??
        ((readEpoch) =>
            MlKitPoseCamera(readEpoch: readEpoch)))(() => this.engine.epoch);
    camera.addListener(_cameraChanged);
    this.engine.addListener(_engineChanged);
    this.output?.addListener(_outputChanged);
    this.output?.onFault = _outputFault;
    if (autoTick) {
      _timer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => this.engine.tick(),
      );
    }
  }

  late final GameEngine engine;
  final GameModeSession modeSession = GameModeSession();
  late final OutputDeviceController? output;
  EmsDeviceController? get ems => output?.yokonex;
  CoyoteDeviceController? get coyote => output?.coyote;
  SimulationOutputController? get simulation => output?.simulation;
  OutputDeviceType get outputDeviceType =>
      output?.selected ?? OutputDeviceType.yokonex;
  late final PoseCamera camera;
  final SettingsStore _store;
  final Future<void> Function(bool) _keepAwake;
  Timer? _timer;
  ActivityRegion? region;
  RegionMode drawingMode = RegionMode.freehand;
  PoseSample? sample;
  bool loading = true;
  bool editing = false;
  bool _disposed = false;
  bool _foreground = true;
  bool _awake = false;
  GamePhase _lastPhase = GamePhase.ready;
  PoseFrame? _lastFrame;
  String? _lastCameraError;
  String? notice;
  int noticeVersion = 0;
  Future<void> _wakeChanges = Future.value();

  bool get canStart =>
      !loading &&
      !editing &&
      camera.ready &&
      (!engine.config.mode.requiresRegion || region != null) &&
      (output?.readyToOutput ?? true) &&
      engine.canStart;
  bool get canResume =>
      camera.ready && (output?.readyToOutput ?? true) && engine.canResume;

  ActivityRegion? get displayRegion => modeSession.effectiveRegion(
    region,
    engine.elapsed,
    engine.config.duration,
  );

  Rect? get obstacle => engine.config.mode == SafetyGameMode.dodge
      ? modeSession.obstacleAt(engine.elapsed)
      : null;

  (ActivityRegion, ActivityRegion)? get dualZones =>
      engine.config.mode == SafetyGameMode.dualZone
      ? modeSession.dualZones(region)
      : null;

  CustomPoseTemplate? get customPoseTemplate =>
      engine.config.mode == SafetyGameMode.customPose
      ? modeSession.customPoseTemplate
      : null;

  Future<void> initialize() async {
    SavedSetup setup;
    try {
      setup = await _store.load();
    } catch (_) {
      setup = const SavedSetup();
      _showNotice('本机设置读取失败');
    }
    if (_disposed) return;
    engine.configure(setup.config);
    _resetModeSession();
    ems?.configure(setup.emsConfig);
    coyote?.configure(setup.coyoteConfig);
    simulation?.configure(setup.simulationConfig);
    if (output != null) output!.selected = setup.outputDeviceType;
    // 仅选择原有 Yokonex 时申请蓝牙权限，选择郊狼不会弹出无关权限。
    if (outputDeviceType == OutputDeviceType.yokonex) {
      await ems?.requestPermissions();
    }
    if (_disposed) return;
    region = setup.region;
    drawingMode = region?.mode ?? RegionMode.freehand;
    loading = false;
    if (_foreground) await camera.initialize(preferredCameraId: setup.cameraId);
    if (_disposed) return;
    if (setup.cameraId != camera.cameraId) region = null;
    engine.invalidateObservation();
    notifyListeners();
  }

  void _cameraChanged() {
    if (_disposed) return;
    final frame = camera.frame;
    if (frame != null &&
        frame != _lastFrame &&
        frame.epoch == engine.epoch &&
        _foreground) {
      _lastFrame = frame;
      sample = frame.sample;
      final observation = editing
          ? const ModeObservation(TrackingStatus.waiting)
          : modeSession.evaluate(
              frame.sample,
              region,
              engine.liveElapsed,
              engine.config.duration,
            );
      engine.acceptObservation(
        observation.status,
        epoch: frame.epoch,
        side: observation.side,
        reason: _triggerReason(observation),
        forceDirectional: observation.forceDirectional,
      );
    }
    if (camera.error != null && camera.error != _lastCameraError) {
      _lastCameraError = camera.error;
      sample = null;
      engine.pause(PauseReason.cameraFault);
    } else if (camera.error == null) {
      _lastCameraError = null;
    }
    notifyListeners();
  }

  void _engineChanged() {
    if (_disposed) return;
    final running = engine.phase == GamePhase.running;
    if (_awake != running) {
      _awake = running;
      _wakeChanges = _wakeChanges.then((_) => _keepAwake(running)).catchError((
        Object _,
      ) {
        if (!_disposed && running && engine.phase == GamePhase.running) {
          _showNotice('保持亮屏失败，请重试');
          engine.pause(PauseReason.manual);
        }
      });
    }
    if (engine.phase == GamePhase.finished &&
        _lastPhase != GamePhase.finished) {
      unawaited(camera.suspend());
    }
    if (_lastPhase == GamePhase.running &&
        engine.phase != GamePhase.running &&
        output != null) {
      unawaited(output!.stop().catchError((Object _) {}));
    }
    _lastPhase = engine.phase;
    notifyListeners();
  }

  void _outputChanged() {
    if (!_disposed) notifyListeners();
  }

  void _outputFault(String message) {
    if (_disposed) return;
    _showNotice(message);
    if (engine.phase == GamePhase.running) {
      engine.pause(PauseReason.outputFault);
    }
  }

  void setDrawingMode(RegionMode mode) {
    if (engine.phase != GamePhase.ready) return;
    drawingMode = mode;
    notifyListeners();
  }

  void beginDrawing() {
    if (engine.phase != GamePhase.ready) return;
    editing = true;
    engine.invalidateObservation();
  }

  void endDrawing(ActivityRegion? value) {
    editing = false;
    if (value != null) {
      region = value;
      unawaited(_save());
    }
    engine.invalidateObservation();
  }

  void clearRegion() {
    if (engine.phase != GamePhase.ready) return;
    region = null;
    sample = null;
    engine.invalidateObservation();
    unawaited(_save());
  }

  void updateConfig(GameConfig value) {
    final modeChanged = engine.config.mode != value.mode;
    engine.configure(value);
    if (modeChanged) {
      _resetModeSession();
      engine.invalidateObservation();
    }
    unawaited(_save());
  }

  void updateGameMode(SafetyGameMode mode) {
    if (engine.phase != GamePhase.ready || engine.config.mode == mode) return;
    updateConfig(engine.config.copyWith(mode: mode));
  }

  void updateRedLightSettings(RedLightSettings settings) {
    if (engine.phase != GamePhase.ready || !settings.isValid) return;
    updateConfig(engine.config.copyWith(redLightSettings: settings));
    _resetModeSession();
  }

  void updateCustomPoseSettings(CustomPoseSettings settings) {
    if (engine.phase != GamePhase.ready || !settings.isValid) return;
    updateConfig(engine.config.copyWith(customPoseSettings: settings));
    _resetModeSession();
  }

  void updateEmsConfig(EmsConfig value) {
    if (engine.phase != GamePhase.ready || ems == null) return;
    ems!.configure(value);
    unawaited(_save());
  }

  void updateCoyoteConfig(CoyoteConfig value) {
    if (engine.phase != GamePhase.ready || coyote == null) return;
    coyote!.configure(value);
    unawaited(_save());
  }

  void updateSimulationConfig(CoyoteConfig value) {
    if (engine.phase != GamePhase.ready || simulation == null) return;
    simulation!.configure(value);
    unawaited(_save());
  }

  Future<void> updateOutputDeviceType(OutputDeviceType value) async {
    if (engine.phase != GamePhase.ready || output == null) return;
    await output!.select(value);
    if (value == OutputDeviceType.yokonex) await ems?.requestPermissions();
    await _save();
  }

  Future<void> emergencyStop() async {
    if (engine.phase == GamePhase.running) engine.pause(PauseReason.manual);
    await output?.emergencyStop();
    _showNotice('已立即停止全部设备输出');
  }

  Future<void> switchCamera() async {
    if (engine.phase != GamePhase.ready ||
        !camera.canSwitch ||
        camera.initializing) {
      return;
    }
    clearRegion();
    await camera.switchCamera();
    if (!_disposed) await _save();
  }

  Future<void> retryCamera() async {
    engine.pause(PauseReason.cameraFault);
    sample = null;
    await camera.initialize();
  }

  void start() {
    if (!canStart) return;
    _resetModeSession();
    engine.start();
  }

  void pause() => engine.pause(PauseReason.manual);
  void resume() {
    if (canResume) engine.resume();
  }

  void finish() => engine.finish();

  Future<void> playAgain() async {
    sample = null;
    _lastFrame = null;
    engine.reset();
    _resetModeSession();
    await camera.initialize();
  }

  Future<void> setForeground(bool foreground) async {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      editing = false;
      sample = null;
      engine.pause(PauseReason.background);
      await output?.emergencyStop();
      await camera.suspend();
    } else if (!loading && engine.phase != GamePhase.finished) {
      await camera.initialize();
    }
  }

  Future<void> _save() async {
    try {
      await _store.save(
        SavedSetup(
          config: engine.config,
          region: region,
          cameraId: camera.cameraId,
          emsConfig: ems?.config ?? const EmsConfig(),
          outputDeviceType: outputDeviceType,
          coyoteConfig: coyote?.config ?? const CoyoteConfig(),
          simulationConfig: simulation?.config ?? const CoyoteConfig(),
        ),
      );
    } catch (_) {
      _showNotice('设置保存失败，本次仍可继续');
    }
  }

  void _showNotice(String value) {
    if (_disposed) return;
    notice = value;
    noticeVersion++;
    notifyListeners();
  }

  TriggerReason? _triggerReason(ModeObservation observation) {
    if (observation.status == TrackingStatus.absent) {
      return TriggerReason.absent;
    }
    if (observation.status != TrackingStatus.outside &&
        observation.status != TrackingStatus.incomplete) {
      return null;
    }
    return switch (observation.violation) {
      ModeViolation.boundary => TriggerReason.outside,
      ModeViolation.movement => TriggerReason.movement,
      ModeViolation.pose => TriggerReason.pose,
      ModeViolation.obstacle => TriggerReason.obstacle,
      ModeViolation.balance => TriggerReason.balance,
      ModeViolation.wrongZone => TriggerReason.wrongZone,
      ModeViolation.customPose => TriggerReason.customPose,
    };
  }

  void _resetModeSession() {
    modeSession.reset(
      engine.config.mode,
      redLight: engine.config.redLightSettings,
      customPose: engine.config.customPoseSettings,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    engine.removeListener(_engineChanged);
    output?.removeListener(_outputChanged);
    output?.onFault = null;
    camera.removeListener(_cameraChanged);
    camera.dispose();
    engine.dispose();
    final deviceOutput = output;
    if (deviceOutput != null) {
      unawaited(
        deviceOutput.disconnectAll().whenComplete(deviceOutput.dispose),
      );
    }
    unawaited(
      _wakeChanges.then((_) => _keepAwake(false)).catchError((Object _) {}),
    );
    super.dispose();
  }
}
