import 'dart:math' as math;
import 'dart:ui';

enum RegionMode { freehand, rectangle }

class ActivityRegion {
  ActivityRegion._(this.mode, List<Offset> points)
    : points = List.unmodifiable(points);

  /// 自由圈画只用来确定大致范围，最终取笔画的包围盒生成矩形区域。
  factory ActivityRegion.freehand(List<Offset> stroke) {
    if (stroke.isEmpty) throw const FormatException('区域太小，请重新画区');
    if (stroke.any((p) => !p.dx.isFinite || !p.dy.isFinite)) {
      throw const FormatException('区域无效，请重新画区');
    }
    var bounds = Rect.fromPoints(stroke.first, stroke.first);
    for (final point in stroke) {
      bounds = bounds.expandToInclude(Rect.fromPoints(point, point));
    }
    return ActivityRegion._validated(RegionMode.freehand, [
      bounds.topLeft,
      bounds.topRight,
      bounds.bottomRight,
      bounds.bottomLeft,
    ]);
  }

  factory ActivityRegion.rectangle(Offset a, Offset b) {
    final rect = Rect.fromPoints(a, b);
    return ActivityRegion._validated(RegionMode.rectangle, [
      rect.topLeft,
      rect.topRight,
      rect.bottomRight,
      rect.bottomLeft,
    ]);
  }

  factory ActivityRegion._validated(RegionMode mode, List<Offset> points) {
    if (points.length < 3 ||
        points.length > 1000 ||
        points.any(
          (p) =>
              !p.dx.isFinite ||
              !p.dy.isFinite ||
              p.dx < 0 ||
              p.dx > 1 ||
              p.dy < 0 ||
              p.dy > 1,
        )) {
      throw const FormatException('区域无效，请重新画区');
    }
    var twiceArea = 0.0;
    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      final b = points[(i + 1) % points.length];
      twiceArea += a.dx * b.dy - b.dx * a.dy;
    }
    if (twiceArea.abs() / 2 < 0.0025) {
      throw const FormatException('区域太小，请重新画区');
    }
    // 自由圈画只接受简单闭合区域，避免交叉边界产生歧义。
    for (var i = 0; i < points.length; i++) {
      for (var j = i + 1; j < points.length; j++) {
        if (j == i + 1 || (i == 0 && j == points.length - 1)) continue;
        if (_intersects(
          points[i],
          points[(i + 1) % points.length],
          points[j],
          points[(j + 1) % points.length],
        )) {
          throw const FormatException('边界交叉，请重新画区');
        }
      }
    }
    return ActivityRegion._(mode, points);
  }

  final RegionMode mode;
  final List<Offset> points;

  Rect get bounds {
    var result = Rect.fromPoints(points.first, points.first);
    for (final point in points.skip(1)) {
      result = result.expandToInclude(Rect.fromPoints(point, point));
    }
    return result;
  }

  ActivityRegion scaled(double factor) {
    final safeFactor = factor.clamp(.05, 1.0);
    final center = bounds.center;
    return ActivityRegion._validated(mode, [
      for (final point in points) center + (point - center) * safeFactor,
    ]);
  }

  bool contains(Offset point) {
    if (!point.dx.isFinite || !point.dy.isFinite) return false;
    var inside = false;
    for (var i = 0, j = points.length - 1; i < points.length; j = i++) {
      final a = points[j];
      final b = points[i];
      if (_onSegment(a, b, point)) return true;
      if ((a.dy > point.dy) != (b.dy > point.dy) &&
          point.dx < (b.dx - a.dx) * (point.dy - a.dy) / (b.dy - a.dy) + a.dx) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// 越界判定加一圈容错边距：刚跨出边界线但仍在 [margin] 距离内的点仍算区域内，
  /// 用来吸收人物贴着边界站立时的姿态估计抖动，而不是靠时间延迟去过滤。
  bool containsWithMargin(Offset point, double margin) {
    if (contains(point)) return true;
    if (margin <= 0 || !point.dx.isFinite || !point.dy.isFinite) return false;
    for (var i = 0, j = points.length - 1; i < points.length; j = i++) {
      if (_distanceToSegment(point, points[j], points[i]) <= margin) {
        return true;
      }
    }
    return false;
  }

  ActivityRegion resizeCorner(int corner, Offset position) {
    if (mode != RegionMode.rectangle || corner < 0 || corner > 3) {
      throw ArgumentError('只能调整矩形四角');
    }
    return ActivityRegion.rectangle(points[(corner + 2) % 4], position);
  }

  Map<String, Object> toJson() => {
    'mode': mode.name,
    'points': points.map((p) => [p.dx, p.dy]).toList(),
  };

  factory ActivityRegion.fromJson(Map<String, dynamic> json) {
    final mode = RegionMode.values.byName(json['mode'] as String);
    final points = (json['points'] as List).map((value) {
      final pair = value as List;
      return Offset((pair[0] as num).toDouble(), (pair[1] as num).toDouble());
    }).toList();
    if (mode == RegionMode.rectangle) {
      if (points.length != 4) throw const FormatException('矩形无效');
      return ActivityRegion.rectangle(points[0], points[2]);
    }
    return ActivityRegion._validated(mode, points);
  }

  static double _cross(Offset a, Offset b, Offset c) =>
      (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);

  static bool _onSegment(Offset a, Offset b, Offset p) =>
      _cross(a, b, p).abs() < 1e-7 &&
      p.dx >= math.min(a.dx, b.dx) - 1e-7 &&
      p.dx <= math.max(a.dx, b.dx) + 1e-7 &&
      p.dy >= math.min(a.dy, b.dy) - 1e-7 &&
      p.dy <= math.max(a.dy, b.dy) + 1e-7;

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lengthSquared == 0) return (p - a).distance;
    final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lengthSquared)
        .clamp(0.0, 1.0);
    return (p - Offset(a.dx + ab.dx * t, a.dy + ab.dy * t)).distance;
  }

  static bool _intersects(Offset a, Offset b, Offset c, Offset d) =>
      (_cross(a, b, c) * _cross(a, b, d) < 0 &&
          _cross(c, d, a) * _cross(c, d, b) < 0) ||
      _onSegment(a, b, c) ||
      _onSegment(a, b, d) ||
      _onSegment(c, d, a) ||
      _onSegment(c, d, b);
}

/// 检测点统一为未镜像、正向图像坐标；预览裁剪和镜像只在此处转换。
class PreviewTransform {
  const PreviewTransform({
    required this.imageSize,
    required this.viewport,
    this.mirrored = false,
  });

  final Size imageSize;
  final Size viewport;
  final bool mirrored;

  double get scale => math.max(
    viewport.width / imageSize.width,
    viewport.height / imageSize.height,
  );
  Size get renderedSize => imageSize * scale;
  Offset get origin => Offset(
    (viewport.width - renderedSize.width) / 2,
    (viewport.height - renderedSize.height) / 2,
  );

  Offset toViewport(Offset normalized) =>
      origin +
      Offset(
        (mirrored ? 1 - normalized.dx : normalized.dx) * renderedSize.width,
        normalized.dy * renderedSize.height,
      );

  Offset fromViewport(Offset position) {
    final x = ((position.dx - origin.dx) / renderedSize.width).clamp(0.0, 1.0);
    final y = ((position.dy - origin.dy) / renderedSize.height).clamp(0.0, 1.0);
    return Offset(mirrored ? 1 - x : x, y);
  }
}

Size uprightImageSize(Size rawSize, int rotation) =>
    rotation == 90 || rotation == 270 ? rawSize.flipped : rawSize;

Offset rotateRawPoint(Offset point, Size rawSize, int rotation) =>
    switch (rotation) {
      0 => point,
      90 => Offset(rawSize.height - point.dy, point.dx),
      180 => Offset(rawSize.width - point.dx, rawSize.height - point.dy),
      270 => Offset(point.dy, rawSize.width - point.dx),
      _ => throw ArgumentError.value(rotation, 'rotation'),
    };
