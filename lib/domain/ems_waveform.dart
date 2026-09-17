import 'dart:math' as math;

enum EmsCurveShape { linear, exponential, stepped }

class EmsWaveformCurve {
  const EmsWaveformCurve(this.id, this.label, this.shape);

  final int id;
  final String label;
  final EmsCurveShape shape;
}

const emsWaveformCurves = <EmsWaveformCurve>[
  EmsWaveformCurve(1, '线性递增', EmsCurveShape.linear),
  EmsWaveformCurve(2, '渐强递增', EmsCurveShape.exponential),
  EmsWaveformCurve(3, '阶梯递增', EmsCurveShape.stepped),
];

class EmsWaveformStep {
  const EmsWaveformStep({required this.frequency, required this.pulseWidth});

  /// 设备频率字节，1-100 对应 1Hz-100Hz。
  final int frequency;

  /// 设备脉宽字节，0-100 对应 0us-100us。
  final int pulseWidth;
}

abstract final class EmsWaveform {
  static const minFrequency = 2;
  static const maxFrequency = 60;
  static const minPulseWidth = 15;
  static const maxPulseWidth = 80;
  static const _steppedPlateaus = 4;
  static const _exponentialSharpness = 3.0;

  static EmsWaveformStep stepAt(
    EmsCurveShape shape,
    Duration elapsed,
    Duration total,
  ) {
    final t = total.inMicroseconds <= 0
        ? 1.0
        : (elapsed.inMicroseconds / total.inMicroseconds).clamp(0.0, 1.0);
    final shaped = _shape(shape, t);
    final frequency = (minFrequency + (maxFrequency - minFrequency) * shaped)
        .round()
        .clamp(1, 100);
    final pulseWidth =
        (maxPulseWidth - (maxPulseWidth - minPulseWidth) * shaped)
            .round()
            .clamp(0, 100);
    return EmsWaveformStep(frequency: frequency, pulseWidth: pulseWidth);
  }

  static double _shape(EmsCurveShape shape, double t) => switch (shape) {
    EmsCurveShape.linear => t,
    EmsCurveShape.exponential =>
      (math.exp(t * _exponentialSharpness) - 1) /
          (math.exp(_exponentialSharpness) - 1),
    EmsCurveShape.stepped =>
      (t * _steppedPlateaus).floorToDouble() / _steppedPlateaus,
  };
}
