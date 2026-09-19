import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/domain/ems_protocol.dart';
import 'package:safety_margin/domain/game_engine.dart';
import 'package:safety_margin/services/ems_device.dart';

class FakeEmsTransport implements EmsTransport {
  final scanController = StreamController<EmsPeripheral>.broadcast();
  final linkController = StreamController<EmsLinkState>.broadcast();
  final notificationController = StreamController<List<int>>.broadcast();
  final writes = <List<int>>[];
  int permissionRequests = 0;
  Object? writeError;
  Completer<void>? blockNextWrite;

  @override
  Future<void> requestPermissions() async {
    permissionRequests++;
  }

  @override
  Stream<EmsPeripheral> scan() => scanController.stream;

  @override
  Stream<EmsLinkState> connect(String deviceId) => linkController.stream;

  @override
  Stream<List<int>> notifications(String deviceId) =>
      notificationController.stream;

  @override
  Future<void> write(String deviceId, List<int> value) async {
    if (writeError != null) throw writeError!;
    final blocker = blockNextWrite;
    blockNextWrite = null;
    await blocker?.future;
    writes.add(List.of(value));
  }

  Future<void> close() async {
    await scanController.close();
    await linkController.close();
    await notificationController.close();
  }
}

void main() {
  late FakeEmsTransport transport;
  late EmsDeviceController device;

  setUp(() {
    transport = FakeEmsTransport();
    device = EmsDeviceController(
      transport: transport,
      pulseDuration: const Duration(milliseconds: 10),
      stepInterval: const Duration(milliseconds: 20),
    );
  });

  tearDown(() async {
    device.dispose();
    await transport.close();
  });

  test('启动阶段申请权限，扫描时不重复申请', () async {
    await device.requestPermissions();
    expect(transport.permissionRequests, 1);
    await device.scan();
    expect(transport.permissionRequests, 1);
  });
  test('扫描结果按信号排序并更新同一设备', () async {
    await device.scan();
    transport.scanController.add(
      const EmsPeripheral(id: 'a', name: 'A', rssi: -80),
    );
    transport.scanController.add(
      const EmsPeripheral(id: 'b', name: 'B', rssi: -40),
    );
    transport.scanController.add(
      const EmsPeripheral(id: 'a', name: 'A2', rssi: -30),
    );
    await Future<void>.delayed(Duration.zero);
    expect(device.devices.map((value) => value.id), ['a', 'b']);
    expect(device.devices.first.name, 'A2');
  });

  test('连接后查询电量，触发后持续输出，需显式 stop 才关闭', () async {
    const peripheral = EmsPeripheral(id: 'ems', name: 'EMS', rssi: -30);
    await device.connect(peripheral);
    transport.linkController.add(EmsLinkState.connected);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(device.connected, isTrue);
    expect(transport.writes.length, 1);
    transport.writes.clear();
    device.configure(
      const EmsConfig(
        generation: EmsGeneration.second,
        intensityA: 180,
        waveform: 2,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    transport.writes.clear();
    device.emit(
      const TriggerEvent(
        sessionId: '1',
        sequence: 1,
        elapsed: Duration(seconds: 3),
        reason: TriggerReason.outside,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // 没有固定脉冲时长，会持续下发渐变帧直到显式 stop()。
    expect(transport.writes.length, greaterThanOrEqualTo(2));
    expect(transport.writes.first[3], 0x01);
    expect(transport.writes.first[4], 0x14);
    for (final packet in transport.writes) {
      expect(packet.length, 12); // 二代实时模式包，不是关闭包
    }
    transport.writes.clear();
    await device.stop();
    expect(transport.writes.single.length, 10); // 二代固定模式关闭包
    expect(transport.writes.single[3], 0);
  });

  test('触发期间频率按波形周期循环，不会自动停止', () async {
    const peripheral = EmsPeripheral(id: 'ems', name: 'EMS', rssi: -30);
    final ramping = EmsDeviceController(
      transport: transport,
      pulseDuration: const Duration(milliseconds: 40),
      stepInterval: const Duration(milliseconds: 10),
    );
    addTearDown(ramping.dispose);
    await ramping.connect(peripheral);
    transport.linkController.add(EmsLinkState.connected);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    ramping.configure(
      const EmsConfig(
        generation: EmsGeneration.second,
        intensityA: 180,
        waveform: 1,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    transport.writes.clear();
    ramping.emit(
      const TriggerEvent(
        sessionId: '1',
        sequence: 1,
        elapsed: Duration.zero,
        reason: TriggerReason.outside,
      ),
    );
    // 覆盖两轮以上的波形周期（40ms 一轮），验证持续输出且从不自动停止。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(transport.writes.length, greaterThanOrEqualTo(6));
    expect(transport.writes.every((packet) => packet.length == 12), isTrue);
    final frequencies = transport.writes.map((p) => p[5]).toList();
    expect(frequencies.any((f) => f > frequencies.first + 10), isTrue);
    expect(frequencies.skip(3).any((f) => f <= frequencies.first + 4), isTrue);
    transport.writes.clear();
    await ramping.stop();
    expect(transport.writes.single.length, 10);
    expect(transport.writes.single[3], 0);
  });

  test('越界期间强度按设置的速率持续叠加，停止后恢复基础强度', () async {
    const peripheral = EmsPeripheral(id: 'ems', name: 'EMS', rssi: -30);
    final ramping = EmsDeviceController(
      transport: transport,
      pulseDuration: const Duration(milliseconds: 200),
      stepInterval: const Duration(milliseconds: 15),
    );
    addTearDown(ramping.dispose);
    await ramping.connect(peripheral);
    transport.linkController.add(EmsLinkState.connected);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    ramping.configure(
      const EmsConfig(
        generation: EmsGeneration.second,
        intensityA: 50,
        waveform: 1,
        intensityRampPerSecond: 180,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    transport.writes.clear();
    ramping.emit(
      const TriggerEvent(
        sessionId: '1',
        sequence: 1,
        elapsed: Duration.zero,
        reason: TriggerReason.outside,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 90));
    final strengths = transport.writes
        .map((packet) => (packet[3] << 8) | packet[4])
        .toList();
    expect(strengths.length, greaterThanOrEqualTo(3));
    // 单调不减：强度只会随时间叠加，不会中途回落。
    for (var i = 1; i < strengths.length; i++) {
      expect(strengths[i], greaterThanOrEqualTo(strengths[i - 1]));
    }
    // 每秒 +180，90ms 至少应看到明显叠加。
    expect(strengths.last, greaterThan(strengths.first));
    await ramping.stop();
    transport.writes.clear();
    ramping.emit(
      const TriggerEvent(
        sessionId: '2',
        sequence: 2,
        elapsed: Duration.zero,
        reason: TriggerReason.outside,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    // 新一次触发从基础强度重新开始，而不是接着上次叠加后的值继续。
    final restarted =
        (transport.writes.first[3] << 8) | transport.writes.first[4];
    expect(restarted, lessThan(strengths.last));
  });

  test('按蓝牙名称自动识别代次，持续触发时一代每轮拆成两条通道指令', () async {
    const peripheral = EmsPeripheral(id: 'ems', name: 'YYC-DJ-1234', rssi: -30);
    await device.connect(peripheral);
    transport.linkController.add(EmsLinkState.connected);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(device.config.generation, EmsGeneration.first);
    device.configure(device.config.copyWith(intensityA: 180, intensityB: 90));
    await Future<void>.delayed(Duration.zero);
    transport.writes.clear();
    device.emit(
      const TriggerEvent(
        sessionId: '1',
        sequence: 1,
        elapsed: Duration.zero,
        reason: TriggerReason.outside,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // 一代协议一个包只能带一个通道，持续输出的每一轮都要拆成两条指令。
    expect(transport.writes.length, greaterThanOrEqualTo(4));
    expect(transport.writes.length.isEven, isTrue);
    for (var i = 0; i < transport.writes.length; i += 2) {
      expect(transport.writes[i][2], 0x01);
      expect(transport.writes[i + 1][2], 0x02);
    }
    transport.writes.clear();
    await device.stop();
    expect(transport.writes.length, 2);
    expect(transport.writes[0][2], 0x01);
    expect(transport.writes[1][2], 0x02);
  });

  test('二代设备（含 V2 标识）不会被误判为一代', () async {
    const peripheral = EmsPeripheral(
      id: 'ems',
      name: 'YYC-DJ-V2-01',
      rssi: -30,
    );
    await device.connect(peripheral);
    transport.linkController.add(EmsLinkState.connected);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(device.config.generation, EmsGeneration.second);
  });

  test('通知更新电量', () async {
    const peripheral = EmsPeripheral(id: 'ems', name: 'EMS', rssi: -30);
    await device.connect(peripheral);
    transport.linkController.add(EmsLinkState.connected);
    await Future<void>.delayed(Duration.zero);
    transport.notificationController.add([0x35, 0x71, 0x04, 80, 0xFA]);
    await Future<void>.delayed(Duration.zero);
    expect(device.batteryPercent, 80);
  });

  test('未连接或强度为零时拒绝触发', () async {
    const event = TriggerEvent(
      sessionId: '1',
      sequence: 1,
      elapsed: Duration.zero,
      reason: TriggerReason.absent,
    );
    expect(() => device.emit(event), throwsStateError);
    const peripheral = EmsPeripheral(id: 'ems', name: 'EMS', rssi: -30);
    await device.connect(peripheral);
    transport.linkController.add(EmsLinkState.connected);
    await Future<void>.delayed(Duration.zero);
    expect(() => device.emit(event), throwsStateError);
  });

  test('断开会取消未发送的 A/B 波形，并保证关闭输出是最后一批写入', () async {
    const peripheral = EmsPeripheral(id: 'ems', name: 'YYC-DJ-1234', rssi: -30);
    await device.connect(peripheral);
    transport.linkController.add(EmsLinkState.connected);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    device.configure(device.config.copyWith(intensityA: 20, intensityB: 20));
    await Future<void>.delayed(Duration.zero);
    transport.writes.clear();

    final blocker = Completer<void>();
    transport.blockNextWrite = blocker;
    device.emit(
      const TriggerEvent(
        sessionId: 'disconnect-safety',
        sequence: 1,
        elapsed: Duration.zero,
        reason: TriggerReason.outside,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final disconnecting = device.disconnect();
    await Future<void>.delayed(Duration.zero);
    expect(transport.writes, isEmpty);

    blocker.complete();
    await disconnecting;
    expect(transport.writes, isNotEmpty);
    final firstClose = transport.writes.indexWhere((packet) => packet[3] == 0);
    expect(firstClose, greaterThanOrEqualTo(0));
    expect(
      transport.writes.skip(firstClose).every((packet) => packet[3] == 0),
      isTrue,
    );
    expect(transport.writes.skip(firstClose), hasLength(2));
  });

  test('发送失败上报故障', () async {
    const peripheral = EmsPeripheral(id: 'ems', name: 'EMS', rssi: -30);
    await device.connect(peripheral);
    transport.linkController.add(EmsLinkState.connected);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    device.configure(const EmsConfig(intensityA: 20));
    await Future<void>.delayed(Duration.zero);
    transport.writeError = StateError('write failed');
    final faults = <String>[];
    device.onFault = faults.add;
    device.emit(
      const TriggerEvent(
        sessionId: '1',
        sequence: 1,
        elapsed: Duration.zero,
        reason: TriggerReason.absent,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(faults.single, contains('write failed'));
  });
}
