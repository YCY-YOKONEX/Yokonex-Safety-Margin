import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/domain/activity_region.dart';
import 'package:safety_margin/ui/app_theme.dart';
import 'package:safety_margin/ui/camera_stage.dart';
import '../support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mirrored in [false, true]) {
    test('所有模式的相机叠加层绘制实时人体骨架 mirror=$mirrored', () async {
      const size = ui.Size(300, 400);
      final transform = PreviewTransform(
        imageSize: size,
        viewport: size,
        mirrored: mirrored,
      );
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawColor(AppColors.camera, ui.BlendMode.src);
      PoseOverlayPainter(
        transform: transform,
        region: testRegion(),
        sample: fullPose(),
      ).paint(canvas, size);
      final picture = recorder.endRecording();
      final image = await picture.toImage(300, 400);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      int pixel(ui.Offset normalized) {
        final p = transform.toViewport(normalized);
        final index = (p.dy.floor() * 300 + p.dx.floor()) * 4;
        return 0xff000000 |
            bytes.getUint8(index) << 16 |
            bytes.getUint8(index + 1) << 8 |
            bytes.getUint8(index + 2);
      }

      expect(
        pixel(const ui.Offset(.98, .5)),
        isNot(AppColors.alert.toARGB32()),
      );
      expect(
        pixel(const ui.Offset(.72, .55)),
        isNot(AppColors.cyan.toARGB32()),
      );
      expect(pixel(const ui.Offset(.38, .28)), AppColors.aligned.toARGB32());
      expect(pixel(const ui.Offset(.1, .3)), AppColors.cage.toARGB32());
      image.dispose();
      picture.dispose();
    });
  }

  test('玩家画区渲染成向上收拢的伪 3D 笼子', () async {
    const size = ui.Size(300, 400);
    const background = ui.Color(0xff303030);
    const transform = PreviewTransform(imageSize: size, viewport: size);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(background, ui.BlendMode.src);
    PoseOverlayPainter(
      transform: transform,
      region: ActivityRegion.rectangle(
        const ui.Offset(.1, .2),
        const ui.Offset(.9, .9),
      ),
    ).paint(canvas, size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(300, 400);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

    bool hasColorNear(ui.Offset point, ui.Color color) {
      for (var y = point.dy.floor() - 2; y <= point.dy.floor() + 2; y++) {
        for (var x = point.dx.floor() - 2; x <= point.dx.floor() + 2; x++) {
          final index = (y * 300 + x) * 4;
          final pixel =
              0xff000000 |
              bytes.getUint8(index) << 16 |
              bytes.getUint8(index + 1) << 8 |
              bytes.getUint8(index + 2);
          if (pixel == color.toARGB32()) return true;
        }
      }
      return false;
    }

    // 左上顶点由底面角点朝正上方消失点收拢 22%。
    expect(hasColorNear(const ui.Offset(56.4, 53.6), AppColors.cage), isTrue);

    image.dispose();
    picture.dispose();
  });
}
