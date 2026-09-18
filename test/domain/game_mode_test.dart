import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/domain/game_mode.dart';
import 'package:safety_margin/domain/pose_sample.dart';

import '../support/fakes.dart';

PoseSample withPoints(Map<Joint, Offset> points) {
  final base = fullPose();
  return PoseSample({
    ...base.landmarks,
    for (final entry in points.entries) entry.key: Landmark(entry.value, .95),
  });
}

PoseSample matching(PoseChallenge challenge) => switch (challenge) {
  PoseChallenge.raiseLeftHand => withPoints({
    Joint.leftWrist: const Offset(.28, .12),
  }),
  PoseChallenge.raiseRightHand => withPoints({
    Joint.rightWrist: const Offset(.72, .12),
  }),
  PoseChallenge.raiseLeftLeg => withPoints({
    Joint.leftAnkle: const Offset(.4, .70),
  }),
  PoseChallenge.raiseRightLeg => withPoints({
    Joint.rightAnkle: const Offset(.6, .70),
  }),
  PoseChallenge.squat => withPoints({
    Joint.leftKnee: const Offset(.38, .63),
    Joint.rightKnee: const Offset(.62, .63),
    Joint.leftAnkle: const Offset(.36, .82),
    Joint.rightAnkle: const Offset(.64, .82),
  }),
  PoseChallenge.armsOut => withPoints({
    Joint.leftWrist: const Offset(.20, .28),
    Joint.rightWrist: const Offset(.80, .28),
  }),
};

void main() {
  test('缩圈只缩小判定区域，不改变设备强度配置', () {
    final session = GameModeSession()..reset(SafetyGameMode.shrinkingZone);
    final start = session.effectiveRegion(
      testRegion(),
      Duration.zero,
      const Duration(seconds: 10),
    )!;
    final end = session.effectiveRegion(
      testRegion(),
      const Duration(seconds: 10),
      const Duration(seconds: 10),
    )!;
    expect(start.bounds.width, closeTo(.8, .001));
    expect(end.bounds.width, closeTo(.36, .001));
  });

  test('木头人仅在停止音乐阶段按左右骨骼位移触发', () {
    final session = GameModeSession()..reset(SafetyGameMode.redLightGreenLight);
    expect(
      session
          .evaluate(
            fullPose(),
            null,
            const Duration(seconds: 1),
            const Duration(minutes: 1),
          )
          .status,
      TrackingStatus.inside,
    );
    session.evaluate(
      fullPose(),
      null,
      const Duration(seconds: 5),
      const Duration(minutes: 1),
    );
    final moved = session.evaluate(
      withPoints({Joint.leftWrist: const Offset(.10, .55)}),
      null,
      const Duration(milliseconds: 5200),
      const Duration(minutes: 1),
    );
    expect(moved.status, TrackingStatus.outside);
    expect(moved.side, TriggerSide.left);
    expect(moved.violation, ModeViolation.movement);
  });

  test('木头人支持固定移动/静止秒数和每轮随机范围', () {
    final fixed = GameModeSession()
      ..reset(
        SafetyGameMode.redLightGreenLight,
        redLight: const RedLightSettings(moveSeconds: 2, freezeSeconds: 4),
      );
    expect(fixed.isGreenLight(const Duration(milliseconds: 1999)), isTrue);
    expect(fixed.isGreenLight(const Duration(seconds: 2)), isFalse);
    expect(fixed.isGreenLight(const Duration(milliseconds: 5999)), isFalse);
    expect(fixed.isGreenLight(const Duration(seconds: 6)), isTrue);

    final random = GameModeSession(random: Random(7))
      ..reset(
        SafetyGameMode.redLightGreenLight,
        redLight: const RedLightSettings(
          moveSeconds: 8,
          freezeSeconds: 5,
          randomized: true,
        ),
      );
    expect(random.lightPhaseDuration.inSeconds, inInclusiveRange(1, 8));
    final first = random.lightPhaseDuration;
    random.isGreenLight(first);
    expect(random.lightPhaseDuration.inSeconds, inInclusiveRange(1, 5));
  });

  test('指定姿势保持成功后得分并更换动作', () {
    final session = GameModeSession(random: Random(1))
      ..reset(SafetyGameMode.poseChallenge);
    final first = session.challenge!;
    session.evaluate(
      matching(first),
      null,
      Duration.zero,
      const Duration(minutes: 1),
    );
    session.evaluate(
      matching(first),
      null,
      const Duration(milliseconds: 1100),
      const Duration(minutes: 1),
    );
    expect(session.score, 100);
    expect(session.completedChallenges, 1);
    expect(session.challenge, isNot(first));
  });

  test('闪避模式识别左右身体碰到移动禁区', () {
    final session = GameModeSession()..reset(SafetyGameMode.dodge);
    final result = session.evaluate(
      withPoints({Joint.leftWrist: const Offset(.12, .40)}),
      null,
      Duration.zero,
      const Duration(minutes: 1),
    );
    expect(result.status, TrackingStatus.outside);
    expect(result.side, TriggerSide.left);
    expect(result.violation, ModeViolation.obstacle);
  });

  test('平衡挑战记录最长坚持时间且强度不参与计分', () {
    final session = GameModeSession()..reset(SafetyGameMode.balance);
    final pose = withPoints({
      Joint.leftWrist: const Offset(.20, .28),
      Joint.rightWrist: const Offset(.80, .28),
      Joint.leftAnkle: const Offset(.4, .70),
    });
    session.evaluate(pose, null, Duration.zero, const Duration(minutes: 1));
    session.evaluate(
      pose,
      null,
      const Duration(milliseconds: 1500),
      const Duration(minutes: 1),
    );
    expect(session.bestHold, const Duration(milliseconds: 1500));
    expect(session.score, 15);
  });

  test('连击模式连续完成动作按固定规则增加分数和连击', () {
    final session = GameModeSession(random: Random(3))
      ..reset(SafetyGameMode.combo);
    var current = session.challenge!;
    session.evaluate(
      matching(current),
      null,
      Duration.zero,
      const Duration(minutes: 1),
    );
    session.evaluate(
      matching(current),
      null,
      const Duration(milliseconds: 800),
      const Duration(minutes: 1),
    );
    current = session.challenge!;
    session.evaluate(
      matching(current),
      null,
      const Duration(seconds: 1),
      const Duration(minutes: 1),
    );
    session.evaluate(
      matching(current),
      null,
      const Duration(milliseconds: 1800),
      const Duration(minutes: 1),
    );
    expect(session.combo, 2);
    expect(session.bestCombo, 2);
    expect(session.score, 300);
  });

  test('双区模式将解剖学左右违规强制映射到 A/B', () {
    final session = GameModeSession()..reset(SafetyGameMode.dualZone);
    expect(
      session
          .evaluate(
            fullPose(),
            testRegion(),
            Duration.zero,
            const Duration(minutes: 1),
          )
          .status,
      TrackingStatus.inside,
    );
    final result = session.evaluate(
      withPoints({Joint.leftWrist: const Offset(.75, .55)}),
      testRegion(),
      Duration.zero,
      const Duration(minutes: 1),
    );
    expect(result.status, TrackingStatus.outside);
    expect(result.side, TriggerSide.left);
    expect(result.violation, ModeViolation.wrongZone);
    expect(result.forceDirectional, isTrue);
  });

  test('自定义姿势要求全部目标关节点匹配，超过自定义秒数才违规', () {
    const grace = Duration(seconds: 2);
    const settings = CustomPoseSettings(mismatchGrace: grace);
    final session = GameModeSession()
      ..reset(SafetyGameMode.customPose, customPose: settings);
    PoseSample targetPose() => PoseSample({
      for (final entry in settings.template.points.entries)
        entry.key: Landmark(entry.value, .95),
    });
    expect(
      session
          .evaluate(
            targetPose(),
            null,
            Duration.zero,
            const Duration(minutes: 1),
          )
          .status,
      TrackingStatus.inside,
    );
    final wrong = PoseSample({
      ...targetPose().landmarks,
      Joint.leftWrist: const Landmark(Offset(.05, .05), .95),
    });
    expect(
      session
          .evaluate(wrong, null, Duration.zero, const Duration(minutes: 1))
          .status,
      TrackingStatus.inside,
    );
    final expired = session.evaluate(
      wrong,
      null,
      const Duration(seconds: 2),
      const Duration(minutes: 1),
    );
    expect(expired.status, TrackingStatus.outside);
    expect(expired.side, TriggerSide.left);
    expect(expired.violation, ModeViolation.customPose);
    expect(
      session
          .evaluate(
            targetPose(),
            null,
            const Duration(milliseconds: 2100),
            const Duration(minutes: 1),
          )
          .status,
      TrackingStatus.inside,
    );
  });
}
