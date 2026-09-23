import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/domain/coyote_protocol.dart';
import 'package:safety_margin/domain/game_engine.dart';
import 'package:safety_margin/domain/pose_sample.dart';
import 'package:safety_margin/services/coyote_device.dart';
import 'package:safety_margin/services/coyote_transport.dart';

class _FakeCoyoteTransport implements CoyoteTransport {
  final controller = StreamController<CoyoteTransportEvent>.broadcast(
    sync: true,
  );
  final sent = <Map<String, dynamic>>[];
  int connects = 0;
  int closes = 0;
  Completer<void>? blockNextSend;

  @override
  Stream<CoyoteTransportEvent> get events => controller.stream;

  @override
  Future<void> connect(Uri uri) async {
    connects++;
  }

  @override
  Future<void> send(Map<String, dynamic> frame) async {
    sent.add(frame);
    final blocker = blockNextSend;
    blockNextSend = null;
    await blocker?.future;
  }

  @override
  Future<void> close() async {
    closes++;
  }

  void message(Map<String, dynamic> data) {
    controller.add(CoyoteTransportMessage(data));
  }

  Future<void> dispose() => controller.close();
}

Map<String, dynamic> _device({bool connected = true}) => {
  'slotId': 'coyote-slot',
  'name': 'Coyote 3.0',
  'type': 'COYOTE_030',
  'props': {
    'connectState': connected ? 'connected' : 'disconnected',
    'power': 88,
    'intensityA': 0,
    'intensityB': 0,
  },
  'slotState': {'hasDevice': connected},
};

Map<String, dynamic> _rpc(Map<String, dynamic> frame) =>
    frame['data'] as Map<String, dynamic>;

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Future<void> _pair(
  CoyoteDeviceController device,
  _FakeCoyoteTransport transport,
) async {
  await device.connect();
  transport.message({'type': 'hello', 'clientId': 'controller'});
  expect(device.phase, CoyoteConnectionPhase.waitingForScan);
  expect(device.pairingUrl, contains('action=socket'));
  transport.message({'type': 'client_attached', 'clientId': 'app'});
  transport.message({
    'type': 'message',
    'clientId': 'app',
    'data': {
      't': 'ev',
      'ev': 'devices.snapshot',
      'devices': [_device()],
    },
  });
  await _flush();
  expect(device.connected, isTrue);
}

void main() {
  late _FakeCoyoteTransport transport;
  late CoyoteDeviceController device;
  var now = DateTime(2026);

  setUp(() {
    transport = _FakeCoyoteTransport();
    device = CoyoteDeviceController(transport: transport, now: () => now);
  });

  tearDown(() async {
    await device.disconnect();
    device.dispose();
    await transport.dispose();
  });

  test('内置波形保留 dglab-kit 1.0.5 官方完整帧序列', () {
    expect(coyoteWaveforms.map((waveform) => waveform.frames.length), [
      2,
      2,
      13,
      13,
      16,
      6,
    ]);
  });

  test('配对状态机生成官方 V4 二维码且连接后先 clear 和 A/B 归零', () async {
    await _pair(device, transport);
    expect(device.activeDevice?.power, 88);
    expect(
      device.pairingUrl,
      contains(
        Uri.encodeQueryComponent(
          '${CoyoteConfig.defaultPrivateRelayUrl}?tid=controller',
        ),
      ),
    );
    final requests = transport.sent.map(_rpc).toList();
    expect(requests.any((value) => value['m'] == 'device.op.clear'), isTrue);
    final zeroTasks = requests
        .where((value) => value['m'] == 'device.op')
        .map((value) => value['data'] as Map<String, dynamic>)
        .where((task) => task['t'] == 7 && task['v'] == 0)
        .toList();
    expect(zeroTasks.map((task) => task['c']).toSet(), {0, 1});
    expect(
      requests
          .where((value) => value['m'] == 'device.op')
          .map((value) => value['data'] as Map<String, dynamic>)
          .where((task) => task['t'] == 4),
      isEmpty,
      reason: '扫码和设备连接本身不得产生正向输出',
    );
  });

  test('官方 devices.get 精简响应不会覆盖已连接设备状态', () async {
    await _pair(device, transport);
    transport.message({
      'type': 'message',
      'clientId': 'app',
      'data': {
        't': 'resp',
        'reqId': '1',
        'result': {
          'devices': [
            {
              'slotId': 'coyote-slot',
              'name': 'Coyote 3.0',
              'type': 'COYOTE_030',
            },
          ],
        },
      },
    });
    expect(device.connected, isTrue);
    expect(device.activeDevice?.power, 88);
  });

  test('急停使发送中的输出失效，clear 后不会继续发送波形', () async {
    await _pair(device, transport);
    transport.sent.clear();
    final blocker = Completer<void>();
    transport.blockNextSend = blocker;
    device.emit(
      const TriggerEvent(
        sessionId: 'session',
        sequence: 1,
        elapsed: Duration.zero,
        reason: TriggerReason.outside,
      ),
    );
    await _flush();
    expect(
      transport.sent.map(_rpc).where((value) => value['m'] == 'device.op'),
      hasLength(1),
    );

    await device.emergencyStop();
    blocker.complete();
    await _flush();

    final requests = transport.sent.map(_rpc).toList();
    expect(requests.any((value) => value['m'] == 'device.op.clear'), isTrue);
    final pulseTasks = requests
        .where((value) => value['m'] == 'device.op')
        .map((value) => value['data'] as Map<String, dynamic>)
        .where((value) => value['t'] == 0);
    expect(pulseTasks, isEmpty);
  });

  test('协议或传输错误会尽力 clear 并将 A/B 归零', () async {
    await _pair(device, transport);
    transport.sent.clear();
    transport.controller.add(
      const CoyoteTransportFailure('simulated transport failure'),
    );
    await _flush();
    expect(device.phase, CoyoteConnectionPhase.error);
    final requests = transport.sent.map(_rpc).toList();
    expect(requests.any((value) => value['m'] == 'device.op.clear'), isTrue);
    final zeroChannels = requests
        .where((value) => value['m'] == 'device.op')
        .map((value) => value['data'] as Map<String, dynamic>)
        .where((value) => value['t'] == 7 && value['v'] == 0)
        .map((value) => value['c'])
        .toSet();
    expect(zeroChannels, {0, 1});
    final stoppedAt = transport.sent.length;
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(transport.sent, hasLength(stoppedAt), reason: '错误状态必须停止心跳，等待用户明确重连');
  });

  test('V4 RPC 错误进入 fail-safe，清理错误不会递归发送', () async {
    await _pair(device, transport);
    transport.sent.clear();
    transport.message({
      'type': 'message',
      'clientId': 'app',
      'data': {'t': 'resp', 'reqId': '2', 'error': 'device_unavailable'},
    });
    await _flush();
    expect(device.phase, CoyoteConnectionPhase.error);
    final firstStopCount = transport.sent.length;
    expect(firstStopCount, 3);

    transport.message({
      'type': 'message',
      'clientId': 'app',
      'data': {'t': 'resp', 'reqId': '3', 'error': 'device_unavailable'},
    });
    await _flush();
    expect(transport.sent, hasLength(firstStopCount));
    transport.message({
      'type': 'message',
      'clientId': 'app',
      'data': {
        't': 'ev',
        'ev': 'devices.snapshot',
        'devices': [_device()],
      },
    });
    expect(device.phase, CoyoteConnectionPhase.error);
    await expectLater(device.testOutput(), throwsStateError);
  });

  test('急停取消仍在本地队列中的正向输出', () async {
    await _pair(device, transport);
    transport.sent.clear();
    device.emit(
      const TriggerEvent(
        sessionId: 'session',
        sequence: 1,
        elapsed: Duration.zero,
        reason: TriggerReason.outside,
      ),
    );
    await device.emergencyStop();
    await _flush();
    final positive = transport.sent
        .map(_rpc)
        .where((value) => value['m'] == 'device.op')
        .map((value) => value['data'] as Map<String, dynamic>)
        .where((value) => value['t'] == 4 || value['t'] == 0);
    expect(positive, isEmpty);
  });

  test('停止输出不清空触发 Cooldown', () async {
    await _pair(device, transport);
    transport.sent.clear();
    const event = TriggerEvent(
      sessionId: 'session',
      sequence: 1,
      elapsed: Duration.zero,
      reason: TriggerReason.outside,
    );
    device.emit(event);
    await _flush();
    await device.stop();
    now = now.add(const Duration(seconds: 2));
    device.emit(event);
    await _flush();
    final positive = transport.sent
        .map(_rpc)
        .where((value) => value['m'] == 'device.op')
        .map((value) => value['data'] as Map<String, dynamic>)
        .where((value) => value['t'] == 4);
    expect(positive, hasLength(1));
  });

  test('方向映射将左/右/双侧送到 A/B/A+B，未知侧别回退选定通道', () async {
    device.configure(
      const CoyoteConfig(
        channel: CoyoteChannel.b,
        triggerIntensity: 5,
        maxIntensity: 10,
        cooldown: Duration(milliseconds: 500),
        directionalMapping: true,
      ),
    );
    await _pair(device, transport);

    Future<Set<int>> emitFor(TriggerSide side) async {
      transport.sent.clear();
      device.emit(
        TriggerEvent(
          sessionId: 'session',
          sequence: 1,
          elapsed: Duration.zero,
          reason: TriggerReason.outside,
          side: side,
        ),
      );
      await _flush();
      final channels = transport.sent
          .map(_rpc)
          .where((value) => value['m'] == 'device.op')
          .map((value) => value['data'] as Map<String, dynamic>)
          .where((value) => value['t'] == 4)
          .map((value) => value['c'] as int)
          .toSet();
      await device.stop();
      now = now.add(const Duration(milliseconds: 500));
      return channels;
    }

    expect(await emitFor(TriggerSide.left), {0});
    expect(await emitFor(TriggerSide.right), {1});
    expect(await emitFor(TriggerSide.both), {0, 1});
    expect(await emitFor(TriggerSide.unknown), {1});
  });

  test('双区事件即使关闭普通方向映射也强制送到对应通道', () async {
    device.configure(
      const CoyoteConfig(
        channel: CoyoteChannel.b,
        triggerIntensity: 5,
        maxIntensity: 10,
        directionalMapping: false,
      ),
    );
    await _pair(device, transport);
    transport.sent.clear();
    device.emit(
      const TriggerEvent(
        sessionId: 'dual-zone',
        sequence: 1,
        elapsed: Duration.zero,
        reason: TriggerReason.wrongZone,
        side: TriggerSide.left,
        forceDirectional: true,
      ),
    );
    await _flush();
    final channels = transport.sent
        .map(_rpc)
        .where((value) => value['m'] == 'device.op')
        .map((value) => value['data'] as Map<String, dynamic>)
        .where((value) => value['t'] == 4)
        .map((value) => value['c'] as int)
        .toSet();
    expect(channels, {0});
  });

  test('Safety event 映射 A+B，统一 clamp 并对连续事件 cooldown', () async {
    device.configure(
      const CoyoteConfig(
        channel: CoyoteChannel.both,
        triggerIntensity: 100,
        maxIntensity: 12,
        duration: Duration(seconds: 1),
        cooldown: Duration(seconds: 3),
      ),
    );
    await _pair(device, transport);
    transport.sent.clear();
    const event = TriggerEvent(
      sessionId: 'session',
      sequence: 1,
      elapsed: Duration.zero,
      reason: TriggerReason.outside,
    );
    device.emit(event);
    device.emit(event);
    await _flush();
    final tasks = transport.sent
        .map(_rpc)
        .where((value) => value['m'] == 'device.op')
        .map((value) => value['data'] as Map<String, dynamic>)
        .toList();
    final intensityTasks = tasks.where((task) => task['t'] == 4).toList();
    expect(intensityTasks, hasLength(2));
    expect(intensityTasks.map((task) => task['c']).toSet(), {0, 1});
    expect(intensityTasks.every((task) => task['v'] == 12), isTrue);

    now = now.add(const Duration(seconds: 3));
    device.emit(event);
    await _flush();
    final allIntensityTasks = transport.sent
        .map(_rpc)
        .where((value) => value['m'] == 'device.op')
        .map((value) => value['data'] as Map<String, dynamic>)
        .where((task) => task['t'] == 4);
    expect(allIntensityTasks, hasLength(4));
  });

  test('B 通道映射、低强度测试限制和短持续时间', () async {
    device.configure(
      const CoyoteConfig(
        channel: CoyoteChannel.b,
        triggerIntensity: 90,
        maxIntensity: 100,
        duration: Duration(seconds: 4),
      ),
    );
    await _pair(device, transport);
    transport.sent.clear();
    await device.testOutput();
    final task = transport.sent
        .map(_rpc)
        .where((value) => value['m'] == 'device.op')
        .map((value) => value['data'] as Map<String, dynamic>)
        .firstWhere((value) => value['t'] == 4);
    expect(task['c'], 1);
    expect(task['v'], CoyoteConfig.testIntensityLimit);
    expect(task['d'], CoyoteConfig.testDurationLimit.inMilliseconds);
  });

  test('无限模式使用安全分片并等待恢复或急停', () async {
    device.configure(
      const CoyoteConfig(
        channel: CoyoteChannel.a,
        triggerIntensity: 5,
        outputDurationMode: CoyoteOutputDurationMode.untilRecovery,
      ),
    );
    await _pair(device, transport);
    transport.sent.clear();

    device.emit(
      const TriggerEvent(
        sessionId: 'continuous',
        sequence: 1,
        elapsed: Duration.zero,
        reason: TriggerReason.outside,
      ),
    );
    await _flush();

    final task = transport.sent
        .map(_rpc)
        .where((value) => value['m'] == 'device.op')
        .map((value) => value['data'] as Map<String, dynamic>)
        .firstWhere((value) => value['t'] == 4);
    expect(task['d'], CoyoteConfig.protocolChunkDuration.inMilliseconds);

    await device.stop();
    expect(
      transport.sent.map(_rpc).any((value) => value['m'] == 'device.op.clear'),
      isTrue,
    );
  });

  test('急停立即 clear 全部任务并将两个通道归零', () async {
    await _pair(device, transport);
    transport.sent.clear();
    await device.emergencyStop();
    final requests = transport.sent.map(_rpc).toList();
    expect(
      requests.where((value) => value['m'] == 'device.op.clear'),
      hasLength(1),
    );
    final tasks = requests
        .where((value) => value['m'] == 'device.op')
        .map((value) => value['data'] as Map<String, dynamic>);
    expect(
      tasks
          .where((value) => value['t'] == 7 && value['v'] == 0)
          .map((value) => value['c'])
          .toSet(),
      {0, 1},
    );
  });

  test('断开会 clear，重连保持 idle 且不恢复旧输出', () async {
    await _pair(device, transport);
    transport.sent.clear();
    await device.disconnect();
    expect(device.phase, CoyoteConnectionPhase.idle);
    expect(
      transport.sent.map(_rpc).any((value) => value['m'] == 'device.op.clear'),
      isTrue,
    );

    transport.sent.clear();
    await _pair(device, transport);
    final positive = transport.sent
        .map(_rpc)
        .where((value) => value['m'] == 'device.op')
        .map((value) => value['data'] as Map<String, dynamic>)
        .where((task) => task['t'] == 4 || (task['v'] is int && task['v'] > 0));
    expect(positive, isEmpty);
    expect(device.readyToOutput, isTrue);
  });

  test('App 或实体设备断开后 fail-safe 且不可输出', () async {
    await _pair(device, transport);
    transport.message({
      'type': 'message',
      'clientId': 'app',
      'data': {
        't': 'ev',
        'ev': 'slots.patch',
        'slots': [
          {
            'slotId': 'coyote-slot',
            'slotState': {'hasDevice': false},
          },
        ],
      },
    });
    await _flush();
    expect(device.connected, isFalse);
    expect(device.readyToOutput, isFalse);
  });
}
