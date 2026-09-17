import 'dart:ui' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/domain/activity_region.dart';
import 'package:safety_margin/services/pose_camera.dart';

void main() {
  test('Android 检测器已旋转的坐标不能重复旋转', () {
    final point = normalizeDetectorPoint(
      point: const Offset(120, 160),
      rawSize: const Size(640, 480),
      rotation: 90,
      isIOS: false,
      frontCamera: false,
    );
    expect(point, const Offset(.25, .25));
  });
  test('iOS 竖屏图像保持方向，前摄先还原镜像后统一预览', () {
    final point = normalizeDetectorPoint(
      point: const Offset(120, 160),
      rawSize: const Size(480, 640),
      rotation: 90,
      isIOS: true,
      frontCamera: true,
    );
    expect(point, const Offset(.75, .25));
    const transform = PreviewTransform(
      imageSize: Size(480, 640),
      viewport: Size(480, 640),
      mirrored: true,
    );
    expect(transform.toViewport(point), const Offset(120, 160));
  });
  test('iOS 后摄不镜像', () {
    expect(
      normalizeDetectorPoint(
        point: const Offset(120, 160),
        rawSize: const Size(480, 640),
        rotation: 90,
        isIOS: true,
        frontCamera: false,
      ),
      const Offset(.25, .25),
    );
  });
}
