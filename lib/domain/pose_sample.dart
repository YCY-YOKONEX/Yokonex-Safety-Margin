import 'dart:ui';

import 'activity_region.dart';

const landmarkConfidenceThreshold = 0.6;
// 边界容错边距（归一化坐标，约等于画面宽/高的 4%），吸收贴边站立时的姿态抖动。
const boundaryTolerance = 0.04;

enum Joint {
  nose,
  leftEyeInner,
  leftEye,
  leftEyeOuter,
  rightEyeInner,
  rightEye,
  rightEyeOuter,
  leftEar,
  rightEar,
  leftMouth,
  rightMouth,
  leftShoulder,
  rightShoulder,
  leftElbow,
  rightElbow,
  leftWrist,
  rightWrist,
  leftPinky,
  rightPinky,
  leftIndex,
  rightIndex,
  leftThumb,
  rightThumb,
  leftHip,
  rightHip,
  leftKnee,
  rightKnee,
  leftAnkle,
  rightAnkle,
  leftHeel,
  rightHeel,
  leftFootIndex,
  rightFootIndex,
}

const monitoredJoints = {
  Joint.leftShoulder,
  Joint.rightShoulder,
  Joint.leftElbow,
  Joint.rightElbow,
  Joint.leftWrist,
  Joint.rightWrist,
  Joint.leftHip,
  Joint.rightHip,
  Joint.leftKnee,
  Joint.rightKnee,
  Joint.leftAnkle,
  Joint.rightAnkle,
};

const skeletonEdges = [
  (Joint.leftEar, Joint.leftEye),
  (Joint.leftEye, Joint.nose),
  (Joint.nose, Joint.rightEye),
  (Joint.rightEye, Joint.rightEar),
  (Joint.leftShoulder, Joint.rightShoulder),
  (Joint.leftShoulder, Joint.leftElbow),
  (Joint.leftElbow, Joint.leftWrist),
  (Joint.rightShoulder, Joint.rightElbow),
  (Joint.rightElbow, Joint.rightWrist),
  (Joint.leftShoulder, Joint.leftHip),
  (Joint.rightShoulder, Joint.rightHip),
  (Joint.leftHip, Joint.rightHip),
  (Joint.leftHip, Joint.leftKnee),
  (Joint.leftKnee, Joint.leftAnkle),
  (Joint.rightHip, Joint.rightKnee),
  (Joint.rightKnee, Joint.rightAnkle),
  (Joint.leftAnkle, Joint.leftHeel),
  (Joint.leftHeel, Joint.leftFootIndex),
  (Joint.rightAnkle, Joint.rightHeel),
  (Joint.rightHeel, Joint.rightFootIndex),
  (Joint.leftWrist, Joint.leftIndex),
  (Joint.rightWrist, Joint.rightIndex),
];

class Landmark {
  const Landmark(this.position, this.confidence);
  final Offset position;
  final double confidence;

  bool get isReliable =>
      confidence.isFinite &&
      confidence >= landmarkConfidenceThreshold &&
      position.dx.isFinite &&
      position.dy.isFinite;
}

enum TrackingStatus { waiting, inside, outside, absent, incomplete }

class PoseSample {
  PoseSample(Map<Joint, Landmark> landmarks, {this.personDetected = true})
    : landmarks = Map.unmodifiable(landmarks);
  PoseSample.absent() : landmarks = const {}, personDetected = false;

  final Map<Joint, Landmark> landmarks;
  final bool personDetected;

  TrackingStatus classify(ActivityRegion? region) {
    if (region == null) return TrackingStatus.waiting;
    if (!personDetected) return TrackingStatus.absent;
    var complete = true;
    // 可信越界点优先，遮挡其他关节不能抵消已经确认的越界。
    for (final joint in monitoredJoints) {
      final point = landmarks[joint];
      if (point == null || !point.isReliable) {
        complete = false;
      } else if (!region.containsWithMargin(
        point.position,
        boundaryTolerance,
      )) {
        return TrackingStatus.outside;
      }
    }
    return complete ? TrackingStatus.inside : TrackingStatus.incomplete;
  }
}
