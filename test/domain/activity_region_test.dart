import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/domain/activity_region.dart';

void main() {
  group('活动区域', () {
    final rect = ActivityRegion.rectangle(
      const Offset(.2, .2),
      const Offset(.8, .8),
    );
    test('区域内、外和边界', () {
      expect(rect.contains(const Offset(.5, .5)), isTrue);
      expect(rect.contains(const Offset(.1, .5)), isFalse);
      expect(rect.contains(const Offset(.2, .5)), isTrue);
      expect(rect.contains(const Offset(.8, .8)), isTrue);
      expect(rect.contains(const Offset(double.nan, .5)), isFalse);
    });
    test('容错边距吸收贴边抖动，超出边距仍判越界', () {
      expect(rect.containsWithMargin(const Offset(.5, .5), .02), isTrue);
      // 刚跨出边界线但在容错边距内，仍算区域内。
      expect(rect.containsWithMargin(const Offset(.19, .5), .02), isTrue);
      // 超出容错边距，判定为真正越界。
      expect(rect.containsWithMargin(const Offset(.15, .5), .02), isFalse);
      // 容错边距为 0 时退化为普通 contains。
      expect(rect.containsWithMargin(const Offset(.19, .5), 0), isFalse);
      expect(rect.containsWithMargin(const Offset(double.nan, .5), .02), isFalse);
    });
    test('反向拖动矩形，调整四角', () {
      final reverse = ActivityRegion.rectangle(
        const Offset(.8, .8),
        const Offset(.2, .2),
      );
      expect(reverse.points, rect.points);
      for (var i = 0; i < 4; i++) {
        final resized = rect.resizeCorner(i, const Offset(.4, .4));
        expect(resized.contains(const Offset(.4, .4)), isTrue);
        expect(resized.points, contains(rect.points[(i + 2) % 4]));
      }
    });
    test('自由圈画取笔画包围盒，生成矩形区域', () {
      final region = ActivityRegion.freehand(const [
        Offset(.2, .3),
        Offset(.9, .1),
        Offset(.6, .8),
        Offset(.3, .5),
      ]);
      expect(region.mode, RegionMode.freehand);
      expect(
        region.points,
        const [
          Offset(.2, .1),
          Offset(.9, .1),
          Offset(.9, .8),
          Offset(.2, .8),
        ],
      );
      expect(region.contains(const Offset(.5, .5)), isTrue);
      expect(region.contains(const Offset(.1, .5)), isFalse);
    });
    test('拒绝过小、交叉和非有限区域', () {
      expect(
        () => ActivityRegion.rectangle(Offset.zero, const Offset(.01, .01)),
        throwsFormatException,
      );
      expect(
        () => ActivityRegion.freehand(const [
          Offset(.1, .1),
          Offset(.101, .101),
        ]),
        throwsFormatException,
      );
      expect(
        () => ActivityRegion.freehand(const [
          Offset(double.nan, 0),
          Offset(1, 0),
          Offset(1, 1),
        ]),
        throwsFormatException,
      );
      expect(() => ActivityRegion.freehand(const []), throwsFormatException);
    });
    test('区域存储还原', () {
      expect(ActivityRegion.fromJson(rect.toJson()).points, rect.points);
      final freehand = ActivityRegion.freehand(const [
        Offset(.1, .1),
        Offset(.9, .1),
        Offset(.5, .9),
      ]);
      expect(
        ActivityRegion.fromJson(freehand.toJson()).points,
        freehand.points,
      );
    });
  });

  group('图像坐标', () {
    test('传感器旋转 0/90/180/270 度', () {
      const size = Size(640, 480);
      const p = Offset(100, 200);
      expect(rotateRawPoint(p, size, 0), p);
      expect(rotateRawPoint(p, size, 90), const Offset(280, 100));
      expect(rotateRawPoint(p, size, 180), const Offset(540, 280));
      expect(rotateRawPoint(p, size, 270), const Offset(200, 540));
      expect(uprightImageSize(size, 90), const Size(480, 640));
      expect(uprightImageSize(size, 180), size);
    });
    for (final mirror in [false, true]) {
      test('裁剪、缩放与镜像往返 mirror=$mirror', () {
        final transform = PreviewTransform(
          imageSize: const Size(480, 640),
          viewport: const Size(300, 300),
          mirrored: mirror,
        );
        for (final point in [
          const Offset(.2, .4),
          const Offset(.8, .6),
          const Offset(.5, .5),
        ]) {
          final roundtrip = transform.fromViewport(transform.toViewport(point));
          expect(roundtrip.dx, closeTo(point.dx, 1e-9));
          expect(roundtrip.dy, closeTo(point.dy, 1e-9));
        }
        expect(
          transform.toViewport(const Offset(.5, .5)),
          const Offset(150, 150),
        );
        expect(transform.origin, const Offset(0, -50));
      });
    }
    test('前摄左右翻转仅一次', () {
      const transform = PreviewTransform(
        imageSize: Size(100, 200),
        viewport: Size(100, 200),
        mirrored: true,
      );
      expect(transform.toViewport(const Offset(.2, .3)), const Offset(80, 60));
    });
  });
}
