import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:safety_margin/domain/activity_region.dart';
import 'package:safety_margin/domain/pose_sample.dart';
import 'package:safety_margin/services/pose_camera.dart';
import 'package:safety_margin/services/settings_store.dart';

class FakeSettingsStore implements SettingsStore {
  SavedSetup setup;
  FakeSettingsStore([this.setup = const SavedSetup()]);
  @override
  Future<SavedSetup> load() async => setup;
  @override
  Future<void> save(SavedSetup value) async {
    setup = value;
  }
}

class FakePoseCamera extends PoseCamera {
  FakePoseCamera(this.readEpoch);
  final int Function() readEpoch;
  @override
  CameraController? get previewController => null;
  @override
  PoseFrame? frame;
  @override
  String? cameraId = 'front';
  @override
  String? error;
  @override
  bool initializing = false;
  @override
  bool ready = false;
  @override
  bool get mirrored => cameraId == 'front';
  @override
  bool get canSwitch => true;
  @override
  Size imageSize = const Size(480, 640);
  int suspended = 0;

  @override
  Future<void> initialize({String? preferredCameraId}) async {
    cameraId = preferredCameraId ?? cameraId;
    ready = true;
    error = null;
    notifyListeners();
  }

  @override
  Future<void> switchCamera() async {
    cameraId = cameraId == 'front' ? 'back' : 'front';
    frame = null;
    notifyListeners();
  }

  @override
  Future<void> suspend() async {
    suspended++;
    ready = false;
    frame = null;
    notifyListeners();
  }

  @override
  Future<void> close() async {}

  void emit(PoseSample sample, {int? epoch}) {
    frame = PoseFrame(
      sample: sample,
      epoch: epoch ?? readEpoch(),
      imageSize: imageSize,
    );
    notifyListeners();
  }

  void fail() {
    error = '摄像头不可用，请重试';
    ready = false;
    notifyListeners();
  }
}

ActivityRegion testRegion() =>
    ActivityRegion.rectangle(const Offset(.1, .05), const Offset(.9, .95));

PoseSample fullPose({bool outside = false}) {
  const positions = {
    Joint.nose: Offset(.5, .15),
    Joint.leftEye: Offset(.47, .14),
    Joint.rightEye: Offset(.53, .14),
    Joint.leftEar: Offset(.44, .15),
    Joint.rightEar: Offset(.56, .15),
    Joint.leftShoulder: Offset(.38, .28),
    Joint.rightShoulder: Offset(.62, .28),
    Joint.leftElbow: Offset(.32, .43),
    Joint.rightElbow: Offset(.68, .43),
    Joint.leftWrist: Offset(.28, .55),
    Joint.rightWrist: Offset(.72, .55),
    Joint.leftHip: Offset(.43, .54),
    Joint.rightHip: Offset(.57, .54),
    Joint.leftKnee: Offset(.41, .71),
    Joint.rightKnee: Offset(.59, .71),
    Joint.leftAnkle: Offset(.4, .89),
    Joint.rightAnkle: Offset(.6, .89),
  };
  return PoseSample({
    for (final entry in positions.entries)
      entry.key: Landmark(entry.value, .95),
    if (outside) Joint.leftWrist: const Landmark(Offset(.98, .5), .95),
  });
}
