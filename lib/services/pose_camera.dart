import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../domain/activity_region.dart';
import '../domain/pose_sample.dart';

class PoseFrame {
  const PoseFrame({
    required this.sample,
    required this.epoch,
    required this.imageSize,
  });
  final PoseSample sample;
  final int epoch;
  final Size imageSize;
}

abstract class PoseCamera extends ChangeNotifier {
  CameraController? get previewController;
  PoseFrame? get frame;
  String? get cameraId;
  String? get error;
  bool get initializing;
  bool get ready;
  bool get mirrored;
  bool get canSwitch;
  Size get imageSize;
  Future<void> initialize({String? preferredCameraId});
  Future<void> switchCamera();
  Future<void> suspend();
  Future<void> close();
}

/// iOS 图像流已旋转到竖屏，且前摄已镜像；Android 检测器返回旋转后的坐标。
Offset normalizeDetectorPoint({
  required Offset point,
  required Size rawSize,
  required int rotation,
  required bool isIOS,
  required bool frontCamera,
}) {
  final size = isIOS ? rawSize : uprightImageSize(rawSize, rotation);
  final x = point.dx / size.width;
  return Offset(isIOS && frontCamera ? 1 - x : x, point.dy / size.height);
}

class MlKitPoseCamera extends PoseCamera {
  MlKitPoseCamera({required this.readEpoch});
  final int Function() readEpoch;
  final PoseDetector _detector = PoseDetector(options: PoseDetectorOptions());
  final Stopwatch _clock = Stopwatch()..start();
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  CameraDescription? _selected;
  PoseFrame? _frame;
  String? _error;
  bool _initializing = false;
  bool _closed = false;
  int _generation = 0;
  Future<void>? _processing;
  Future<void> _operations = Future.value();
  Duration _lastAccepted = const Duration(seconds: -1);
  // 关节点位置和置信度都做帧间指数平滑，抑制单帧抖动；权重越低越平滑、响应越慢。
  // 置信度不平滑的话，单帧的置信度掉零会让关节瞬间判定为不可靠，
  // 站在区域中间不动也会被误判为跟踪不完整。
  static const _smoothingAlpha = 0.4;
  final Map<Joint, Offset> _smoothed = {};
  final Map<Joint, double> _smoothedConfidence = {};

  @override
  CameraController? get previewController => _controller;
  @override
  PoseFrame? get frame => _frame;
  @override
  String? get cameraId => _selected?.name;
  @override
  String? get error => _error;
  @override
  bool get initializing => _initializing;
  @override
  bool get ready =>
      !_closed &&
      !_initializing &&
      _error == null &&
      (_controller?.value.isInitialized ?? false);
  @override
  bool get mirrored => _selected?.lensDirection == CameraLensDirection.front;
  @override
  bool get canSwitch => _cameras.any(
    (c) =>
        c.lensDirection != _selected?.lensDirection &&
        c.lensDirection != CameraLensDirection.external,
  );
  @override
  Size get imageSize =>
      _frame?.imageSize ??
      _controller?.value.previewSize?.flipped ??
      const Size(480, 640);

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _operations.then((_) => action());
    _operations = next.catchError((Object _) {});
    return next;
  }

  @override
  Future<void> initialize({String? preferredCameraId}) {
    final generation = ++_generation;
    _initializing = true;
    _error = null;
    _frame = null;
    _smoothed.clear();
    _smoothedConfidence.clear();
    _notify();
    return _enqueue(() async {
      await _releaseCamera();
      if (_closed || generation != _generation) return;
      try {
        if (!Platform.isAndroid && !Platform.isIOS) {
          throw const FormatException('请在 Android 或 iPhone 上运行');
        }
        _cameras = await availableCameras();
        if (_cameras.isEmpty) throw const FormatException('未找到可用摄像头');
        _selected =
            _cameras.where((c) => c.name == preferredCameraId).firstOrNull ??
            _cameras.where((c) => c.name == _selected?.name).firstOrNull ??
            _cameras
                .where((c) => c.lensDirection == CameraLensDirection.front)
                .firstOrNull ??
            _cameras.first;
        if (_closed || generation != _generation) return;
        final controller = CameraController(
          _selected!,
          ResolutionPreset.medium,
          enableAudio: false,
          fps: 15,
          imageFormatGroup: Platform.isAndroid
              ? ImageFormatGroup.nv21
              : ImageFormatGroup.bgra8888,
        );
        _controller = controller;
        await controller.initialize();
        if (_closed || generation != _generation) {
          await _releaseCamera();
          return;
        }
        await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
        controller.addListener(_cameraChanged);
        await controller.startImageStream(
          (image) => _receiveImage(image, generation),
        );
        _initializing = false;
        _notify();
      } catch (error) {
        if (!_closed && generation == _generation) {
          _error = _describeError(error);
          _initializing = false;
          _notify();
          await _releaseCamera();
        }
      }
    });
  }

  void _cameraChanged() {
    final value = _controller?.value;
    if (value?.hasError ?? false) _fail('摄像头已中断，请重试');
  }

  void _receiveImage(CameraImage image, int generation) {
    if (_closed ||
        generation != _generation ||
        _error != null ||
        _processing != null) {
      return;
    }
    final now = _clock.elapsed;
    if (now - _lastAccepted < const Duration(milliseconds: 80)) return;
    _lastAccepted = now;
    final epoch = readEpoch();
    // 单帧串行识别；会话号在采集时记录，异步完成后仍使用原会话号。
    _processing = _process(
      image,
      generation,
      epoch,
      now,
    ).whenComplete(() => _processing = null);
  }

  Future<void> _process(
    CameraImage image,
    int generation,
    int epoch,
    Duration capturedAt,
  ) async {
    try {
      final selected = _selected!;
      final rotation = Platform.isIOS ? 0 : selected.sensorOrientation;
      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      final expected = Platform.isIOS
          ? InputImageFormat.bgra8888
          : InputImageFormat.nv21;
      if (format != expected || image.planes.length != 1) {
        throw const FormatException('摄像头图像格式不兼容');
      }
      final rawSize = Size(image.width.toDouble(), image.height.toDouble());
      final plane = image.planes.first;
      final input = InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: rawSize,
          rotation: InputImageRotationValue.fromRawValue(rotation)!,
          format: format!,
          bytesPerRow: plane.bytesPerRow,
        ),
      );
      final poses = await _detector.processImage(input);
      if (_closed || generation != _generation || epoch != readEpoch()) return;
      // 长耗时识别结果不作为当前人体状态使用。
      if (_clock.elapsed - capturedAt >= const Duration(milliseconds: 1500)) {
        return;
      }
      final size = Platform.isIOS
          ? rawSize
          : uprightImageSize(rawSize, rotation);
      final pose = poses.firstOrNull;
      if (pose == null) {
        // 人物消失后清空平滑状态，避免下次出现时和旧数据插值。
        _smoothed.clear();
        _smoothedConfidence.clear();
      }
      final sample = pose == null
          ? PoseSample.absent()
          : PoseSample({
              for (final entry in pose.landmarks.entries)
                Joint.values.byName(entry.key.name): Landmark(
                  _smoothPosition(
                    Joint.values.byName(entry.key.name),
                    normalizeDetectorPoint(
                      point: Offset(entry.value.x, entry.value.y),
                      rawSize: rawSize,
                      rotation: rotation,
                      isIOS: Platform.isIOS,
                      frontCamera:
                          selected.lensDirection == CameraLensDirection.front,
                    ),
                  ),
                  _smoothConfidence(
                    Joint.values.byName(entry.key.name),
                    entry.value.likelihood,
                  ),
                ),
            });
      _frame = PoseFrame(sample: sample, epoch: epoch, imageSize: size);
      _notify();
    } catch (error) {
      if (!_closed && generation == _generation) _fail(_describeError(error));
    }
  }

  /// 关节点位置指数平滑：抑制模型逐帧预测抖动，不引入明显响应延迟。
  Offset _smoothPosition(Joint joint, Offset raw) {
    final previous = _smoothed[joint];
    final value = previous == null
        ? raw
        : Offset.lerp(previous, raw, _smoothingAlpha)!;
    _smoothed[joint] = value;
    return value;
  }

  /// 置信度指数平滑：避免单帧置信度骤降把关节瞬间判定为不可靠。
  double _smoothConfidence(Joint joint, double raw) {
    final previous = _smoothedConfidence[joint];
    final value = previous == null
        ? raw
        : previous + (raw - previous) * _smoothingAlpha;
    _smoothedConfidence[joint] = value;
    return value;
  }

  void _fail(String message) {
    _error = message;
    _frame = null;
    _generation++;
    _smoothed.clear();
    _smoothedConfidence.clear();
    _notify();
    unawaited(_enqueue(_releaseCamera));
  }

  @override
  Future<void> switchCamera() {
    final next = _cameras
        .where(
          (c) =>
              c.lensDirection != _selected?.lensDirection &&
              c.lensDirection != CameraLensDirection.external,
        )
        .firstOrNull;
    return next == null
        ? Future.value()
        : initialize(preferredCameraId: next.name);
  }

  @override
  Future<void> suspend() {
    _generation++;
    _frame = null;
    _initializing = false;
    _smoothed.clear();
    _smoothedConfidence.clear();
    return _enqueue(() async {
      await _releaseCamera();
      _notify();
    });
  }

  Future<void> _releaseCamera() async {
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_cameraChanged);
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } on CameraException {
        // 摄像头已被系统收回时仍继续释放控制器。
      }
      await controller.dispose();
    }
    await _processing;
  }

  @override
  Future<void> close() {
    if (_closed) return _operations;
    _closed = true;
    _generation++;
    return _enqueue(() async {
      await _releaseCamera();
      await _detector.close();
    });
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  String _describeError(Object error) {
    if (error is CameraException) {
      if (error.code.contains('AccessDenied') ||
          error.code.contains('AccessRestricted')) {
        return '摄像头权限未开启，请在系统设置中允许访问';
      }
      return '摄像头不可用，请重试';
    }
    if (error is FormatException) return error.message;
    return '人体识别暂不可用，请重试';
  }
}
