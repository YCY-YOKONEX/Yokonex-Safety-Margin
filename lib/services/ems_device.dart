import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import '../domain/ems_protocol.dart';
import '../domain/ems_waveform.dart';
import '../domain/game_engine.dart';

enum EmsConnectionPhase { idle, scanning, connecting, connected, error }

enum EmsLinkState { connecting, connected, disconnecting, disconnected }

class EmsPeripheral {
  const EmsPeripheral({
    required this.id,
    required this.name,
    required this.rssi,
  });

  final String id;
  final String name;
  final int rssi;
}

abstract interface class EmsTransport {
  Future<void> requestPermissions();
  Stream<EmsPeripheral> scan();
  Stream<EmsLinkState> connect(String deviceId);
  Stream<List<int>> notifications(String deviceId);
  Future<void> write(String deviceId, List<int> value);
}

class ReactiveBleEmsTransport implements EmsTransport {
  ReactiveBleEmsTransport({
    FlutterReactiveBle? ble,
    DeviceInfoPlugin? deviceInfo,
  }) : _ble = ble ?? FlutterReactiveBle(),
       _deviceInfo = deviceInfo ?? DeviceInfoPlugin();

  final FlutterReactiveBle _ble;
  final DeviceInfoPlugin _deviceInfo;
  final Uuid _service = Uuid.parse(EmsProtocol.serviceUuid);
  final Uuid _write = Uuid.parse(EmsProtocol.writeUuid);
  final Uuid _notify = Uuid.parse(EmsProtocol.notifyUuid);

  @override
  Stream<EmsPeripheral> scan() async* {
    await _ensureReady();
    yield* _ble
        .scanForDevices(
          withServices: [_service],
          scanMode: ScanMode.lowLatency,
          requireLocationServicesEnabled: Platform.isAndroid,
        )
        .map(
          (device) => EmsPeripheral(
            id: device.id,
            name: device.name.trim().isEmpty ? 'EMS 设备' : device.name.trim(),
            rssi: device.rssi,
          ),
        );
  }

  @override
  Stream<EmsLinkState> connect(String deviceId) => _ble
      .connectToAdvertisingDevice(
        id: deviceId,
        withServices: [_service],
        prescanDuration: const Duration(seconds: 5),
        servicesWithCharacteristicsToDiscover: {
          _service: [_write, _notify],
        },
        connectionTimeout: const Duration(seconds: 8),
      )
      .map(
        (update) => switch (update.connectionState) {
          DeviceConnectionState.connecting => EmsLinkState.connecting,
          DeviceConnectionState.connected => EmsLinkState.connected,
          DeviceConnectionState.disconnecting => EmsLinkState.disconnecting,
          DeviceConnectionState.disconnected => EmsLinkState.disconnected,
        },
      );

  @override
  Stream<List<int>> notifications(String deviceId) =>
      _ble.subscribeToCharacteristic(
        QualifiedCharacteristic(
          serviceId: _service,
          characteristicId: _notify,
          deviceId: deviceId,
        ),
      );

  @override
  Future<void> write(String deviceId, List<int> value) =>
      _ble.writeCharacteristicWithoutResponse(
        QualifiedCharacteristic(
          serviceId: _service,
          characteristicId: _write,
          deviceId: deviceId,
        ),
        value: value,
      );

  @override
  Future<void> requestPermissions() async {
    if (!Platform.isAndroid) return;
    final sdk = (await _deviceInfo.androidInfo).version.sdkInt;
    final permissions = sdk >= 31
        ? [Permission.bluetoothScan, Permission.bluetoothConnect]
        : [Permission.locationWhenInUse];
    await permissions.request();
    // 部分机型上 request() 的返回值和系统实际授权状态之间有竞态，
    // 刚点完“允许”立刻查询可能仍拿到旧状态，延迟后重新查询确认，
    // 最多重试两次，避免把“状态还没同步”误判成“用户拒绝了”。
    var statuses = await _pollPermissionStatuses(permissions);
    for (
      var attempt = 0;
      attempt < 2 && statuses.values.any((status) => !status.isGranted);
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      statuses = await _pollPermissionStatuses(permissions);
    }
    if (statuses.values.any((status) => !status.isGranted)) {
      final permanentlyDenied = statuses.values.any(
        (status) => status.isPermanentlyDenied,
      );
      throw StateError(permanentlyDenied ? '蓝牙权限被永久拒绝，请到系统设置中开启' : '蓝牙权限未允许');
    }
  }

  Future<Map<Permission, PermissionStatus>> _pollPermissionStatuses(
    List<Permission> permissions,
  ) async {
    final statuses = <Permission, PermissionStatus>{};
    for (final permission in permissions) {
      statuses[permission] = await permission.status;
    }
    return statuses;
  }

  Future<void> _ensureReady() async {
    final status = await _ble.statusStream.firstWhere(
      (value) => value != BleStatus.unknown,
    );
    final message = switch (status) {
      BleStatus.ready => null,
      BleStatus.poweredOff => '请先开启手机蓝牙',
      BleStatus.unauthorized => '蓝牙权限未允许',
      BleStatus.locationServicesDisabled => '请先开启手机定位服务',
      BleStatus.unsupported => '当前手机不支持蓝牙低功耗设备',
      BleStatus.unknown => '蓝牙状态不可用',
    };
    if (message != null) throw StateError(message);
  }
}

class EmsDeviceController extends ChangeNotifier implements TriggerSink {
  EmsDeviceController({
    EmsTransport? transport,
    this.pulseDuration = const Duration(milliseconds: 800),
    this.stepInterval = const Duration(milliseconds: 100),
  }) : _transport = transport ?? ReactiveBleEmsTransport();

  final EmsTransport _transport;
  // 波形曲线（稀疏→密集）单次循环的时长；输出本身是持续的，这里只控制频率节奏重复的周期。
  final Duration pulseDuration;
  final Duration stepInterval;
  final List<EmsPeripheral> _devices = [];
  StreamSubscription<EmsPeripheral>? _scanSubscription;
  StreamSubscription<EmsLinkState>? _connectionSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  Timer? _scanTimer;
  Timer? _outputTimer;
  Future<void> _writes = Future.value();
  int _outputToken = 0;
  bool _disposed = false;

  EmsConfig config = const EmsConfig();
  EmsConnectionPhase phase = EmsConnectionPhase.idle;
  EmsPeripheral? connectedDevice;
  String? connectingDeviceId;
  String? error;
  int? batteryPercent;
  void Function(String message)? onFault;

  List<EmsPeripheral> get devices => List.unmodifiable(_devices);
  bool get connected => phase == EmsConnectionPhase.connected;
  bool get readyToOutput =>
      connected && (config.intensityA > 0 || config.intensityB > 0);

  Future<void> requestPermissions() async {
    try {
      await _transport.requestPermissions();
    } on Object catch (value) {
      _setError(_message(value, '设备权限申请失败'));
    }
  }

  void configure(EmsConfig value) {
    if (!value.isValid) throw const FormatException('EMS 参数无效');
    final previous = config;
    _outputTimer?.cancel();
    _outputTimer = null;
    _outputToken++;
    config = value;
    if (connected) {
      unawaited(
        _queueWriteAll(
          EmsProtocol.fixedModePacket(previous, enabled: false),
        ).catchError((Object _) {}),
      );
    }
    notifyListeners();
  }

  Future<void> scan() async {
    await _cancelScan();
    error = null;
    phase = EmsConnectionPhase.scanning;
    _devices.clear();
    notifyListeners();
    _scanSubscription = _transport.scan().listen(
      (device) {
        final index = _devices.indexWhere((value) => value.id == device.id);
        if (index < 0) {
          _devices.add(device);
        } else {
          _devices[index] = device;
        }
        _devices.sort((a, b) => b.rssi.compareTo(a.rssi));
        notifyListeners();
      },
      onError: (Object value) {
        _setError(_message(value, '扫描设备失败'));
      },
    );
    _scanTimer = Timer(const Duration(seconds: 8), () {
      unawaited(_cancelScan());
      if (phase == EmsConnectionPhase.scanning) {
        phase = EmsConnectionPhase.idle;
        notifyListeners();
      }
    });
  }

  Future<void> connect(EmsPeripheral device) async {
    await disconnect();
    await _cancelScan();
    error = null;
    connectingDeviceId = device.id;
    phase = EmsConnectionPhase.connecting;
    notifyListeners();
    _connectionSubscription = _transport
        .connect(device.id)
        .listen(
          (state) {
            switch (state) {
              case EmsLinkState.connecting:
                phase = EmsConnectionPhase.connecting;
              case EmsLinkState.connected:
                connectedDevice = device;
                connectingDeviceId = null;
                phase = EmsConnectionPhase.connected;
                config = config.copyWith(
                  generation: EmsProtocol.detectGeneration(device.name),
                );
                _listenNotifications(device.id);
                unawaited(_queryStatus());
              case EmsLinkState.disconnecting:
                phase = EmsConnectionPhase.connecting;
              case EmsLinkState.disconnected:
                _handleDisconnected('EMS 设备已断开');
            }
            notifyListeners();
          },
          onError: (Object value) {
            _handleDisconnected(_message(value, '连接设备失败'));
          },
        );
  }

  Future<void> disconnect() async {
    _outputTimer?.cancel();
    _outputTimer = null;
    _outputToken++;
    if (connectedDevice != null) {
      try {
        // 关闭包作为一个原子批次排到所有写入之后；旧输出批次因 token
        // 失效会跳过尚未开始的 A/B 波形，确保最终写入一定是关闭输出。
        await _queueWriteAll(
          EmsProtocol.fixedModePacket(config, enabled: false),
        );
      } on Object {
        // 断开流程继续执行，不能因关闭命令失败留下连接订阅。
      }
    }
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    connectedDevice = null;
    connectingDeviceId = null;
    batteryPercent = null;
    if (!_disposed) {
      phase = EmsConnectionPhase.idle;
      notifyListeners();
    }
  }

  /// 触发后持续输出直到 [stop] 被调用（人物回到区域内），不再有固定脉冲时长。
  /// 波形曲线的频率/脉宽按 [pulseDuration] 周期循环，强度则随触发时长不断叠加。
  @override
  void emit(TriggerEvent event) {
    if (!readyToOutput) {
      throw StateError(!connected ? 'EMS 设备未连接' : 'EMS 强度必须大于 0');
    }
    _outputTimer?.cancel();
    final token = ++_outputToken;
    final shape = emsWaveformCurves
        .firstWhere(
          (curve) => curve.id == config.waveform,
          orElse: () => emsWaveformCurves.first,
        )
        .shape;
    final stopwatch = Stopwatch()..start();
    void tick() {
      if (_disposed || token != _outputToken) return;
      final elapsed = stopwatch.elapsed;
      final cycleMicros = pulseDuration.inMicroseconds <= 0
          ? 0
          : elapsed.inMicroseconds % pulseDuration.inMicroseconds;
      final step = EmsWaveform.stepAt(
        shape,
        Duration(microseconds: cycleMicros),
        pulseDuration,
      );
      final ramped = config.copyWith(
        intensityA: _rampedIntensity(config.intensityA, elapsed),
        intensityB: _rampedIntensity(config.intensityB, elapsed),
      );
      unawaited(
        _queueWriteAll(
          EmsProtocol.customStepPacket(ramped, step),
          outputToken: token,
        ).catchError((Object _) {}),
      );
    }

    tick();
    if (token == _outputToken) {
      _outputTimer = Timer.periodic(stepInterval, (_) => tick());
    }
  }

  int _rampedIntensity(int base, Duration elapsed) {
    final added =
        (config.intensityRampPerSecond * elapsed.inMilliseconds / 1000).round();
    return (base + added).clamp(0, EmsConfig.appMaxIntensity);
  }

  Future<void> stop() {
    _outputTimer?.cancel();
    _outputTimer = null;
    _outputToken++;
    if (!connected) return Future.value();
    return _queueWriteAll(EmsProtocol.fixedModePacket(config, enabled: false));
  }

  @override
  void reset() {
    unawaited(stop().catchError((Object _) {}));
  }

  void _listenNotifications(String deviceId) {
    unawaited(_notificationSubscription?.cancel());
    _notificationSubscription = _transport
        .notifications(deviceId)
        .listen(
          (packet) {
            final notification = EmsProtocol.parseNotification(packet);
            switch (notification) {
              case EmsBatteryNotification():
                batteryPercent = notification.percent;
              case EmsErrorNotification():
                _fault('设备报告协议错误：${notification.code}');
              case EmsChannelNotification():
              case null:
            }
            notifyListeners();
          },
          onError: (Object value) {
            _fault(_message(value, '设备状态监听失败'));
          },
        );
  }

  Future<void> _queryStatus() async {
    if (!connected) return;
    await _queueWrite(EmsProtocol.queryPacket(4));
  }

  Future<void> _queueWrite(List<int> packet) {
    return _queueWriteAll([packet]);
  }

  Future<void> _queueWriteAll(List<List<int>> packets, {int? outputToken}) {
    final operation = _writes.then((_) async {
      if (outputToken != null && outputToken != _outputToken) return;
      for (final packet in packets) {
        if (outputToken != null && outputToken != _outputToken) return;
        await _writeNow(packet);
      }
    });
    _writes = operation.catchError((Object value) {
      _fault(_message(value, 'EMS 指令发送失败'));
    });
    return operation;
  }

  Future<void> _writeNow(List<int> packet) {
    final device = connectedDevice;
    if (device == null) throw StateError('EMS 设备未连接');
    return _transport.write(device.id, packet);
  }

  void _handleDisconnected(String message) {
    _outputTimer?.cancel();
    _outputTimer = null;
    _outputToken++;
    connectedDevice = null;
    connectingDeviceId = null;
    batteryPercent = null;
    phase = EmsConnectionPhase.error;
    error = message;
    notifyListeners();
    onFault?.call(message);
  }

  void _fault(String message) {
    if (_disposed) return;
    error = message;
    notifyListeners();
    onFault?.call(message);
  }

  void _setError(String message) {
    if (_disposed) return;
    phase = EmsConnectionPhase.error;
    error = message;
    notifyListeners();
  }

  String _message(Object value, String fallback) {
    final text = value.toString().replaceFirst(RegExp(r'^Bad state: '), '');
    return text.isEmpty ? fallback : text;
  }

  Future<void> _cancelScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSubscription?.cancel();
    _scanSubscription = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _scanTimer?.cancel();
    _outputTimer?.cancel();
    unawaited(_scanSubscription?.cancel());
    unawaited(_notificationSubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    super.dispose();
  }
}
