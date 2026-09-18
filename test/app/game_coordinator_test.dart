import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/app/game_coordinator.dart';
import 'package:safety_margin/domain/game_engine.dart';
import 'package:safety_margin/domain/game_mode.dart';
import 'package:safety_margin/domain/pose_sample.dart';
import 'package:safety_margin/services/settings_store.dart';
import '../support/fakes.dart';

void main() {
  late GameCoordinator c;
  late FakePoseCamera camera;
  late FakeSettingsStore store;
  var now = Duration.zero;

  setUp(() async {
    now = Duration.zero;
    store = FakeSettingsStore(
      SavedSetup(region: testRegion(), cameraId: 'front'),
    );
    c = GameCoordinator(
      engine: GameEngine(sink: MemoryTriggerSink(), now: () => now),
      cameraFactory: (readEpoch) => camera = FakePoseCamera(readEpoch),
      store: store,
      keepAwake: (_) async {},
      autoTick: false,
    );
    await c.initialize();
  });
  tearDown(() => c.dispose());

  test('加载区域，收到新鲜观测帧后允许开始（不要求画面中已有人）', () {
    expect(c.region, isNotNull);
    expect(c.canStart, isFalse);
    camera.emit(fullPose());
    expect(c.canStart, isTrue);
    c.start();
    expect(c.engine.phase, GamePhase.running);
  });
  test('现有姿态帧将左侧越界信息送入触发事件', () {
    camera.emit(fullPose());
    c.start();
    camera.emit(fullPose(outside: true));
    expect(c.engine.events.single.side, TriggerSide.left);
  });
  test('无需画区的模式可直接开始，双区违规进入统一触发链', () async {
    c.dispose();
    store = FakeSettingsStore(
      const SavedSetup(
        config: GameConfig(
          startCountdown: Duration.zero,
          mode: SafetyGameMode.poseChallenge,
        ),
        cameraId: 'front',
      ),
    );
    c = GameCoordinator(
      engine: GameEngine(sink: MemoryTriggerSink(), now: () => now),
      cameraFactory: (readEpoch) => camera = FakePoseCamera(readEpoch),
      store: store,
      keepAwake: (_) async {},
      autoTick: false,
    );
    await c.initialize();
    camera.emit(fullPose());
    expect(c.canStart, isTrue);

    c.updateConfig(
      const GameConfig(
        startCountdown: Duration.zero,
        mode: SafetyGameMode.dualZone,
      ),
    );
    c.region = testRegion();
    camera.emit(fullPose());
    c.start();
    final pose = fullPose();
    camera.emit(
      PoseSample({
        ...pose.landmarks,
        Joint.leftWrist: const Landmark(Offset(.75, .55), .95),
      }),
    );
    expect(c.engine.events.single.reason, TriggerReason.wrongZone);
    expect(c.engine.events.single.side, TriggerSide.left);
    expect(c.engine.events.single.forceDirectional, isTrue);
  });
  test('自定义姿势超过配置时限后进入统一触发链', () async {
    c.updateConfig(
      const GameConfig(
        startCountdown: Duration.zero,
        mode: SafetyGameMode.customPose,
        customPoseSettings: CustomPoseSettings(
          mismatchGrace: Duration(seconds: 2),
        ),
      ),
    );
    final target = PoseSample({
      for (final entry in CustomPoseTemplate.standard.points.entries)
        entry.key: Landmark(entry.value, .95),
    });
    camera.emit(target);
    c.start();
    final wrong = PoseSample({
      ...target.landmarks,
      Joint.rightWrist: const Landmark(Offset(.05, .05), .95),
    });
    camera.emit(wrong);
    expect(c.engine.events, isEmpty);
    now += const Duration(seconds: 1);
    camera.emit(wrong);
    expect(c.engine.events, isEmpty);
    now += const Duration(seconds: 1);
    camera.emit(wrong);
    expect(c.engine.events.single.reason, TriggerReason.customPose);
    expect(c.engine.events.single.side, TriggerSide.right);
  });
  test('切换摄像头清空区域并保存', () async {
    camera.emit(fullPose());
    await c.switchCamera();
    expect(c.region, isNull);
    expect(c.canStart, isFalse);
    expect(store.setup.region, isNull);
    expect(store.setup.cameraId, 'back');
  });
  test('前后台切换暂停，过期帧不恢复状态', () async {
    camera.emit(fullPose());
    c.start();
    final oldEpoch = c.engine.epoch;
    now += const Duration(milliseconds: 500);
    await c.setForeground(false);
    expect(c.engine.phase, GamePhase.paused);
    expect(camera.suspended, 1);
    now += const Duration(seconds: 30);
    await c.setForeground(true);
    camera.emit(PoseSample.absent(), epoch: oldEpoch);
    expect(c.engine.tracking, TrackingStatus.waiting);
    expect(c.engine.elapsed, const Duration(milliseconds: 500));
    camera.emit(fullPose());
    expect(c.engine.phase, GamePhase.paused);
    expect(c.canResume, isTrue);
  });
  test('画区期间不允许开始，完成后等待新帧', () {
    camera.emit(fullPose());
    c.beginDrawing();
    camera.emit(fullPose());
    expect(c.canStart, isFalse);
    c.endDrawing(testRegion());
    expect(c.canStart, isFalse);
    camera.emit(fullPose());
    expect(c.canStart, isTrue);
  });
  test('摄像头故障暂停并可重试', () async {
    camera.emit(fullPose());
    c.start();
    camera.fail();
    expect(c.engine.phase, GamePhase.paused);
    expect(c.engine.pauseReason, PauseReason.cameraFault);
    await c.retryCamera();
    camera.emit(fullPose());
    expect(c.canResume, isTrue);
    expect(c.engine.phase, GamePhase.paused);
  });
  test('结束释放摄像头，再来一局清空识别和事件', () async {
    camera.emit(fullPose());
    c.start();
    c.finish();
    expect(camera.suspended, 1);
    await c.playAgain();
    expect(c.engine.phase, GamePhase.ready);
    expect(c.engine.events, isEmpty);
    expect(c.canStart, isFalse);
    expect(camera.ready, isTrue);
  });
}
