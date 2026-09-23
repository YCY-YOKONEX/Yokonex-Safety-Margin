import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../domain/coyote_protocol.dart';
import '../domain/game_engine.dart';
import '../domain/pose_sample.dart';

/// A completely local output adapter used to exercise the Safety Margin flow
/// without Bluetooth, WebSocket, or a physical device.
class SimulationPulse {
  const SimulationPulse({
    required this.startedAt,
    required this.channels,
    required this.intensity,
    required this.waveform,
    required this.duration,
    required this.untilRecovery,
    required this.isTest,
    this.event,
    this.endedAt,
    this.stopped = false,
  });

  final DateTime startedAt;
  final List<int> channels;
  final int intensity;
  final CoyoteWaveform waveform;
  final Duration duration;
  final bool untilRecovery;
  final bool isTest;
  final TriggerEvent? event;
  final DateTime? endedAt;
  final bool stopped;

  SimulationPulse copyWith({DateTime? endedAt, bool? stopped}) =>
      SimulationPulse(
        startedAt: startedAt,
        channels: channels,
        intensity: intensity,
        waveform: waveform,
        duration: duration,
        untilRecovery: untilRecovery,
        isTest: isTest,
        event: event,
        endedAt: endedAt ?? this.endedAt,
        stopped: stopped ?? this.stopped,
      );
}

class SimulationOutputController extends ChangeNotifier implements TriggerSink {
  SimulationOutputController({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const maxHistory = 100;
  final DateTime Function() _now;
  Timer? _timer;
  int _outputToken = 0;
  bool _disposed = false;
  DateTime? _lastTriggerAt;
  DateTime? _lastTestAt;

  CoyoteConfig config = const CoyoteConfig();
  SimulationPulse? activePulse;
  final List<SimulationPulse> _history = [];

  /// Simulation is always available, but remains explicitly labelled as local.
  bool get connected => true;
  bool get readyToOutput => config.triggerIntensity > 0;
  List<SimulationPulse> get history => List.unmodifiable(_history);
  Duration? get activeRemaining {
    final pulse = activePulse;
    if (pulse == null || pulse.untilRecovery) return null;
    final remaining = pulse.duration - _now().difference(pulse.startedAt);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void configure(CoyoteConfig value) {
    if (!value.isValid) throw const FormatException('模拟输出参数无效');
    _finishActive(stopped: true);
    config = value;
    notifyListeners();
  }

  @override
  void emit(TriggerEvent event) {
    if (!readyToOutput) throw StateError('模拟输出强度必须大于 0');
    final now = _now();
    if (_lastTriggerAt != null &&
        now.difference(_lastTriggerAt!) < config.cooldown) {
      developer.log(
        'Simulation safety event rate-limited',
        name: 'SafetyMargin',
      );
      return;
    }
    _lastTriggerAt = now;
    _startPulse(
      intensity: _clampIntensity(config.triggerIntensity),
      duration: config.duration,
      untilRecovery:
          config.outputDurationMode == CoyoteOutputDurationMode.untilRecovery,
      event: event,
      isTest: false,
    );
  }

  Future<void> testOutput() async {
    final now = _now();
    if (_lastTestAt != null && now.difference(_lastTestAt!) < config.cooldown) {
      throw StateError('模拟测试冷却中，请稍后再试');
    }
    final intensity = _clampIntensity(
      config.triggerIntensity.clamp(0, CoyoteConfig.testIntensityLimit),
    );
    if (intensity <= 0) throw StateError('模拟测试强度必须大于 0');
    _lastTestAt = now;
    final duration = config.duration < CoyoteConfig.testDurationLimit
        ? config.duration
        : CoyoteConfig.testDurationLimit;
    _startPulse(
      intensity: intensity,
      duration: duration,
      untilRecovery: false,
      isTest: true,
    );
  }

  Future<void> stop() async {
    _finishActive(stopped: true);
    notifyListeners();
  }

  Future<void> emergencyStop() => stop();

  void clearHistory() {
    _history.clear();
    notifyListeners();
  }

  @override
  void reset() {
    unawaited(stop());
  }

  int _clampIntensity(int requested) => requested.clamp(
    0,
    config.maxIntensity.clamp(1, CoyoteConfig.protocolMaxIntensity),
  );

  List<int> _selectedChannels(TriggerEvent? event) {
    if (event != null &&
        (config.directionalMapping || event.forceDirectional)) {
      switch (event.side) {
        case TriggerSide.left:
          return const [0];
        case TriggerSide.right:
          return const [1];
        case TriggerSide.both:
          return const [0, 1];
        case TriggerSide.unknown:
          break;
      }
    }
    return switch (config.channel) {
      CoyoteChannel.a => const [0],
      CoyoteChannel.b => const [1],
      CoyoteChannel.both => const [0, 1],
    };
  }

  void _startPulse({
    required int intensity,
    required Duration duration,
    required bool untilRecovery,
    required bool isTest,
    TriggerEvent? event,
  }) {
    _finishActive(stopped: true);
    final pulse = SimulationPulse(
      startedAt: _now(),
      channels: List.unmodifiable(_selectedChannels(event)),
      intensity: _clampIntensity(intensity),
      waveform: config.waveform,
      duration: duration,
      untilRecovery: untilRecovery,
      isTest: isTest,
      event: event,
    );
    activePulse = pulse;
    _history.add(pulse);
    if (_history.length > maxHistory) _history.removeAt(0);
    final token = ++_outputToken;
    if (untilRecovery) {
      developer.log(
        'Simulation output remains active until recovery or stop',
        name: 'SafetyMargin',
      );
      notifyListeners();
      return;
    }
    _timer = Timer(duration, () {
      if (_disposed || token != _outputToken) return;
      final completed = activePulse;
      if (completed != null) {
        final finished = completed.copyWith(endedAt: _now());
        final index = _history.lastIndexOf(completed);
        if (index >= 0) _history[index] = finished;
      }
      activePulse = null;
      notifyListeners();
    });
    developer.log(
      'Simulation pulse ${isTest ? 'test' : 'event'} sent',
      name: 'SafetyMargin',
    );
    notifyListeners();
  }

  void _finishActive({required bool stopped}) {
    _timer?.cancel();
    _timer = null;
    _outputToken++;
    final pulse = activePulse;
    if (pulse != null) {
      final finished = pulse.copyWith(endedAt: _now(), stopped: stopped);
      final index = _history.lastIndexOf(pulse);
      if (index >= 0) _history[index] = finished;
      activePulse = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _finishActive(stopped: true);
    super.dispose();
  }
}
