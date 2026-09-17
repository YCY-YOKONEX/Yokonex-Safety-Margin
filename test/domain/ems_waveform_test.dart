import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/domain/ems_waveform.dart';

void main() {
  const total = Duration(milliseconds: 800);

  test('起点稀疏、终点密集，脉宽随频率反向变化', () {
    for (final shape in EmsCurveShape.values) {
      final start = EmsWaveform.stepAt(shape, Duration.zero, total);
      final end = EmsWaveform.stepAt(shape, total, total);
      expect(start.frequency, EmsWaveform.minFrequency);
      expect(start.pulseWidth, EmsWaveform.maxPulseWidth);
      expect(end.frequency, EmsWaveform.maxFrequency);
      expect(end.pulseWidth, EmsWaveform.minPulseWidth);
    }
  });

  test('总时长为零时直接给出终点取值', () {
    final step = EmsWaveform.stepAt(
      EmsCurveShape.linear,
      Duration.zero,
      Duration.zero,
    );
    expect(step.frequency, EmsWaveform.maxFrequency);
    expect(step.pulseWidth, EmsWaveform.minPulseWidth);
  });

  test('线性曲线频率随时间匀速递增', () {
    final quarter = EmsWaveform.stepAt(
      EmsCurveShape.linear,
      total * 0.25,
      total,
    );
    final half = EmsWaveform.stepAt(EmsCurveShape.linear, total * 0.5, total);
    final threeQuarters = EmsWaveform.stepAt(
      EmsCurveShape.linear,
      total * 0.75,
      total,
    );
    expect(quarter.frequency, lessThan(half.frequency));
    expect(half.frequency, lessThan(threeQuarters.frequency));
    // 匀速：中点应接近首尾平均值。
    expect(
      half.frequency,
      closeTo(
        (EmsWaveform.minFrequency + EmsWaveform.maxFrequency) / 2,
        2,
      ),
    );
  });

  test('渐强(指数)曲线前段更稀疏、后段加速', () {
    final quarter = EmsWaveform.stepAt(
      EmsCurveShape.exponential,
      total * 0.25,
      total,
    );
    final half = EmsWaveform.stepAt(
      EmsCurveShape.exponential,
      total * 0.5,
      total,
    );
    final threeQuarters = EmsWaveform.stepAt(
      EmsCurveShape.exponential,
      total * 0.75,
      total,
    );
    final firstGap = half.frequency - quarter.frequency;
    final secondGap = threeQuarters.frequency - half.frequency;
    expect(secondGap, greaterThan(firstGap));
  });

  test('阶梯曲线在同一区间内保持不变，跨区间跳变', () {
    final early = EmsWaveform.stepAt(
      EmsCurveShape.stepped,
      total * 0.10,
      total,
    );
    final stillEarly = EmsWaveform.stepAt(
      EmsCurveShape.stepped,
      total * 0.20,
      total,
    );
    final nextPlateau = EmsWaveform.stepAt(
      EmsCurveShape.stepped,
      total * 0.30,
      total,
    );
    expect(early.frequency, stillEarly.frequency);
    expect(nextPlateau.frequency, greaterThan(early.frequency));
  });
}
