import 'dart:typed_data';

import 'ems_waveform.dart';

enum EmsGeneration { first, second }

enum EmsChannel { a, b }

class EmsConfig {
  const EmsConfig({
    this.generation = EmsGeneration.second,
    this.intensityA = 0,
    this.intensityB = 0,
    this.waveform = 1,
    this.intensityRampPerSecond = 0,
  });

  static const appMaxIntensity = 180;
  static const deviceMaxIntensity = 276;
  static const maxIntensityRampPerSecond = 180;

  final EmsGeneration generation;
  final int intensityA;
  final int intensityB;
  final int waveform;
  // 越界持续期间，A、B 通道强度在各自基础值上每秒叠加的增量，回到区域内立即清零。
  final int intensityRampPerSecond;

  bool get isValid =>
      intensityA >= 0 &&
      intensityA <= appMaxIntensity &&
      intensityB >= 0 &&
      intensityB <= appMaxIntensity &&
      waveform >= 1 &&
      waveform <= emsWaveformCurves.length &&
      intensityRampPerSecond >= 0 &&
      intensityRampPerSecond <= maxIntensityRampPerSecond;

  EmsConfig copyWith({
    EmsGeneration? generation,
    int? intensityA,
    int? intensityB,
    int? waveform,
    int? intensityRampPerSecond,
  }) => EmsConfig(
    generation: generation ?? this.generation,
    intensityA: intensityA ?? this.intensityA,
    intensityB: intensityB ?? this.intensityB,
    waveform: waveform ?? this.waveform,
    intensityRampPerSecond:
        intensityRampPerSecond ?? this.intensityRampPerSecond,
  );

  Map<String, Object> toJson() => {
    'generation': generation.name,
    'intensityA': intensityA,
    'intensityB': intensityB,
    'waveform': waveform,
    'intensityRampPerSecond': intensityRampPerSecond,
  };

  factory EmsConfig.fromJson(Map<String, dynamic> json) {
    final config = EmsConfig(
      generation: EmsGeneration.values.byName(json['generation'] as String),
      intensityA: json['intensityA'] as int,
      intensityB: json['intensityB'] as int,
      waveform: json['waveform'] as int,
      intensityRampPerSecond: json['intensityRampPerSecond'] as int,
    );
    if (!config.isValid) throw const FormatException('EMS 参数无效');
    return config;
  }
}

class EmsChannelStatus {
  const EmsChannelStatus({
    required this.channel,
    required this.connectionState,
    required this.enabled,
    required this.deviceIntensity,
    required this.mode,
  });

  final EmsChannel channel;
  final int connectionState;
  final bool enabled;
  final int deviceIntensity;
  final int mode;

  bool get electrodeAttached => connectionState != 0;
}

sealed class EmsNotification {
  const EmsNotification();
}

class EmsChannelNotification extends EmsNotification {
  const EmsChannelNotification(this.status);
  final EmsChannelStatus status;
}

class EmsBatteryNotification extends EmsNotification {
  const EmsBatteryNotification(this.percent);
  final int percent;
}

class EmsErrorNotification extends EmsNotification {
  const EmsErrorNotification(this.code);
  final int code;
}

abstract final class EmsProtocol {
  static const serviceUuid = '0000ff30-0000-1000-8000-00805f9b34fb';
  static const writeUuid = '0000ff31-0000-1000-8000-00805f9b34fb';
  static const notifyUuid = '0000ff32-0000-1000-8000-00805f9b34fb';

  /// 蓝牙名称区分代次：二代含 "YYC-DJ-V2"，一代仅含 "YYC-DJ"；无法识别时按二代处理。
  static EmsGeneration detectGeneration(String deviceName) {
    final name = deviceName.toUpperCase();
    if (name.contains('YYC-DJ-V2')) return EmsGeneration.second;
    if (name.contains('YYC-DJ')) return EmsGeneration.first;
    return EmsGeneration.second;
  }

  static int toDeviceIntensity(int appIntensity) {
    if (appIntensity < 0 || appIntensity > EmsConfig.appMaxIntensity) {
      throw RangeError.range(
        appIntensity,
        0,
        EmsConfig.appMaxIntensity,
        'appIntensity',
      );
    }
    if (appIntensity == 0) return 0;
    // UI 使用统一的 180 级，设备协议最高为 276 级。
    return (appIntensity *
            EmsConfig.deviceMaxIntensity /
            EmsConfig.appMaxIntensity)
        .round();
  }

  /// A、B 通道强度各自独立；一代协议一个包只能带一个通道的强度，
  /// 所以一代总是拆成两条指令分别下发，二代天然支持单包双通道。
  static List<Uint8List> fixedModePacket(
    EmsConfig config, {
    required bool enabled,
  }) {
    if (!config.isValid) throw const FormatException('EMS 参数无效');
    final strengthA = enabled ? toDeviceIntensity(config.intensityA) : 0;
    final strengthB = enabled ? toDeviceIntensity(config.intensityB) : 0;
    return switch (config.generation) {
      EmsGeneration.first => [
        _firstGenerationChannelPacket(
          0x01,
          strengthA,
          mode: config.waveform,
          frequency: 0,
          pulseWidth: 0,
        ),
        _firstGenerationChannelPacket(
          0x02,
          strengthB,
          mode: config.waveform,
          frequency: 0,
          pulseWidth: 0,
        ),
      ],
      EmsGeneration.second => [
        _secondGenerationPacket(config, strengthA, strengthB),
      ],
    };
  }

  /// 波形曲线渐变帧：一代走自定义模式 0x11，二代走实时模式 0x02。
  static List<Uint8List> customStepPacket(
    EmsConfig config,
    EmsWaveformStep step,
  ) {
    if (!config.isValid) throw const FormatException('EMS 参数无效');
    final strengthA = toDeviceIntensity(config.intensityA);
    final strengthB = toDeviceIntensity(config.intensityB);
    return switch (config.generation) {
      EmsGeneration.first => [
        _firstGenerationChannelPacket(
          0x01,
          strengthA,
          mode: 0x11,
          frequency: step.frequency,
          pulseWidth: step.pulseWidth,
        ),
        _firstGenerationChannelPacket(
          0x02,
          strengthB,
          mode: 0x11,
          frequency: step.frequency,
          pulseWidth: step.pulseWidth,
        ),
      ],
      EmsGeneration.second => [
        _secondGenerationCustomPacket(step, strengthA, strengthB),
      ],
    };
  }

  static Uint8List queryPacket(int type) {
    if (type < 1 || type > 6) throw RangeError.range(type, 1, 6, 'type');
    return _withChecksum([0x35, 0x71, type]);
  }

  static EmsNotification? parseNotification(List<int> packet) {
    if (packet.length < 4 || packet.first != 0x35 || !_checksumValid(packet)) {
      return null;
    }
    if (packet[1] != 0x71) return null;
    return switch (packet[2]) {
      0x01 when packet.length == 9 => EmsChannelNotification(
        _channelStatus(EmsChannel.a, packet),
      ),
      0x02 when packet.length == 9 => EmsChannelNotification(
        _channelStatus(EmsChannel.b, packet),
      ),
      0x04 when packet.length == 5 && packet[3] <= 100 =>
        EmsBatteryNotification(packet[3]),
      0x55 when packet.length == 5 => EmsErrorNotification(packet[3]),
      _ => null,
    };
  }

  static Uint8List _firstGenerationChannelPacket(
    int channelByte,
    int strength, {
    required int mode,
    required int frequency,
    required int pulseWidth,
  }) => _withChecksum([
    0x35,
    0x11,
    channelByte,
    strength == 0 ? 0x00 : 0x01,
    strength >> 8,
    strength & 0xFF,
    strength == 0 ? 0x00 : mode,
    strength == 0 ? 0x00 : frequency,
    strength == 0 ? 0x00 : pulseWidth,
  ]);

  static Uint8List _secondGenerationPacket(
    EmsConfig config,
    int strengthA,
    int strengthB,
  ) => _withChecksum([
    0x35,
    0x11,
    0x01,
    strengthA >> 8,
    strengthA & 0xFF,
    config.waveform,
    strengthB >> 8,
    strengthB & 0xFF,
    config.waveform,
  ]);

  static Uint8List _secondGenerationCustomPacket(
    EmsWaveformStep step,
    int strengthA,
    int strengthB,
  ) => _withChecksum([
    0x35,
    0x11,
    0x02,
    strengthA >> 8,
    strengthA & 0xFF,
    step.frequency,
    step.pulseWidth,
    strengthB >> 8,
    strengthB & 0xFF,
    step.frequency,
    step.pulseWidth,
  ]);

  static EmsChannelStatus _channelStatus(
    EmsChannel channel,
    List<int> packet,
  ) => EmsChannelStatus(
    channel: channel,
    connectionState: packet[3],
    enabled: packet[4] == 0x01,
    deviceIntensity: packet[5] << 8 | packet[6],
    mode: packet[7],
  );

  static Uint8List _withChecksum(List<int> bytes) => Uint8List.fromList([
    ...bytes,
    bytes.fold<int>(0, (sum, value) => sum + value) & 0xFF,
  ]);

  static bool _checksumValid(List<int> packet) =>
      packet.last ==
      (packet
              .take(packet.length - 1)
              .fold<int>(0, (sum, value) => sum + value) &
          0xFF);
}
