import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/domain/ems_protocol.dart';
import 'package:safety_margin/domain/ems_waveform.dart';

void main() {
  test('App 180 级强度映射到设备 276 级', () {
    expect(EmsProtocol.toDeviceIntensity(0), 0);
    expect(EmsProtocol.toDeviceIntensity(90), 138);
    expect(EmsProtocol.toDeviceIntensity(180), 276);
    expect(() => EmsProtocol.toDeviceIntensity(181), throwsRangeError);
  });

  test('蓝牙名称识别代次，未知名称按二代处理', () {
    expect(EmsProtocol.detectGeneration('YYC-DJ-V2-1234'), EmsGeneration.second);
    expect(EmsProtocol.detectGeneration('YYC-DJ-5678'), EmsGeneration.first);
    expect(EmsProtocol.detectGeneration('yyc-dj-v2'), EmsGeneration.second);
    expect(EmsProtocol.detectGeneration('未知设备'), EmsGeneration.second);
  });

  test('一代固定模式报文拆成 A、B 两条独立指令', () {
    const base = EmsConfig(
      generation: EmsGeneration.first,
      intensityA: 180,
      intensityB: 90,
      waveform: 1,
    );
    expect(EmsProtocol.fixedModePacket(base, enabled: true), [
      [0x35, 0x11, 0x01, 0x01, 0x01, 0x14, 0x01, 0, 0, 0x5E],
      [0x35, 0x11, 0x02, 0x01, 0x00, 0x8A, 0x01, 0, 0, 0xD4],
    ]);
    expect(EmsProtocol.fixedModePacket(base, enabled: false), [
      [0x35, 0x11, 0x01, 0, 0, 0, 0, 0, 0, 0x47],
      [0x35, 0x11, 0x02, 0, 0, 0, 0, 0, 0, 0x48],
    ]);
  });

  test('二代固定模式报文单包携带 A、B 各自强度', () {
    const base = EmsConfig(
      generation: EmsGeneration.second,
      intensityA: 180,
      intensityB: 90,
      waveform: 2,
    );
    expect(EmsProtocol.fixedModePacket(base, enabled: true), [
      [0x35, 0x11, 0x01, 0x01, 0x14, 0x02, 0x00, 0x8A, 0x02, 0xEA],
    ]);
    expect(EmsProtocol.fixedModePacket(base, enabled: false), [
      [0x35, 0x11, 0x01, 0, 0, 0x02, 0, 0, 0x02, 0x4B],
    ]);
  });

  test('查询、通道、电量和异常通知解析', () {
    expect(EmsProtocol.queryPacket(4), [0x35, 0x71, 0x04, 0xAA]);
    final channel =
        EmsProtocol.parseNotification([
              0x35,
              0x71,
              0x01,
              0x02,
              0x00,
              0x01,
              0x14,
              0x03,
              0xC1,
            ])
            as EmsChannelNotification;
    expect(channel.status.channel, EmsChannel.a);
    expect(channel.status.electrodeAttached, isTrue);
    expect(channel.status.enabled, isFalse);
    expect(channel.status.deviceIntensity, 276);
    expect(channel.status.mode, 3);
    expect(
      (EmsProtocol.parseNotification([0x35, 0x71, 0x04, 88, 0x02])
              as EmsBatteryNotification)
          .percent,
      88,
    );
    expect(
      (EmsProtocol.parseNotification([0x35, 0x71, 0x55, 4, 0xFF])
              as EmsErrorNotification)
          .code,
      4,
    );
    expect(EmsProtocol.parseNotification([0x35, 0x71, 0x04, 88, 0]), isNull);
  });

  test('EMS 设置存储还原并拒绝越界值', () {
    const config = EmsConfig(
      generation: EmsGeneration.first,
      intensityA: 135,
      intensityB: 60,
      waveform: 3,
      intensityRampPerSecond: 20,
    );
    expect(EmsConfig.fromJson(config.toJson()).toJson(), config.toJson());
    expect(
      () => EmsConfig.fromJson({...config.toJson(), 'intensityA': 181}),
      throwsFormatException,
    );
    expect(
      () => EmsConfig.fromJson({...config.toJson(), 'waveform': 4}),
      throwsFormatException,
    );
    expect(
      () => EmsConfig.fromJson({
        ...config.toJson(),
        'intensityRampPerSecond': -1,
      }),
      throwsFormatException,
    );
  });

  test('波形曲线渐变帧：一代自定义模式拆两条指令，二代实时模式单包', () {
    const step = EmsWaveformStep(frequency: 30, pulseWidth: 50);
    const first = EmsConfig(
      generation: EmsGeneration.first,
      intensityA: 180,
      intensityB: 0,
      waveform: 1,
    );
    expect(EmsProtocol.customStepPacket(first, step), [
      [0x35, 0x11, 0x01, 0x01, 0x01, 0x14, 0x11, 0x1E, 0x32, 0xBE],
      [0x35, 0x11, 0x02, 0, 0, 0, 0, 0, 0, 0x48],
    ]);
    const second = EmsConfig(
      generation: EmsGeneration.second,
      intensityA: 180,
      intensityB: 90,
      waveform: 2,
    );
    expect(EmsProtocol.customStepPacket(second, step), [
      [
        0x35,
        0x11,
        0x02,
        0x01,
        0x14,
        0x1E,
        0x32,
        0x00,
        0x8A,
        0x1E,
        0x32,
        0x87,
      ],
    ]);
  });
}
