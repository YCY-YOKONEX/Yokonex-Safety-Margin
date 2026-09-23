import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/domain/coyote_protocol.dart';
import 'package:safety_margin/domain/game_engine.dart';
import 'package:safety_margin/domain/pose_sample.dart';
import 'package:safety_margin/services/simulation_device.dart';

void main() {
  late DateTime now;
  late SimulationOutputController device;

  setUp(() {
    now = DateTime(2026, 1, 1);
    device = SimulationOutputController(now: () => now);
  });

  tearDown(() => device.dispose());

  TriggerEvent event({
    TriggerSide side = TriggerSide.unknown,
    bool forceDirectional = false,
  }) => TriggerEvent(
    sessionId: 'simulation',
    sequence: 1,
    elapsed: Duration.zero,
    reason: TriggerReason.outside,
    side: side,
    forceDirectional: forceDirectional,
  );

  test('无需连接实体设备即可输出并统一限制强度', () {
    device.configure(
      const CoyoteConfig(
        channel: CoyoteChannel.both,
        triggerIntensity: 100,
        maxIntensity: 7,
      ),
    );

    device.emit(event());

    expect(device.connected, isTrue);
    expect(device.readyToOutput, isTrue);
    expect(device.activePulse, isNotNull);
    expect(device.activePulse!.channels, [0, 1]);
    expect(device.activePulse!.intensity, 7);
    expect(device.history, hasLength(1));
  });

  test('支持按事件方向映射 A/B 通道', () {
    device.configure(
      const CoyoteConfig(channel: CoyoteChannel.both, directionalMapping: true),
    );

    device.emit(event(side: TriggerSide.right));

    expect(device.activePulse!.channels, [1]);
  });

  test('连续事件遵守 cooldown，不会无限创建脉冲', () {
    device.emit(event());
    now = now.add(const Duration(seconds: 1));
    device.emit(event());
    expect(device.history, hasLength(1));

    now = now.add(const Duration(seconds: 3));
    device.emit(event());
    expect(device.history, hasLength(2));
  });

  test('模拟测试使用低强度和短持续时间，并遵守测试 cooldown', () async {
    device.configure(
      const CoyoteConfig(
        triggerIntensity: 20,
        maxIntensity: 20,
        duration: Duration(seconds: 5),
      ),
    );

    await device.testOutput();

    expect(device.history.single.isTest, isTrue);
    expect(device.history.single.intensity, CoyoteConfig.testIntensityLimit);
    expect(device.history.single.duration, CoyoteConfig.testDurationLimit);
    now = now.add(const Duration(seconds: 1));
    await expectLater(device.testOutput(), throwsStateError);
  });

  test('急停清除活动输出并标记已停止', () async {
    device.emit(event());
    await device.emergencyStop();

    expect(device.activePulse, isNull);
    expect(device.history.single.stopped, isTrue);
  });

  test('无限模式保持输出直到恢复链路调用 stop', () async {
    device.configure(
      const CoyoteConfig(
        duration: Duration(milliseconds: 100),
        outputDurationMode: CoyoteOutputDurationMode.untilRecovery,
      ),
    );
    device.emit(event());

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(device.activePulse, isNotNull);
    expect(device.activePulse!.untilRecovery, isTrue);
    expect(device.activeRemaining, isNull);

    await device.stop();
    expect(device.activePulse, isNull);
  });

  test('历史记录有容量上限', () {
    for (var i = 0; i < SimulationOutputController.maxHistory + 10; i++) {
      now = now.add(const Duration(seconds: 4));
      device.emit(event());
    }

    expect(device.history, hasLength(SimulationOutputController.maxHistory));
  });
}
