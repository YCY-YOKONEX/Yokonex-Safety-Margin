import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/domain/game_engine.dart';
import 'package:safety_margin/domain/pose_sample.dart';

class FailingSink implements TriggerSink {
  @override
  void reset() {}
  @override
  void emit(TriggerEvent event) => throw StateError('模拟输出失败');
}

class Harness {
  Duration time = Duration.zero;
  final sink = MemoryTriggerSink();
  late final engine = GameEngine(sink: sink, now: () => time);
  void observe(TrackingStatus status) =>
      engine.acceptObservation(status, epoch: engine.epoch);
  void start({GameConfig config = const GameConfig()}) {
    engine.configure(config);
    observe(TrackingStatus.inside);
    expect(engine.start(), isTrue);
  }

  void feed(Duration duration, TrackingStatus status) {
    observe(status);
    final end = time + duration;
    while (time < end) {
      final remaining = end - time;
      time += remaining < const Duration(milliseconds: 100)
          ? remaining
          : const Duration(milliseconds: 100);
      observe(status);
      engine.tick();
    }
  }
}

void main() {
  test('输出失败时暂停，不记录为成功触发', () {
    var now = Duration.zero;
    final engine = GameEngine(sink: FailingSink(), now: () => now);
    engine.acceptObservation(TrackingStatus.inside, epoch: engine.epoch);
    engine.start();
    engine.acceptObservation(TrackingStatus.outside, epoch: engine.epoch);
    expect(engine.phase, GamePhase.paused);
    expect(engine.pauseReason, PauseReason.outputFault);
    expect(engine.events, isEmpty);
  });
  test('默认参数和有效值校验', () {
    const config = GameConfig();
    expect(config.duration, const Duration(minutes: 5));
    expect(
      GameConfig.fromJson(config.toJson()).duration,
      const Duration(minutes: 5),
    );
    expect(
      () => GameConfig.fromJson({
        'durationSeconds': 0,
        'startCountdownSeconds': 5,
      }),
      throwsFormatException,
    );
  });
  test('开局和继续都只需要新鲜的观测帧，不要求画面中有人', () {
    final h = Harness();
    expect(h.engine.start(), isFalse);
    h.observe(TrackingStatus.outside);
    h.time += const Duration(seconds: 2);
    // 观测已过期（超过 frameTimeout），仍不能开始。
    expect(h.engine.start(), isFalse);
    h.observe(TrackingStatus.outside);
    // 有新鲜观测即可开始，不要求画面中已有人。
    expect(h.engine.start(), isTrue);
    h.engine.pause(PauseReason.manual);
    expect(h.engine.resume(), isFalse);
    // 继续同样不要求画面中已有人，只需要新鲜观测。
    h.observe(TrackingStatus.outside);
    expect(h.engine.resume(), isTrue);
  });
  test('越界立即触发一次，持续越界不重复，短暂回框不清零', () {
    final h = Harness()..start();
    h.feed(const Duration(milliseconds: 50), TrackingStatus.outside);
    expect(h.engine.events.length, 1);
    expect(h.engine.triggering, isTrue);
    // 设备端持续输出，引擎不需要按间隔重复触发。
    h.feed(const Duration(seconds: 2), TrackingStatus.outside);
    expect(h.engine.events.length, 1);
    // 短于 recoveryConfirm(400ms) 的单帧闪回，不应清零触发状态。
    h.time += const Duration(milliseconds: 100);
    h.observe(TrackingStatus.inside);
    h.time += const Duration(milliseconds: 100);
    h.observe(TrackingStatus.outside);
    expect(h.engine.events.length, 1);
    expect(h.engine.triggering, isTrue);
    // 确认回到区域内（持续 >= 400ms）后，触发状态清零。
    h.feed(const Duration(milliseconds: 500), TrackingStatus.inside);
    expect(h.engine.triggering, isFalse);
    // 再次越界视为新的一次触发。
    h.feed(const Duration(milliseconds: 50), TrackingStatus.outside);
    expect(h.engine.events.length, 2);
  });
  test('越界与无人切换视为同一次持续触发', () {
    final h = Harness()..start();
    h.feed(const Duration(milliseconds: 50), TrackingStatus.outside);
    expect(h.engine.events.single.reason, TriggerReason.outside);
    h.feed(const Duration(seconds: 1), TrackingStatus.absent);
    expect(h.engine.events.length, 1);
    h.feed(const Duration(seconds: 1), TrackingStatus.outside);
    expect(h.engine.events.length, 1);
  });
  for (final reason in PauseReason.values) {
    test('$reason 暂停清零触发状态且暂停时间不计入游戏', () {
      final h = Harness()..start();
      h.feed(const Duration(seconds: 2), TrackingStatus.outside);
      expect(h.engine.events.length, 1);
      final oldEpoch = h.engine.epoch;
      h.engine.pause(reason);
      expect(h.engine.triggering, isFalse);
      h.time += const Duration(seconds: 30);
      h.engine.tick();
      h.engine.acceptObservation(TrackingStatus.absent, epoch: oldEpoch);
      expect(h.engine.elapsed, const Duration(seconds: 2));
      expect(h.engine.events.length, 1);
      expect(h.engine.tracking, TrackingStatus.waiting);
      h.observe(TrackingStatus.inside);
      h.engine.resume();
      // 暂停清零了触发状态，恢复后再次越界视为新的一次触发。
      h.feed(const Duration(milliseconds: 50), TrackingStatus.outside);
      expect(h.engine.events.length, 2);
    });
  }
  test('跟踪不完整有 1 秒豁免，短暂遮挡不触发，超时才按越界触发', () {
    final h = Harness()..start();
    h.feed(const Duration(milliseconds: 500), TrackingStatus.incomplete);
    expect(h.engine.events, isEmpty);
    expect(h.engine.triggering, isFalse);
    // 持续遮挡累计超过豁免时间(1秒)后才按越界触发。
    h.feed(const Duration(milliseconds: 600), TrackingStatus.incomplete);
    expect(h.engine.events.length, 1);
    expect(h.engine.events.single.reason, TriggerReason.outside);
    expect(h.engine.phase, GamePhase.running);
    // 已经触发后继续遮挡不再豁免、不重复触发。
    h.feed(const Duration(seconds: 1), TrackingStatus.incomplete);
    expect(h.engine.events.length, 1);
    // 确认回到区域内后，豁免时间重新计时。
    h.feed(const Duration(milliseconds: 500), TrackingStatus.inside);
    expect(h.engine.triggering, isFalse);
    h.feed(const Duration(milliseconds: 500), TrackingStatus.incomplete);
    expect(h.engine.events.length, 1);
    h.feed(const Duration(milliseconds: 600), TrackingStatus.incomplete);
    expect(h.engine.events.length, 2);
  });
  test('断流时自动暂停，不重复触发', () {
    final h = Harness()..start();
    h.feed(const Duration(seconds: 3), TrackingStatus.outside);
    expect(h.engine.events.length, 1);
    h.time += const Duration(seconds: 20);
    h.engine.tick();
    expect(h.engine.phase, GamePhase.paused);
    expect(h.engine.pauseReason, PauseReason.cameraFault);
    expect(h.engine.events.length, 1);
  });
  test('恢复帧不能掩盖断流', () {
    final h = Harness()..start();
    h.time += const Duration(seconds: 2);
    h.observe(TrackingStatus.outside);
    expect(h.engine.phase, GamePhase.paused);
  });
  test('达到时长后自动结束，不再产生新的触发', () {
    final h = Harness()
      ..start(config: const GameConfig(duration: Duration(seconds: 3)));
    final epoch = h.engine.epoch;
    h.feed(const Duration(seconds: 3), TrackingStatus.outside);
    expect(h.engine.phase, GamePhase.finished);
    expect(h.engine.events.length, 1);
    h.time += const Duration(seconds: 5);
    h.engine.acceptObservation(TrackingStatus.outside, epoch: epoch);
    h.engine.tick();
    expect(h.engine.elapsed, const Duration(seconds: 3));
    expect(h.engine.events.length, 1);
  });
  test('手动结束、再次开局拒收上一局结果', () {
    final h = Harness()..start();
    final oldEpoch = h.engine.epoch;
    h.feed(const Duration(seconds: 3), TrackingStatus.outside);
    final oldId = h.engine.events.single.sessionId;
    h.engine.finish();
    h.feed(const Duration(seconds: 5), TrackingStatus.absent);
    expect(h.engine.events.length, 1);
    h.engine.reset();
    expect(h.sink.events, isEmpty);
    h.start();
    h.engine.acceptObservation(TrackingStatus.absent, epoch: oldEpoch);
    expect(h.engine.tracking, TrackingStatus.inside);
    h.feed(const Duration(seconds: 3), TrackingStatus.outside);
    expect(h.engine.events.single.sequence, 1);
    expect(h.engine.events.single.sessionId, isNot(oldId));
    expect(h.sink.events.length, 1);
  });
}
