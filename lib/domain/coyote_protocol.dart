enum CoyoteChannel { a, b, both }

enum CoyoteWaveform { extrusion, bubble, rhythm, airWaves, dance, climb }

enum CoyoteConnectionMode {
  privateRelay,
  officialRelay,
  localNetwork,
  loopback,
}

enum CoyoteOutputDurationMode { untilRecovery, maximum }

class CoyoteWaveformData {
  const CoyoteWaveformData({
    required this.id,
    required this.label,
    required this.frames,
  });

  final CoyoteWaveform id;
  final String label;
  final List<String> frames;
}

/// V3 waveform frames published by the official dglab-kit package.
const coyoteWaveforms = <CoyoteWaveformData>[
  CoyoteWaveformData(
    id: CoyoteWaveform.extrusion,
    label: '挤压',
    frames: ['0A0A0A0A00000000', '0A0A0A0A64646464'],
  ),
  CoyoteWaveformData(
    id: CoyoteWaveform.bubble,
    label: '气泡',
    frames: ['2D2D2D2D00000000', '2D2D2D2D64646464'],
  ),
  CoyoteWaveformData(
    id: CoyoteWaveform.rhythm,
    label: '律动',
    frames: [
      '0A0A0A0A00000000',
      '0A0A0A0A32323232',
      '0A0A0A0A64646464',
      '0A0A0A0A00000000',
      '0A0A0A0A32323232',
      '0A0A0A0A64646464',
      '1919191964646464',
      '1D1D1D1D64646464',
      '2222222264646464',
      '2626262664646464',
      '2B2B2B2B64646464',
      '0A0A0A0A00000000',
      '0A0A0A0A00000000',
    ],
  ),
  CoyoteWaveformData(
    id: CoyoteWaveform.airWaves,
    label: '电波',
    frames: [
      '0A0A0A0A64646464',
      '1717171764646464',
      '2424242464646464',
      '3232323264646464',
      '0A0A0A0A00000000',
      '0A0A0A0A64646464',
      '0A0A0A0A00000000',
      '0A0A0A0A64646464',
      '0A0A0A0A00000000',
      '0A0A0A0A64646464',
      '0A0A0A0A00000000',
      '0A0A0A0A64646464',
      '0A0A0A0A00000000',
    ],
  ),
  CoyoteWaveformData(
    id: CoyoteWaveform.dance,
    label: '舞步',
    frames: [
      '0A0A0A0A00000000',
      '0A0A0A0A00000000',
      '0A0A0A0A64646464',
      '0A0A0A0A00000000',
      '0A0A0A0A00000000',
      '0A0A0A0A64646464',
      '0A0A0A0A00000000',
      '0A0A0A0A00000000',
      '0A0A0A0A64646464',
      '0A0A0A0A64646464',
      '0A0A0A0A64646464',
      '0A0A0A0A00000000',
      '0A0A0A0A00000000',
      '0A0A0A0A64646464',
      '0A0A0A0A64646464',
      '0A0A0A0A64646464',
    ],
  ),
  CoyoteWaveformData(
    id: CoyoteWaveform.climb,
    label: '攀登',
    frames: [
      '3030303032323232',
      '282828283C3C3C3C',
      '2020202046464646',
      '1919191950505050',
      '111111115A5A5A5A',
      '0A0A0A0A64646464',
    ],
  ),
];

class CoyoteConfig {
  const CoyoteConfig({
    this.channel = CoyoteChannel.a,
    this.waveform = CoyoteWaveform.extrusion,
    this.triggerIntensity = 5,
    this.maxIntensity = 20,
    this.duration = const Duration(seconds: 1),
    this.outputDurationMode = CoyoteOutputDurationMode.maximum,
    this.cooldown = const Duration(seconds: 3),
    this.directionalMapping = false,
    this.connectionMode = CoyoteConnectionMode.privateRelay,
    this.privateRelayUrl = defaultPrivateRelayUrl,
  });

  static const protocolMaxIntensity = 200;
  static const minDuration = Duration(milliseconds: 100);
  static const maxDuration = Duration(minutes: 5);
  static const protocolChunkDuration = Duration(seconds: 5);
  static const minCooldown = Duration(milliseconds: 500);
  static const maxCooldown = Duration(minutes: 1);
  static const testIntensityLimit = 3;
  static const testDurationLimit = Duration(milliseconds: 500);
  static const defaultPrivateRelayUrl =
      'wss://38.244.4.154.sslip.io:18444/dglab-v4';

  final CoyoteChannel channel;
  final CoyoteWaveform waveform;
  final int triggerIntensity;
  final int maxIntensity;
  final Duration duration;
  final CoyoteOutputDurationMode outputDurationMode;
  final Duration cooldown;
  final bool directionalMapping;
  final CoyoteConnectionMode connectionMode;
  final String privateRelayUrl;

  Uri? get privateRelayUri {
    final uri = Uri.tryParse(privateRelayUrl.trim());
    if (uri == null ||
        (uri.scheme != 'ws' && uri.scheme != 'wss') ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri;
  }

  bool get isValid =>
      triggerIntensity >= 0 &&
      triggerIntensity <= protocolMaxIntensity &&
      maxIntensity >= 1 &&
      maxIntensity <= protocolMaxIntensity &&
      duration >= minDuration &&
      duration <= maxDuration &&
      cooldown >= minCooldown &&
      cooldown <= maxCooldown &&
      (connectionMode != CoyoteConnectionMode.privateRelay ||
          privateRelayUri != null);

  CoyoteConfig copyWith({
    CoyoteChannel? channel,
    CoyoteWaveform? waveform,
    int? triggerIntensity,
    int? maxIntensity,
    Duration? duration,
    CoyoteOutputDurationMode? outputDurationMode,
    Duration? cooldown,
    bool? directionalMapping,
    CoyoteConnectionMode? connectionMode,
    String? privateRelayUrl,
  }) => CoyoteConfig(
    channel: channel ?? this.channel,
    waveform: waveform ?? this.waveform,
    triggerIntensity: triggerIntensity ?? this.triggerIntensity,
    maxIntensity: maxIntensity ?? this.maxIntensity,
    duration: duration ?? this.duration,
    outputDurationMode: outputDurationMode ?? this.outputDurationMode,
    cooldown: cooldown ?? this.cooldown,
    directionalMapping: directionalMapping ?? this.directionalMapping,
    connectionMode: connectionMode ?? this.connectionMode,
    privateRelayUrl: privateRelayUrl ?? this.privateRelayUrl,
  );

  Map<String, Object> toJson() => {
    'channel': channel.name,
    'waveform': waveform.name,
    'triggerIntensity': triggerIntensity,
    'maxIntensity': maxIntensity,
    'durationMilliseconds': duration.inMilliseconds,
    'outputDurationMode': outputDurationMode.name,
    'cooldownMilliseconds': cooldown.inMilliseconds,
    'directionalMapping': directionalMapping,
    'connectionMode': connectionMode.name,
    'privateRelayUrl': privateRelayUrl,
  };

  factory CoyoteConfig.fromJson(Map<String, dynamic> json) {
    final config = CoyoteConfig(
      channel: CoyoteChannel.values.byName(json['channel'] as String),
      waveform: CoyoteWaveform.values.byName(json['waveform'] as String),
      triggerIntensity: json['triggerIntensity'] as int,
      maxIntensity: json['maxIntensity'] as int,
      duration: Duration(milliseconds: json['durationMilliseconds'] as int),
      outputDurationMode: CoyoteOutputDurationMode.values.byName(
        json['outputDurationMode'] as String? ??
            CoyoteOutputDurationMode.maximum.name,
      ),
      cooldown: Duration(milliseconds: json['cooldownMilliseconds'] as int),
      directionalMapping: json['directionalMapping'] as bool? ?? false,
      connectionMode: CoyoteConnectionMode.values.byName(
        json['connectionMode'] as String? ??
            CoyoteConnectionMode.officialRelay.name,
      ),
      privateRelayUrl:
          json['privateRelayUrl'] as String? ?? defaultPrivateRelayUrl,
    );
    if (!config.isValid) throw const FormatException('郊狼参数无效');
    return config;
  }
}

class CoyoteDeviceInfo {
  const CoyoteDeviceInfo({
    required this.slotId,
    required this.name,
    required this.type,
    this.hasDevice = false,
    this.power,
    this.intensityA,
    this.intensityB,
    this.channelAStatus,
    this.channelBStatus,
  });

  final String slotId;
  final String name;
  final String type;
  final bool hasDevice;
  final int? power;
  final int? intensityA;
  final int? intensityB;
  final int? channelAStatus;
  final int? channelBStatus;

  CoyoteDeviceInfo copyWith({
    String? name,
    String? type,
    bool? hasDevice,
    int? power,
    int? intensityA,
    int? intensityB,
    int? channelAStatus,
    int? channelBStatus,
  }) => CoyoteDeviceInfo(
    slotId: slotId,
    name: name ?? this.name,
    type: type ?? this.type,
    hasDevice: hasDevice ?? this.hasDevice,
    power: power ?? this.power,
    intensityA: intensityA ?? this.intensityA,
    intensityB: intensityB ?? this.intensityB,
    channelAStatus: channelAStatus ?? this.channelAStatus,
    channelBStatus: channelBStatus ?? this.channelBStatus,
  );
}
