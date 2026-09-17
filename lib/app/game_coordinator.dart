import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../domain/activity_region.dart';
import '../domain/ems_protocol.dart';
import '../domain/game_engine.dart';
import '../domain/pose_sample.dart';
import '../services/ems_device.dart';
import '../services/pose_camera.dart';
import '../services/settings_store.dart';

class GameCoordinator extends ChangeNotifier {
  GameCoordinator({
    GameEngine? engine,
    EmsDeviceController? ems,
    bool enableEms = false,
    PoseCamera Function(int Function())? cameraFactory,
    SettingsStore? store,
    Future<void> Function(bool)? keepAwake,
    bool autoTick = true,
  }) : ems = enableEms ? (ems ?? EmsDeviceController()) : ems,
       _store = store ?? LocalSettingsStore(),
       _keepAwake =
           keepAwake ?? ((enabled) => WakelockPlus.toggle(enable: enabled)) {
    this.engine = engine ?? GameEngine(sink: this.ems ?? MemoryTriggerSink());
    camera =
        (cameraFactory ??
        ((readEpoch) =>
            MlKitPoseCamera(readEpoch: readEpoch)))(() => this.engine.epoch);
    camera.addListener(_cameraChanged);
    this.engine.addListener(_engineChanged);
    this.ems?.addListener(_emsChanged);
    this.ems?.onFault = _emsFault;
    if (autoTick) {
      _timer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => this.engine.tick(),
      );
    }
  }

  late final GameEngine engine;
  final EmsDeviceController? ems;
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
      region != null &&
      (ems?.readyToOutput ?? true) &&
      engine.canStart;
  bool get canResume =>
      camera.ready && (ems?.readyToOutput ?? true) && engine.canResume;

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
    ems?.configure(setup.emsConfig);
    // 蓝牙权限在应用启动阶段申请，避免首次扫描紧接权限弹窗读取到旧状态。
    await ems?.requestPermissions();
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
      engine.acceptObservation(
        editing ? TrackingStatus.waiting : frame.sample.classify(region),
        epoch: frame.epoch,
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
        ems != null) {
      unawaited(ems!.stop().catchError((Object _) {}));
    }
    _lastPhase = engine.phase;
    notifyListeners();
  }

  void _emsChanged() {
    if (!_disposed) notifyListeners();
  }

  void _emsFault(String message) {
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
    engine.configure(value);
    unawaited(_save());
  }

  void updateEmsConfig(EmsConfig value) {
    if (engine.phase != GamePhase.ready || ems == null) return;
    ems!.configure(value);
    unawaited(_save());
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
    if (canStart) engine.start();
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
    await camera.initialize();
  }

  Future<void> setForeground(bool foreground) async {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      editing = false;
      sample = null;
      engine.pause(PauseReason.background);
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

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    engine.removeListener(_engineChanged);
    ems?.removeListener(_emsChanged);
    ems?.onFault = null;
    camera.removeListener(_cameraChanged);
    camera.dispose();
    engine.dispose();
    final output = ems;
    if (output != null) {
      unawaited(output.disconnect().whenComplete(output.dispose));
    }
    unawaited(
      _wakeChanges.then((_) => _keepAwake(false)).catchError((Object _) {}),
    );
    super.dispose();
  }
}
