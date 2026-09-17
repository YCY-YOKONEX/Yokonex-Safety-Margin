import 'package:flutter/foundation.dart';

import 'pose_sample.dart';

class GameConfig {
  const GameConfig({
    this.duration = const Duration(minutes: 5),
    this.startCountdown = const Duration(seconds: 5),
  });

  final Duration duration;
  // 开始游戏后、正式进入判定前的准备倒计时；0 表示不倒计时直接开始。
  final Duration startCountdown;

  bool get isValid =>
      duration >= const Duration(seconds: 1) &&
      duration <= const Duration(hours: 24) &&
      startCountdown >= Duration.zero &&
      startCountdown <= const Duration(seconds: 30);

  Map<String, Object> toJson() => {
    'durationSeconds': duration.inSeconds,
    'startCountdownSeconds': startCountdown.inSeconds,
  };

  factory GameConfig.fromJson(Map<String, dynamic> json) {
    final config = GameConfig(
      duration: Duration(seconds: json['durationSeconds'] as int),
      startCountdown: Duration(seconds: json['startCountdownSeconds'] as int),
    );
    if (!config.isValid) throw const FormatException('游戏参数无效');
    return config;
  }
}

enum GamePhase { ready, running, paused, finished }

enum PauseReason { manual, background, cameraFault, outputFault }

enum TriggerReason { outside, absent }

class TriggerEvent {
  const TriggerEvent({
    required this.sessionId,
    required this.sequence,
    required this.elapsed,
    required this.reason,
  });
  final String sessionId;
  final int sequence;
  final Duration elapsed;
  final TriggerReason reason;
}

/// 输出接口只接受事件；设备适配器由后续协议接入。
abstract interface class TriggerSink {
  void reset();
  void emit(TriggerEvent event);
}

class MemoryTriggerSink implements TriggerSink {
  final List<TriggerEvent> _events = [];
  List<TriggerEvent> get events => List.unmodifiable(_events);

  @override
  void reset() => _events.clear();

  @override
  void emit(TriggerEvent event) {
    if (_events.isNotEmpty && _events.last.sessionId != event.sessionId) {
      _events.clear();
    }
    _events.add(event);
  }
}

class GameEngine extends ChangeNotifier {
  GameEngine({required this.sink, Duration Function()? now}) {
    final stopwatch = Stopwatch()..start();
    _now = now ?? () => stopwatch.elapsed;
  }

  final TriggerSink sink;
  late final Duration Function() _now;
  static const frameTimeout = Duration(milliseconds: 1500);
  // 回到区域内需要持续这么久才算真正恢复，避免边缘抖动导致触发被单帧打断。
  static const recoveryConfirm = Duration(milliseconds: 400);
  // 跟踪不完整（转身、手臂遮挡关节点等）的豁免时间，超过这个时长仍未恢复才按越界触发。
  static const incompleteGrace = Duration(seconds: 1);
  GameConfig config = const GameConfig();
  GamePhase phase = GamePhase.ready;
  TrackingStatus tracking = TrackingStatus.waiting;
  PauseReason? pauseReason;
  Duration elapsed = Duration.zero;
  Duration? _lastTick;
  Duration? _lastObservation;
  Duration? _insideStart;
  Duration? _incompleteStart;
  bool _triggering = false;
  String _sessionId = '';
  int _sessionCounter = 0;
  int _epoch = 0;
  final List<TriggerEvent> _events = [];

  int get epoch => _epoch;
  List<TriggerEvent> get events => List.unmodifiable(_events);
  Duration get remaining => config.duration - elapsed;
  bool get triggering => _triggering;
  bool get _fresh =>
      _lastObservation != null && _now() - _lastObservation! < frameTimeout;
  // 开始/继续都不要求画面中已有人；恢复运行后立即按当时状态判定。
  bool get canStart => phase == GamePhase.ready && _fresh;
  bool get canResume => phase == GamePhase.paused && _fresh;

  void configure(GameConfig value) {
    if (phase != GamePhase.ready || !value.isValid) {
      throw StateError('只能在准备阶段设置有效参数');
    }
    config = value;
    notifyListeners();
  }

  void invalidateObservation() {
    _epoch++;
    tracking = TrackingStatus.waiting;
    _lastObservation = null;
    _resetTrigger();
    notifyListeners();
  }

  bool start() {
    if (!canStart) return false;
    _epoch++;
    _sessionId =
        '${DateTime.now().microsecondsSinceEpoch}-${++_sessionCounter}';
    _events.clear();
    sink.reset();
    elapsed = Duration.zero;
    _lastTick = _now();
    _lastObservation = _lastTick;
    _resetTrigger();
    phase = GamePhase.running;
    pauseReason = null;
    notifyListeners();
    return true;
  }

  void acceptObservation(TrackingStatus status, {required int epoch}) {
    if (epoch != _epoch || phase == GamePhase.finished) return;
    final now = _now();
    _advance(now);
    if (phase == GamePhase.finished) return;
    // 恢复帧不能掩盖中途断流；断流后必须先暂停，再手动继续。
    if (phase == GamePhase.running &&
        _lastObservation != null &&
        now - _lastObservation! >= frameTimeout) {
      pause(PauseReason.cameraFault);
      return;
    }
    _lastObservation = now;
    tracking = status;
    if (phase == GamePhase.running) {
      switch (status) {
        case TrackingStatus.outside:
        case TrackingStatus.absent:
          _insideStart = null;
          _incompleteStart = null;
          if (!_triggering) _trigger(status);
        // 跟踪不完整（关节被遮挡）给一段豁免时间；已经在触发中则不豁免，
        // 不能靠遮挡关节点中途逃避判定。超过豁免时间仍未恢复才按越界触发。
        case TrackingStatus.incomplete:
          _insideStart = null;
          if (_triggering) {
            _incompleteStart = null;
          } else {
            _incompleteStart ??= now;
            if (now - _incompleteStart! >= incompleteGrace) _trigger(status);
          }
        case TrackingStatus.inside:
          _incompleteStart = null;
          if (_triggering) {
            _insideStart ??= now;
            if (now - _insideStart! >= recoveryConfirm) _stopTrigger();
          }
        case TrackingStatus.waiting:
          pause(PauseReason.cameraFault);
          return;
      }
    }
    notifyListeners();
  }

  void tick() {
    final now = _now();
    _advance(now);
    if (phase == GamePhase.running) {
      // 无新图像属于摄像头故障，不能当作画面中无人继续触发。
      if (_lastObservation == null || now - _lastObservation! >= frameTimeout) {
        pause(PauseReason.cameraFault);
        return;
      }
    }
    notifyListeners();
  }

  void _advance(Duration now) {
    if (phase != GamePhase.running) return;
    elapsed += now - _lastTick!;
    _lastTick = now;
    if (elapsed >= config.duration) {
      elapsed = config.duration;
      _finish();
    }
  }

  /// 越界（或识别不到人）后立即触发，设备端持续输出直到确认回到区域内。
  void _trigger(TrackingStatus status) {
    final event = TriggerEvent(
      sessionId: _sessionId,
      sequence: _events.length + 1,
      elapsed: elapsed,
      reason: status == TrackingStatus.absent
          ? TriggerReason.absent
          : TriggerReason.outside,
    );
    try {
      sink.emit(event);
      _events.add(event);
      _triggering = true;
    } catch (_) {
      pause(PauseReason.outputFault);
    }
  }

  void _stopTrigger() {
    _triggering = false;
    _insideStart = null;
    sink.reset();
  }

  void pause(PauseReason reason) {
    _advance(_now());
    if (phase == GamePhase.finished) return;
    if (phase == GamePhase.running || phase == GamePhase.paused) {
      phase = GamePhase.paused;
      pauseReason = reason;
    }
    invalidateObservation();
  }

  bool resume() {
    if (!canResume) return false;
    _epoch++;
    _lastTick = _now();
    _lastObservation = _lastTick;
    _resetTrigger();
    phase = GamePhase.running;
    pauseReason = null;
    notifyListeners();
    return true;
  }

  void finish() {
    _advance(_now());
    _finish();
    notifyListeners();
  }

  void _finish() {
    phase = GamePhase.finished;
    _epoch++;
    _lastTick = null;
    _resetTrigger();
  }

  void reset() {
    phase = GamePhase.ready;
    elapsed = Duration.zero;
    pauseReason = null;
    _events.clear();
    sink.reset();
    invalidateObservation();
  }

  void _resetTrigger() {
    _triggering = false;
    _insideStart = null;
    _incompleteStart = null;
  }
}
