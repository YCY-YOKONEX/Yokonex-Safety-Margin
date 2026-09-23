import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../domain/coyote_protocol.dart';
import '../domain/game_engine.dart';
import '../domain/pose_sample.dart';
import 'coyote_transport.dart';

enum CoyoteConnectionPhase {
  idle,
  connecting,
  waitingForScan,
  waitingForDevice,
  connected,
  disconnected,
  error,
}

class CoyoteDeviceController extends ChangeNotifier implements TriggerSink {
  CoyoteDeviceController({CoyoteTransport? transport, DateTime Function()? now})
    : _transport = transport ?? AdaptiveCoyoteTransport(),
      _now = now ?? DateTime.now;

  static final relayUri = Uri.parse('wss://trex.dungeon-lab.cn/v4');
  static const _helloTimeout = Duration(seconds: 8);
  static const _pingInterval = Duration(seconds: 2);
  static const _maxMissedPongs = 3;

  final CoyoteTransport _transport;
  final DateTime Function() _now;
  StreamSubscription<CoyoteTransportEvent>? _subscription;
  Timer? _helloTimer;
  Timer? _pingTimer;
  Timer? _safetyStopTimer;
  Timer? _outputRefreshTimer;
  Future<void> _commands = Future.value();
  int _requestSequence = 0;
  int _missedPongs = 0;
  int _outputToken = 0;
  bool _disposed = false;
  bool _closing = false;
  DateTime? _lastTriggerAt;
  DateTime? _lastTestAt;
  String? _targetId;
  String? _clientId;
  final Map<String, CoyoteDeviceInfo> _devices = {};

  CoyoteConfig config = const CoyoteConfig();
  CoyoteConnectionPhase phase = CoyoteConnectionPhase.idle;
  String? error;
  void Function(String message)? onFault;

  String? get pairingUrl {
    final appSocket = pairingSocketUri;
    if (appSocket == null) return null;
    return Uri.https('dungeon-lab.cn', '/s/', {
      'v': '1',
      'action': 'socket',
      'url': appSocket.toString(),
    }).toString();
  }

  Uri? get pairingSocketUri {
    final targetId = _targetId;
    if (targetId == null) return null;
    final base = switch (config.connectionMode) {
      CoyoteConnectionMode.privateRelay => config.privateRelayUri,
      CoyoteConnectionMode.officialRelay => relayUri.replace(
        path: '${relayUri.path}/',
      ),
      CoyoteConnectionMode.localNetwork || CoyoteConnectionMode.loopback =>
        _transport is CoyotePairingEndpoint
            ? (_transport as CoyotePairingEndpoint).pairingBaseUri
            : null,
    };
    return base?.replace(queryParameters: {'tid': targetId});
  }

  List<CoyoteDeviceInfo> get devices => List.unmodifiable(_devices.values);
  CoyoteDeviceInfo? get activeDevice => _devices.values
      .where((device) => device.type == 'COYOTE_030' && device.hasDevice)
      .firstOrNull;
  bool get appConnected => _clientId != null;
  bool get connected =>
      phase == CoyoteConnectionPhase.connected && activeDevice != null;
  bool get readyToOutput => connected && config.triggerIntensity > 0;

  void configure(CoyoteConfig value) {
    if (!value.isValid) throw const FormatException('郊狼参数无效');
    if (value.connectionMode != config.connectionMode &&
        phase != CoyoteConnectionPhase.idle) {
      unawaited(disconnect());
    }
    config = value;
    notifyListeners();
  }

  Future<void> connect() async {
    await disconnect();
    if (_disposed) return;
    _closing = false;
    error = null;
    phase = CoyoteConnectionPhase.connecting;
    notifyListeners();
    _log('DG-LAB server connecting');
    _subscription = _transport.events.listen(_handleTransportEvent);
    try {
      final endpoint = switch (config.connectionMode) {
        CoyoteConnectionMode.privateRelay => config.privateRelayUri!,
        CoyoteConnectionMode.officialRelay => relayUri,
        CoyoteConnectionMode.localNetwork => Uri.parse('dglab-local://network'),
        CoyoteConnectionMode.loopback => Uri.parse('dglab-local://loopback'),
      };
      await _transport.connect(endpoint);
      _helloTimer = Timer(_helloTimeout, () {
        if (_targetId == null) _fail('DG-LAB 连接超时');
      });
    } on Object catch (value) {
      _fail(_message(value, 'DG-LAB server 连接失败'));
    }
  }

  Future<void> reconnect() => connect();

  Future<void> disconnect() async {
    _closing = true;
    await emergencyStop(notify: false);
    _cancelTimers();
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _transport.close();
    } on Object {
      // Local state must still return to safe idle when close fails.
    }
    _clearSession();
    if (!_disposed) {
      phase = CoyoteConnectionPhase.idle;
      error = null;
      notifyListeners();
    }
    _closing = false;
    _log('Disconnected');
  }

  Future<void> testOutput() async {
    final now = _now();
    if (_lastTestAt != null && now.difference(_lastTestAt!) < config.cooldown) {
      throw StateError('测试冷却中，请稍后再试');
    }
    _lastTestAt = now;
    final intensity = _clampIntensity(
      config.triggerIntensity.clamp(0, CoyoteConfig.testIntensityLimit),
    );
    if (intensity <= 0) throw StateError('测试强度必须大于 0');
    final duration = config.duration < CoyoteConfig.testDurationLimit
        ? config.duration
        : CoyoteConfig.testDurationLimit;
    _log('Test pulse requested');
    await _startOutput(
      intensity: intensity,
      durationLimit: duration,
      repeatUntilStopped: false,
    );
  }

  @override
  void emit(TriggerEvent event) {
    if (!readyToOutput) {
      throw StateError(!connected ? 'DG-LAB 郊狼未连接' : '郊狼强度必须大于 0');
    }
    final now = _now();
    if (_lastTriggerAt != null &&
        now.difference(_lastTriggerAt!) < config.cooldown) {
      _log('Safety event rate-limited');
      return;
    }
    _lastTriggerAt = now;
    _log('Safety event triggered');
    unawaited(
      _startOutput(
        intensity: _clampIntensity(config.triggerIntensity),
        durationLimit:
            config.outputDurationMode == CoyoteOutputDurationMode.maximum
            ? config.duration
            : null,
        repeatUntilStopped: true,
        event: event,
      ).catchError((Object value) {
        _fail(_message(value, '郊狼输出失败'));
      }),
    );
  }

  Future<void> _startOutput({
    required int intensity,
    required Duration? durationLimit,
    required bool repeatUntilStopped,
    TriggerEvent? event,
  }) async {
    final clientId = _clientId;
    final device = activeDevice;
    if (!connected || clientId == null || device == null) {
      throw StateError('DG-LAB 郊狼未连接');
    }
    final safeIntensity = _clampIntensity(intensity);
    if (safeIntensity <= 0) throw StateError('郊狼强度必须大于 0');
    final safeDurationLimit = durationLimit == null
        ? null
        : Duration(
            milliseconds: durationLimit.inMilliseconds.clamp(
              CoyoteConfig.minDuration.inMilliseconds,
              CoyoteConfig.maxDuration.inMilliseconds,
            ),
          );
    final token = ++_outputToken;
    _safetyStopTimer?.cancel();
    _outputRefreshTimer?.cancel();
    final channels = _selectedChannels(event);
    await _sendOutputChunk(
      token: token,
      clientId: clientId,
      slotId: device.slotId,
      channels: channels,
      intensity: safeIntensity,
      remaining: safeDurationLimit,
      repeatUntilStopped: repeatUntilStopped,
    );
    if (token != _outputToken) return;
    if (safeDurationLimit != null) {
      _safetyStopTimer = Timer(safeDurationLimit, () {
        if (token == _outputToken) {
          unawaited(emergencyStop(notify: false));
        }
      });
    }
  }

  Future<void> _sendOutputChunk({
    required int token,
    required String clientId,
    required String slotId,
    required List<int> channels,
    required int intensity,
    required Duration? remaining,
    required bool repeatUntilStopped,
  }) async {
    if (token != _outputToken || !connected) return;
    final chunkDuration =
        remaining == null || remaining > CoyoteConfig.protocolChunkDuration
        ? CoyoteConfig.protocolChunkDuration
        : remaining;
    if (chunkDuration <= Duration.zero) return;
    final frames = _framesForDuration(chunkDuration);
    for (final channel in channels) {
      if (token != _outputToken) return;
      await _sendOperate(clientId, {
        's': slotId,
        't': 4,
        'c': channel,
        'p': 1,
        'd': chunkDuration.inMilliseconds,
        'im': true,
        'v': intensity,
      }, outputToken: token);
      if (token != _outputToken) return;
      await _sendOperate(clientId, {
        's': slotId,
        't': 0,
        'c': channel,
        'p': 1,
        'd': chunkDuration.inMilliseconds,
        'im': true,
        'v': frames,
        'ver': 3,
      }, outputToken: token);
    }
    if (token != _outputToken) return;
    _log('Pulse/task sent');
    if (!repeatUntilStopped) return;
    // A finite task that already spans the remaining limit needs no refresh.
    if (remaining != null && remaining <= chunkDuration) return;
    const lead = Duration(milliseconds: 250);
    final refreshAfter = chunkDuration > lead
        ? chunkDuration - lead
        : chunkDuration;
    final nextRemaining = remaining == null ? null : remaining - refreshAfter;
    if (nextRemaining != null && nextRemaining <= Duration.zero) return;
    _outputRefreshTimer = Timer(refreshAfter, () {
      if (token != _outputToken) return;
      unawaited(
        _sendOutputChunk(
          token: token,
          clientId: clientId,
          slotId: slotId,
          channels: channels,
          intensity: intensity,
          remaining: nextRemaining,
          repeatUntilStopped: true,
        ).catchError((Object value) {
          _fail(_message(value, '郊狼持续输出失败'));
        }),
      );
    });
  }

  int _clampIntensity(int requested) => requested.clamp(
    0,
    config.maxIntensity.clamp(1, CoyoteConfig.protocolMaxIntensity),
  );

  List<int> _selectedChannels(TriggerEvent? event) {
    if (event != null &&
        (config.directionalMapping || event.forceDirectional)) {
      switch (event.side) {
        case TriggerSide.left:
          return const [0];
        case TriggerSide.right:
          return const [1];
        case TriggerSide.both:
          return const [0, 1];
        case TriggerSide.unknown:
          break;
      }
    }
    return switch (config.channel) {
      CoyoteChannel.a => const [0],
      CoyoteChannel.b => const [1],
      CoyoteChannel.both => const [0, 1],
    };
  }

  List<String> _framesForDuration(Duration duration) {
    final source = coyoteWaveforms
        .firstWhere(
          (waveform) => waveform.id == config.waveform,
          orElse: () => coyoteWaveforms.first,
        )
        .frames;
    final count = (duration.inMilliseconds / 100).ceil().clamp(1, 50);
    return List.generate(count, (index) => source[index % source.length]);
  }

  Future<void> emergencyStop({bool notify = true}) async {
    _safetyStopTimer?.cancel();
    _safetyStopTimer = null;
    _outputRefreshTimer?.cancel();
    _outputRefreshTimer = null;
    _outputToken++;
    final clientId = _clientId;
    final slotIds = _devices.values
        .where((value) => value.type == 'COYOTE_030')
        .map((value) => value.slotId)
        .toList(growable: false);
    if (clientId != null) {
      await _clearOutputImmediately(clientId, slotIds);
    }
    if (notify && !_disposed) notifyListeners();
    _log('Emergency stop');
  }

  Future<void> stop() => emergencyStop(notify: false);

  @override
  void reset() {
    unawaited(emergencyStop(notify: false));
  }

  void _handleTransportEvent(CoyoteTransportEvent event) {
    switch (event) {
      case CoyoteTransportMessage(:final data):
        _handleFrame(data);
      case CoyoteTransportFailure(:final error):
        _fail(_message(error, 'DG-LAB WebSocket 错误'));
      case CoyoteTransportDisconnected(:final reason):
        if (_closing || _disposed) return;
        _handleDisconnected(reason ?? 'DG-LAB WebSocket 已断开');
    }
  }

  void _handleFrame(Map<String, dynamic> frame) {
    switch (frame['type']) {
      case 'hello':
        final id = frame['clientId'];
        if (id is! String || id.isEmpty) return;
        _helloTimer?.cancel();
        _targetId = id;
        phase = CoyoteConnectionPhase.waitingForScan;
        _startPing();
        _log('DG-LAB server started; QR/session created');
        notifyListeners();
      case 'client_attached':
        final id = frame['clientId'];
        if (id is! String || id.isEmpty) return;
        _clientId = id;
        phase = CoyoteConnectionPhase.waitingForDevice;
        _lastTriggerAt = null;
        _lastTestAt = null;
        _log('App connected');
        unawaited(_initializeSafeSession(id));
        notifyListeners();
      case 'client_disconnected':
        if (frame['clientId'] != _clientId) return;
        unawaited(emergencyStop(notify: false));
        _clientId = null;
        _devices.clear();
        phase = CoyoteConnectionPhase.disconnected;
        _fault('DG-LAB App 已断开');
      case 'message':
        if (frame['clientId'] != _clientId) return;
        final data = frame['data'];
        if (data is Map<String, dynamic>) _handleData(data);
      case 'pong':
        _missedPongs = 0;
      case 'idle_timeout':
        _fail('DG-LAB 配对会话已超时，请重新连接');
      case 'error':
        _fail((frame['message'] ?? frame['code'] ?? 'DG-LAB 服务错误').toString());
      case 'heartbeat':
        break;
    }
  }

  Future<void> _initializeSafeSession(String clientId) async {
    await emergencyStop(notify: false);
    await _sendRpc(clientId, 'devices.get');
  }

  void _handleData(Map<String, dynamic> data) {
    if (data['t'] == 'resp') {
      final responseError = data['error'];
      if (responseError != null && responseError.toString().isNotEmpty) {
        _fail('DG-LAB 指令失败: $responseError');
        return;
      }
      if (data['result'] is Map<String, dynamic>) {
        final result = data['result'] as Map<String, dynamic>;
        if (result['devices'] is List) {
          _replaceDevices(result['devices'] as List, preserveDetails: true);
        }
      }
      return;
    }
    if (data['t'] != 'ev') return;
    switch (data['ev']) {
      case 'devices.snapshot':
        _replaceDevices(
          data['devices'] is List ? data['devices'] as List : const [],
        );
      case 'devices.patch':
        for (final value
            in data['added'] is List ? data['added'] as List : const []) {
          final device = _parseDevice(value);
          if (device != null) _devices[device.slotId] = device;
        }
        for (final value
            in data['removed'] is List ? data['removed'] as List : const []) {
          if (value is String) _devices.remove(value);
        }
        _syncDevicePhase();
      case 'slots.patch':
        for (final value
            in data['slots'] is List ? data['slots'] as List : const []) {
          if (value is! Map) continue;
          final patch = Map<String, dynamic>.from(value);
          final slotId = patch['slotId'];
          final current = slotId is String ? _devices[slotId] : null;
          if (current == null) continue;
          _devices[slotId as String] = _patchDevice(current, patch);
        }
        _syncDevicePhase();
    }
  }

  void _replaceDevices(List<dynamic> values, {bool preserveDetails = false}) {
    final previous = preserveDetails
        ? Map<String, CoyoteDeviceInfo>.of(_devices)
        : const <String, CoyoteDeviceInfo>{};
    _devices.clear();
    for (final value in values) {
      final slotId = value is Map ? value['slotId'] : null;
      final device = _parseDevice(
        value,
        previous: slotId is String ? previous[slotId] : null,
      );
      if (device != null) _devices[device.slotId] = device;
    }
    _syncDevicePhase();
  }

  CoyoteDeviceInfo? _parseDevice(dynamic value, {CoyoteDeviceInfo? previous}) {
    if (value is! Map) return null;
    final data = Map<String, dynamic>.from(value);
    final slotId = data['slotId'];
    final type = data['type'];
    if (slotId is! String || type is! String) return null;
    final props = data['props'] is Map
        ? Map<String, dynamic>.from(data['props'] as Map)
        : const <String, dynamic>{};
    final slotState = data['slotState'] is Map
        ? Map<String, dynamic>.from(data['slotState'] as Map)
        : const <String, dynamic>{};
    return CoyoteDeviceInfo(
      slotId: slotId,
      name: data['name'] is String ? data['name'] as String : 'DG-LAB Coyote',
      type: type,
      hasDevice: slotState.containsKey('hasDevice')
          ? slotState['hasDevice'] == true &&
                props['connectState'] != 'disconnected'
          : previous?.hasDevice ?? false,
      power: _intValue(props['power']) ?? previous?.power,
      intensityA: _intValue(props['intensityA']) ?? previous?.intensityA,
      intensityB: _intValue(props['intensityB']) ?? previous?.intensityB,
      channelAStatus:
          _intValue(props['channelAStatus']) ?? previous?.channelAStatus,
      channelBStatus:
          _intValue(props['channelBStatus']) ?? previous?.channelBStatus,
    );
  }

  CoyoteDeviceInfo _patchDevice(
    CoyoteDeviceInfo current,
    Map<String, dynamic> patch,
  ) {
    final props = patch['props'] is Map
        ? Map<String, dynamic>.from(patch['props'] as Map)
        : const <String, dynamic>{};
    final state = patch['slotState'] is Map
        ? Map<String, dynamic>.from(patch['slotState'] as Map)
        : const <String, dynamic>{};
    return current.copyWith(
      hasDevice: state.containsKey('hasDevice')
          ? state['hasDevice'] == true
          : current.hasDevice,
      power: _intValue(props['power']),
      intensityA: _intValue(props['intensityA']),
      intensityB: _intValue(props['intensityB']),
      channelAStatus: _intValue(props['channelAStatus']),
      channelBStatus: _intValue(props['channelBStatus']),
    );
  }

  int? _intValue(dynamic value) => value is num ? value.round() : null;

  void _syncDevicePhase() {
    if (phase == CoyoteConnectionPhase.error) {
      notifyListeners();
      return;
    }
    final coyote = activeDevice;
    if (coyote != null) {
      final firstConnection = phase != CoyoteConnectionPhase.connected;
      phase = CoyoteConnectionPhase.connected;
      error = null;
      if (firstConnection) {
        _log('Coyote connected');
        unawaited(emergencyStop(notify: false));
      }
    } else if (_clientId != null) {
      if (phase == CoyoteConnectionPhase.connected) {
        unawaited(emergencyStop(notify: false));
        _fault('郊狼设备已断开');
      }
      phase = CoyoteConnectionPhase.waitingForDevice;
    }
    notifyListeners();
  }

  Future<void> _sendOperate(
    String clientId,
    Map<String, dynamic> data, {
    required int outputToken,
  }) => _queueFrame(
    _rpcFrame(clientId, 'device.op', data: data),
    outputToken: outputToken,
  );

  Future<void> _sendRpc(
    String clientId,
    String method, {
    Map<String, dynamic>? data,
  }) {
    return _queueFrame(_rpcFrame(clientId, method, data: data));
  }

  Map<String, dynamic> _rpcFrame(
    String clientId,
    String method, {
    Map<String, dynamic>? data,
  }) {
    final payload = <String, dynamic>{
      't': 'req',
      'reqId': '${++_requestSequence}',
      'm': method,
      'data': ?data,
    };
    return {'type': 'message', 'clientId': clientId, 'data': payload};
  }

  Future<void> _clearOutputImmediately(
    String clientId,
    List<String> slotIds,
  ) async {
    final operations = <Future<void>>[
      _sendBestEffort(_rpcFrame(clientId, 'device.op.clear')),
    ];
    for (final slotId in slotIds) {
      for (final channel in const [0, 1]) {
        operations.add(
          _sendBestEffort(
            _rpcFrame(
              clientId,
              'device.op',
              data: {
                's': slotId,
                't': 7,
                'c': channel,
                'p': 2,
                'im': true,
                'v': 0,
              },
            ),
          ),
        );
      }
    }
    await Future.wait(operations);
  }

  Future<void> _sendBestEffort(Map<String, dynamic> frame) async {
    try {
      await _transport.send(frame);
    } on Object {
      // A fail-safe stop must continue even if one clear/reset frame fails.
    }
  }

  Future<void> _queueFrame(Map<String, dynamic> frame, {int? outputToken}) {
    final operation = _commands.then((_) {
      if (outputToken != null &&
          (outputToken != _outputToken || !connected || _disposed)) {
        return Future<void>.value();
      }
      return _transport.send(frame);
    });
    _commands = operation.catchError((Object value) {
      if (!_closing) _fail(_message(value, 'DG-LAB 指令发送失败'));
    });
    return operation;
  }

  void _startPing() {
    _pingTimer?.cancel();
    _missedPongs = 0;
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      if (_missedPongs >= _maxMissedPongs) {
        _fail('DG-LAB server ping 超时');
        unawaited(_transport.close());
        return;
      }
      _missedPongs++;
      unawaited(_queueFrame({'type': 'ping'}).catchError((Object _) {}));
    });
  }

  void _handleDisconnected(String message) {
    _cancelTimers();
    _clearSession();
    phase = CoyoteConnectionPhase.disconnected;
    error = message;
    notifyListeners();
    onFault?.call(message);
    _log('Disconnected');
  }

  void _fail(String message) {
    if (_disposed || _closing) return;
    if (phase == CoyoteConnectionPhase.error) {
      _log('Error: $message');
      return;
    }
    _cancelTimers();
    _outputToken++;
    final clientId = _clientId;
    final slotIds = _devices.values
        .where((value) => value.type == 'COYOTE_030')
        .map((value) => value.slotId)
        .toList(growable: false);
    if (clientId != null) {
      unawaited(_clearOutputImmediately(clientId, slotIds));
    }
    phase = CoyoteConnectionPhase.error;
    error = message;
    notifyListeners();
    onFault?.call(message);
    _log('Error: $message');
  }

  void _fault(String message) {
    if (_disposed) return;
    error = message;
    notifyListeners();
    onFault?.call(message);
  }

  void _cancelTimers() {
    _helloTimer?.cancel();
    _helloTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _safetyStopTimer?.cancel();
    _safetyStopTimer = null;
    _outputRefreshTimer?.cancel();
    _outputRefreshTimer = null;
  }

  void _clearSession() {
    _targetId = null;
    _clientId = null;
    _devices.clear();
    _lastTriggerAt = null;
    _lastTestAt = null;
    _outputToken++;
  }

  String _message(Object value, String fallback) {
    final text = value.toString().replaceFirst(RegExp(r'^Bad state: '), '');
    return text.isEmpty ? fallback : text;
  }

  void _log(String message) {
    developer.log(message, name: 'safety_margin.dglab');
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    unawaited(_subscription?.cancel());
    unawaited(emergencyStop(notify: false).whenComplete(_transport.close));
    super.dispose();
  }
}
