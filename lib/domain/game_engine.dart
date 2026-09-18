import 'package:flutter/foundation.dart';

import 'game_mode.dart';
import 'pose_sample.dart';

class GameConfig {
  const GameConfig({
    this.duration = const Duration(minutes: 5),
    this.startCountdown = const Duration(seconds: 5),
    this.mode = SafetyGameMode.classic,
  });

  final Duration duration;
  // 开始游戏后、正式进入判定前的准备倒计时；0 表示不倒计时直接开始。
  final Duration startCountdown;
  final SafetyGameMode mode;

  bool get isValid =>
      duration >= const Duration(seconds: 1) &&
      duration <= const Duration(hours: 24) &&
      startCountdown >= Duration.zero &&
      startCountdown <= const Duration(seconds: 30);

  Map<String, Object> toJson() => {
    'durationSeconds': duration.inSeconds,
    'startCountdownSeconds': startCountdown.inSeconds,
    'mode': mode.name,
  };

  factory GameConfig.fromJson(Map<String, dynamic> json) {
    final config = GameConfig(
      duration: Duration(seconds: json['durationSeconds'] as int),
      startCountdown: Duration(seconds: json['startCountdownSeconds'] as int),
      mode: SafetyGameMode.values.byName(
        json['mode'] as String? ?? SafetyGameMode.classic.name,
      ),
    );
    if (!config.isValid) throw const FormatException('游戏参数无效');
    return config;
  }
}

enum GamePhase { ready, running, paused, finished }

enum PauseReason { manual, background, cameraFault, outputFault }

enum TriggerReason {
  outside,
  absent,
  movement,
  pose,
  obstacle,
  balance,
  wrongZone,
}

class TriggerEvent {
  const TriggerEvent({
    required this.sessionId,
    required this.sequence,
    required this.elapsed,
    required this.reason,
    this.side = TriggerSide.unknown,
    this.forceDirectional = false,
    this.recoveredAt,
  });
  final String sessionId;
  final int sequence;
  final Duration elapsed;
  final TriggerReason reason;
  final TriggerSide side;
  final bool forceDirectional;
  final Duration? recoveredAt;

  Duration durationUntil(Duration sessionDuration) {
    final end = recoveredAt ?? sessionDuration;
    return end > elapsed ? end - elapsed : Duration.zero;
  }

  TriggerEvent copyWith({Duration? recoveredAt}) => TriggerEvent(
    sessionId: sessionId,
    sequence: sequence,
    elapsed: elapsed,
    reason: reason,
    side: side,
    forceDirectional: forceDirectional,
    recoveredAt: recoveredAt ?? this.recoveredAt,
  );
}

class GameSessionStats {
  const GameSessionStats({
    required this.outsideCount,
    required this.absentCount,
    required this.leftCount,
    required this.rightCount,
    required this.bothCount,
    required this.abnormalDuration,
    required this.longestSafeDuration,
  });

  factory GameSessionStats.from(
    List<TriggerEvent> events,
    Duration sessionDuration,
  ) {
    var outsideCount = 0;
    var absentCount = 0;
    var leftCount = 0;
    var rightCount = 0;
    var bothCount = 0;
    var abnormal = Duration.zero;
    var longestSafe = Duration.zero;
    var cursor = Duration.zero;
    for (final event in events) {
      if (event.reason == TriggerReason.absent) {
        absentCount++;
      } else {
        outsideCount++;
      }
      switch (event.side) {
        case TriggerSide.left:
          leftCount++;
        case TriggerSide.right:
          rightCount++;
        case TriggerSide.both:
          bothCount++;
        case TriggerSide.unknown:
          break;
      }
      final start = event.elapsed < Duration.zero
          ? Duration.zero
          : event.elapsed > sessionDuration
          ? sessionDuration
          : event.elapsed;
      if (start > cursor && start - cursor > longestSafe) {
        longestSafe = start - cursor;
      }
      final rawEnd = event.recoveredAt ?? sessionDuration;
      final end = rawEnd < start
          ? start
          : rawEnd > sessionDuration
          ? sessionDuration
          : rawEnd;
      abnormal += end - start;
      if (end > cursor) cursor = end;
    }
    if (sessionDuration > cursor && sessionDuration - cursor > longestSafe) {
      longestSafe = sessionDuration - cursor;
    }
    return GameSessionStats(
      outsideCount: outsideCount,
      absentCount: absentCount,
      leftCount: leftCount,
      rightCount: rightCount,
      bothCount: bothCount,
      abnormalDuration: abnormal,
      longestSafeDuration: longestSafe,
    );
  }

  final int outsideCount;
  final int absentCount;
  final int leftCount;
  final int rightCount;
  final int bothCount;
  final Duration abnormalDuration;
  final Duration longestSafeDuration;
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
  GameSessionStats get stats => GameSessionStats.from(_events, elapsed);
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

  void acceptObservation(
    TrackingStatus status, {
    required int epoch,
    TriggerSide side = TriggerSide.unknown,
    TriggerReason? reason,
    bool forceDirectional = false,
  }) {
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
          if (!_triggering) {
            _trigger(status, side, reason, forceDirectional);
          }
        // 跟踪不完整（关节被遮挡）给一段豁免时间；已经在触发中则不豁免，
        // 不能靠遮挡关节点中途逃避判定。超过豁免时间仍未恢复才按越界触发。
        case TrackingStatus.incomplete:
          _insideStart = null;
          if (_triggering) {
            _incompleteStart = null;
          } else {
            _incompleteStart ??= now;
            if (now - _incompleteStart! >= incompleteGrace) {
              _trigger(status, side, reason, forceDirectional);
            }
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
  void _trigger(
    TrackingStatus status,
    TriggerSide side,
    TriggerReason? reason,
    bool forceDirectional,
  ) {
    final event = TriggerEvent(
      sessionId: _sessionId,
      sequence: _events.length + 1,
      elapsed: elapsed,
      reason:
          reason ??
          (status == TrackingStatus.absent
              ? TriggerReason.absent
              : TriggerReason.outside),
      side: side,
      forceDirectional: forceDirectional,
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
    _closeActiveTrigger();
    _triggering = false;
    _insideStart = null;
    sink.reset();
  }

  void pause(PauseReason reason) {
    _advance(_now());
    if (phase == GamePhase.finished) return;
    _closeActiveTrigger();
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
    _closeActiveTrigger();
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

  void _closeActiveTrigger() {
    if (!_triggering || _events.isEmpty || _events.last.recoveredAt != null) {
      return;
    }
    _events[_events.length - 1] = _events.last.copyWith(recoveredAt: elapsed);
  }
}
