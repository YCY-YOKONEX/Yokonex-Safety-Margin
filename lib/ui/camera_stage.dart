import 'package:camera/camera.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app/game_coordinator.dart';
import '../domain/activity_region.dart';
import '../domain/game_engine.dart';
import '../domain/game_mode.dart';
import '../domain/pose_sample.dart';
import 'app_localizations.dart';
import 'app_theme.dart';

class CameraStage extends StatefulWidget {
  const CameraStage({super.key, required this.coordinator});
  final GameCoordinator coordinator;

  @override
  State<CameraStage> createState() => _CameraStageState();
}

class _CameraStageState extends State<CameraStage> {
  final List<Offset> _stroke = [];
  Offset? _anchor;
  ActivityRegion? _draft;
  bool _drawing = false;
  int? _pointer;

  GameCoordinator get c => widget.coordinator;

  void _start(PointerDownEvent details, PreviewTransform transform) {
    if (_pointer != null) return;
    _pointer = details.pointer;
    final point = transform.fromViewport(details.localPosition);
    _stroke
      ..clear()
      ..add(point);
    _anchor = point;
    _draft = null;
    if (c.drawingMode == RegionMode.rectangle &&
        c.region?.mode == RegionMode.rectangle) {
      final points = c.region!.points;
      for (var i = 0; i < 4; i++) {
        if ((transform.toViewport(points[i]) - details.localPosition).distance <
            26) {
          _anchor = points[(i + 2) % 4];
          _draft = c.region;
          break;
        }
      }
    }
    _drawing = true;
    c.beginDrawing();
    setState(() {});
  }

  void _update(PointerMoveEvent details, PreviewTransform transform) {
    if (!_drawing || !c.editing || details.pointer != _pointer) return;
    final point = transform.fromViewport(details.localPosition);
    if (c.drawingMode == RegionMode.rectangle) {
      try {
        _draft = ActivityRegion.rectangle(_anchor!, point);
      } on FormatException {
        _draft = null;
      }
      _stroke
        ..clear()
        ..addAll([_anchor!, point]);
    } else if (_stroke.length < 1000 &&
        (_stroke.last - point).distance >= .004) {
      _stroke.add(point);
    }
    setState(() {});
  }

  void _end() {
    if (!_drawing) return;
    ActivityRegion? value;
    if (c.editing) {
      try {
        value = c.drawingMode == RegionMode.freehand
            ? ActivityRegion.freehand(_stroke)
            : _draft;
        if (value == null) throw const FormatException('区域太小，请重新画区');
      } on FormatException catch (error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.message(error.message))),
        );
      }
    }
    _drawing = false;
    _pointer = null;
    _stroke.clear();
    _draft = null;
    c.endDrawing(value);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final camera = c.camera;
    final editable =
        c.engine.phase == GamePhase.ready &&
        c.engine.config.mode.requiresRegion &&
        camera.ready &&
        !c.loading;
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final transform = PreviewTransform(
              imageSize: camera.imageSize,
              viewport: constraints.biggest,
              mirrored: camera.mirrored,
            );
            final controller = camera.previewController;
            return Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: AppColors.camera),
                if (controller != null && controller.value.isInitialized)
                  FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: camera.imageSize.width,
                      height: camera.imageSize.height,
                      child: CameraPreview(controller),
                    ),
                  ),
                RawGestureDetector(
                  // 画区时立即接管手势，防止斜向拖动被外层页面滚动抢走。
                  gestures: editable
                      ? {
                          EagerGestureRecognizer:
                              GestureRecognizerFactoryWithHandlers<
                                EagerGestureRecognizer
                              >(EagerGestureRecognizer.new, (_) {}),
                        }
                      : const {},
                  child: Listener(
                    key: const ValueKey('region_canvas'),
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: editable
                        ? (event) => _start(event, transform)
                        : null,
                    onPointerMove: editable
                        ? (event) => _update(event, transform)
                        : null,
                    onPointerUp: (event) {
                      if (event.pointer == _pointer) _end();
                    },
                    onPointerCancel: (event) {
                      if (event.pointer != _pointer) return;
                      _pointer = null;
                      _drawing = false;
                      _stroke.clear();
                      _draft = null;
                      c.endDrawing(null);
                    },
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: PoseOverlayPainter(
                          transform: transform,
                          sample: c.sample,
                          region: c.editing
                              ? _draft ?? c.region
                              : c.displayRegion,
                          obstacle: c.obstacle,
                          dualZones: c.dualZones,
                          customPose: c.customPoseTemplate,
                          stroke: _drawing && c.editing ? _stroke : const [],
                          mode: c.drawingMode,
                          showHandles:
                              editable && c.drawingMode == RegionMode.rectangle,
                        ),
                      ),
                    ),
                  ),
                ),
                if (camera.initializing || c.loading)
                  const Center(
                    child: CircularProgressIndicator(color: AppColors.cyan),
                  ),
                if (camera.error != null)
                  ColoredBox(
                    color: AppColors.camera.withValues(alpha: .94),
                    child: Center(
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.no_photography_outlined,
                                size: 36,
                                color: AppColors.yellow,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                context.l10n.message(camera.error!),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  height: 1.5,
                                ),
                              ),
                              const SizedBox(height: 16),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: c.retryCamera,
                                icon: const Icon(Icons.refresh),
                                label: Text(context.l10n.text('重试')),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (c.engine.phase == GamePhase.paused && camera.error == null)
                  Positioned(
                    bottom: 16,
                    left: 16,
                    child: _CameraBadge(
                      label: context.l10n.text('已暂停'),
                      icon: Icons.pause,
                      color: AppColors.yellow,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CameraBadge extends StatelessWidget {
  const _CameraBadge({
    required this.label,
    required this.icon,
    this.color = Colors.white,
  });
  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.camera.withValues(alpha: .8),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: icon == Icons.circle ? 8 : 15, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: color, fontSize: 12, letterSpacing: 0),
          ),
        ],
      ),
    ),
  );
}

class PoseOverlayPainter extends CustomPainter {
  PoseOverlayPainter({
    required this.transform,
    required this.region,
    this.sample,
    this.obstacle,
    this.dualZones,
    this.customPose,
    this.stroke = const [],
    this.mode = RegionMode.freehand,
    this.showHandles = false,
  });
  final PreviewTransform transform;
  final ActivityRegion? region;
  final PoseSample? sample;
  final Rect? obstacle;
  final (ActivityRegion, ActivityRegion)? dualZones;
  final CustomPoseTemplate? customPose;
  final List<Offset> stroke;
  final RegionMode mode;
  final bool showHandles;

  Path _path(List<Offset> points, {bool close = true}) {
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final point = transform.toViewport(points[i]);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    if (close) path.close();
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (region != null) {
      final path = _path(region!.points);
      final outside = Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        path,
      );
      canvas.drawPath(
        outside,
        Paint()..color = Colors.black.withValues(alpha: .25),
      );
      canvas.drawPath(
        path,
        Paint()..color = AppColors.cage.withValues(alpha: .05),
      );

      // 底面是真实判定边界，顶部朝正上方消失点收拢，形成正对玩家的伪 3D 笼子。
      // 立柱和密集栏杆只负责视觉表现，不参与越界判定。
      final basePoints = [
        for (final p in region!.points) transform.toViewport(p),
      ];
      final center =
          basePoints.reduce((a, b) => a + b) / basePoints.length.toDouble();
      final vanishingPoint = Offset(center.dx, center.dy - size.height * .65);
      const convergence = .22;
      final topPoints = [
        for (final p in basePoints)
          Offset.lerp(p, vanishingPoint, convergence)!,
      ];
      final topPath = Path();
      for (var i = 0; i < topPoints.length; i++) {
        if (i == 0) {
          topPath.moveTo(topPoints[i].dx, topPoints[i].dy);
        } else {
          topPath.lineTo(topPoints[i].dx, topPoints[i].dy);
        }
      }
      topPath.close();

      final barPaint = Paint()
        ..color = AppColors.cage.withValues(alpha: .6)
        ..strokeWidth = 1.2;
      const barSpacing = 16.0;
      for (var i = 0; i < basePoints.length; i++) {
        final a = basePoints[i];
        final b = basePoints[(i + 1) % basePoints.length];
        final topA = topPoints[i];
        final topB = topPoints[(i + 1) % basePoints.length];
        final barCount = ((b - a).distance / barSpacing).round().clamp(2, 40);
        for (var j = 1; j < barCount; j++) {
          final t = j / barCount;
          canvas.drawLine(
            Offset.lerp(a, b, t)!,
            Offset.lerp(topA, topB, t)!,
            barPaint,
          );
        }
      }

      canvas.drawPath(
        topPath,
        Paint()..color = AppColors.cage.withValues(alpha: .1),
      );
      final structurePaint = Paint()
        ..color = AppColors.cage
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawPath(path, structurePaint);
      canvas.drawPath(topPath, structurePaint);
      for (var i = 0; i < basePoints.length; i++) {
        canvas.drawLine(basePoints[i], topPoints[i], structurePaint);
      }

      if (showHandles && region!.mode == RegionMode.rectangle) {
        for (final p in region!.points) {
          canvas.drawRect(
            Rect.fromCenter(
              center: transform.toViewport(p),
              width: 11,
              height: 11,
            ),
            Paint()..color = Colors.white,
          );
        }
      }
    }
    if (dualZones case final zones?) {
      _paintZone(canvas, zones.$1, 'A', AppColors.cyan);
      _paintZone(canvas, zones.$2, 'B', AppColors.yellow);
    }
    if (obstacle case final rect?) {
      final viewportRect = Rect.fromPoints(
        transform.toViewport(rect.topLeft),
        transform.toViewport(rect.bottomRight),
      );
      canvas.drawRect(
        viewportRect,
        Paint()..color = AppColors.alert.withValues(alpha: .24),
      );
      canvas.drawRect(
        viewportRect,
        Paint()
          ..color = AppColors.alert
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
      canvas.drawLine(
        viewportRect.topLeft,
        viewportRect.bottomRight,
        Paint()
          ..color = AppColors.alert
          ..strokeWidth = 2,
      );
      canvas.drawLine(
        viewportRect.topRight,
        viewportRect.bottomLeft,
        Paint()
          ..color = AppColors.alert
          ..strokeWidth = 2,
      );
    }
    if (sample case final pose?) {
      _paintDetectedPose(canvas, pose);
    }
    if (customPose case final template?) {
      _paintCustomPose(canvas, template);
    }
    if (stroke.isNotEmpty) {
      final path = mode == RegionMode.rectangle && stroke.length == 2
          ? (Path()..addRect(
              Rect.fromPoints(
                transform.toViewport(stroke.first),
                transform.toViewport(stroke.last),
              ),
            ))
          : _path(stroke, close: false);
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  void _paintDetectedPose(Canvas canvas, PoseSample pose) {
    if (!pose.personDetected) return;
    final linePaint = Paint()
      ..color = AppColors.aligned.withValues(alpha: .95)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: .68)
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    for (final edge in skeletonEdges) {
      final a = pose.landmarks[edge.$1];
      final b = pose.landmarks[edge.$2];
      if (a == null || b == null || !a.isReliable || !b.isReliable) continue;
      final start = transform.toViewport(a.position);
      final end = transform.toViewport(b.position);
      canvas.drawLine(start, end, shadowPaint);
      canvas.drawLine(start, end, linePaint);
    }
    for (final entry in pose.landmarks.entries) {
      if (!entry.value.isReliable) continue;
      final point = transform.toViewport(entry.value.position);
      canvas.drawCircle(point, 6, Paint()..color = Colors.black87);
      canvas.drawCircle(point, 4, Paint()..color = AppColors.aligned);
    }
  }

  void _paintZone(
    Canvas canvas,
    ActivityRegion zone,
    String label,
    Color color,
  ) {
    final path = _path(zone.points);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: .10));
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: .85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: 22,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final center = transform.toViewport(zone.bounds.center);
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  void _paintCustomPose(Canvas canvas, CustomPoseTemplate template) {
    final linePaint = Paint()
      ..color = AppColors.yellow.withValues(alpha: .82)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    for (final edge in customPoseEdges) {
      canvas.drawLine(
        transform.toViewport(template.points[edge.$1]!),
        transform.toViewport(template.points[edge.$2]!),
        linePaint,
      );
    }
    final head = transform.toViewport(template.points[Joint.nose]!);
    canvas.drawCircle(
      head,
      18,
      Paint()
        ..color = AppColors.yellow.withValues(alpha: .16)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      head,
      18,
      Paint()
        ..color = AppColors.yellow
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    for (final joint in customPoseJoints.where(
      (joint) => joint != Joint.nose,
    )) {
      canvas.drawCircle(
        transform.toViewport(template.points[joint]!),
        6,
        Paint()..color = AppColors.yellow,
      );
    }
  }

  @override
  bool shouldRepaint(covariant PoseOverlayPainter oldDelegate) => true;
}
