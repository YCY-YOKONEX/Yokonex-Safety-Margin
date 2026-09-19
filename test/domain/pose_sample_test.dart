import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/domain/activity_region.dart';
import 'package:safety_margin/domain/pose_sample.dart';

void main() {
  final region = ActivityRegion.rectangle(
    const Offset(.1, .1),
    const Offset(.9, .9),
  );
  Map<Joint, Landmark> inside() => {
    for (final joint in monitoredJoints)
      joint: const Landmark(Offset(.5, .5), .9),
  };
  test('12 个主要关节齐全且在区域内', () {
    expect(monitoredJoints.length, 12);
    expect(PoseSample(inside()).classify(region), TrackingStatus.inside);
  });
  test('任一主要关节越界', () {
    for (final joint in monitoredJoints) {
      final landmarks = inside()..[joint] = const Landmark(Offset(.95, .5), .9);
      expect(PoseSample(landmarks).classify(region), TrackingStatus.outside);
    }
  });
  test('缺少或低可信关节为跟踪不完整', () {
    expect(
      PoseSample(inside()..remove(Joint.leftAnkle)).classify(region),
      TrackingStatus.incomplete,
    );
    expect(
      PoseSample(
        inside()..[Joint.leftAnkle] = const Landmark(Offset(.95, .5), .59),
      ).classify(region),
      TrackingStatus.incomplete,
    );
  });
  test('可信越界优先于其他关节缺失', () {
    final landmarks = inside()
      ..remove(Joint.leftAnkle)
      ..[Joint.rightWrist] = const Landmark(Offset(.99, .5), .6);
    expect(PoseSample(landmarks).classify(region), TrackingStatus.outside);
  });
  test('贴边容错吸收轻微抖动，超出容错仍判越界', () {
    // 区域右边界在 x=.9，容错边距 boundaryTolerance=.04。
    final barelyOut = inside()
      ..[Joint.rightWrist] = const Landmark(Offset(.905, .5), .9);
    expect(PoseSample(barelyOut).classify(region), TrackingStatus.inside);
    // 稍微晃动到 .03 之外仍在容错范围内，不应误判越界。
    final swaying = inside()
      ..[Joint.rightWrist] = const Landmark(Offset(.93, .5), .9);
    expect(PoseSample(swaying).classify(region), TrackingStatus.inside);
    final clearlyOut = inside()
      ..[Joint.rightWrist] = const Landmark(Offset(.95, .5), .9);
    expect(PoseSample(clearlyOut).classify(region), TrackingStatus.outside);
  });
  test('无人、没有区域、非监测关节越界', () {
    expect(PoseSample.absent().classify(region), TrackingStatus.absent);
    expect(PoseSample.absent().classify(null), TrackingStatus.waiting);
    expect(
      PoseSample(
        inside()..[Joint.nose] = const Landmark(Offset(2, 2), 1),
      ).classify(region),
      TrackingStatus.inside,
    );
  });
  test('越界侧别按现有左右监测关节判定', () {
    expect(
      PoseSample(
        inside()..[Joint.leftWrist] = const Landmark(Offset(.96, .5), .9),
      ).outsideSide(region),
      TriggerSide.left,
    );
    expect(
      PoseSample(
        inside()..[Joint.rightAnkle] = const Landmark(Offset(.96, .5), .9),
      ).outsideSide(region),
      TriggerSide.right,
    );
    expect(
      PoseSample(
        inside()
          ..[Joint.leftWrist] = const Landmark(Offset(.96, .5), .9)
          ..[Joint.rightAnkle] = const Landmark(Offset(.96, .5), .9),
      ).outsideSide(region),
      TriggerSide.both,
    );
    expect(PoseSample.absent().outsideSide(region), TriggerSide.unknown);
    expect(PoseSample(inside()).outsideSide(region), TriggerSide.unknown);
  });
}
