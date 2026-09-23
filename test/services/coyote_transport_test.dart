import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/domain/coyote_protocol.dart';
import 'package:safety_margin/services/coyote_device.dart';
import 'package:safety_margin/services/coyote_transport.dart';

void main() {
  test('内嵌 V4 Relay 完成回环配对和双向消息透传', () async {
    final transport = EmbeddedV4CoyoteTransport(loopback: true);
    addTearDown(transport.close);
    final helloFuture = transport.events
        .where((event) => event is CoyoteTransportMessage)
        .cast<CoyoteTransportMessage>()
        .map((event) => event.data)
        .firstWhere((frame) => frame['type'] == 'hello');

    await transport.connect(Uri.parse('dglab-local://loopback'));
    final hello = await helloFuture;
    final controllerId = hello['clientId'] as String;
    expect(controllerId, matches(RegExp(r'^[0-9a-f]{8}$')));
    final endpoint = transport.pairingBaseUri!.replace(
      queryParameters: {'tid': controllerId},
    );
    expect(endpoint.host, '127.0.0.1');

    final attachedFuture = transport.events
        .where((event) => event is CoyoteTransportMessage)
        .cast<CoyoteTransportMessage>()
        .map((event) => event.data)
        .firstWhere((frame) => frame['type'] == 'client_attached');
    final socket = await WebSocket.connect(endpoint.toString());
    addTearDown(socket.close);
    final appFrames = StreamIterator<dynamic>(socket);

    expect(await appFrames.moveNext(), isTrue);
    final appHello = jsonDecode(appFrames.current as String) as Map;
    expect(appHello['type'], 'hello');
    final clientId = appHello['clientId'] as String;
    expect(clientId, matches(RegExp(r'^[0-9a-f]{8}$')));
    expect(await appFrames.moveNext(), isTrue);
    final controllerAttached = jsonDecode(appFrames.current as String) as Map;
    expect(controllerAttached['type'], 'controller_attached');
    expect(controllerAttached['clientId'], controllerId);
    expect((await attachedFuture)['clientId'], clientId);

    final reportFuture = transport.events
        .where((event) => event is CoyoteTransportMessage)
        .cast<CoyoteTransportMessage>()
        .map((event) => event.data)
        .firstWhere(
          (frame) =>
              frame['type'] == 'message' && frame['clientId'] == clientId,
        );
    socket.add(
      jsonEncode({
        'type': 'message',
        'data': {'t': 'ev', 'ev': 'devices.snapshot', 'devices': []},
      }),
    );
    final report = await reportFuture;
    expect((report['data'] as Map)['ev'], 'devices.snapshot');

    await transport.send({
      'type': 'message',
      'clientId': clientId,
      'data': {'t': 'req', 'reqId': '1', 'm': 'devices.get'},
    });
    expect(await appFrames.moveNext(), isTrue);
    final request = jsonDecode(appFrames.current as String) as Map;
    expect(request['type'], 'message');
    expect((request['data'] as Map)['m'], 'devices.get');
    expect(request.containsKey('clientId'), isFalse);

    await appFrames.cancel();
  });

  test('错误 tid 无法接入内嵌 Relay', () async {
    final transport = EmbeddedV4CoyoteTransport(loopback: true);
    addTearDown(transport.close);
    await transport.connect(Uri.parse('dglab-local://loopback'));
    final endpoint = transport.pairingBaseUri!.replace(
      queryParameters: {'tid': 'wrong'},
    );
    await expectLater(
      WebSocket.connect(endpoint.toString()),
      throwsA(anything),
    );
  });

  test('Coyote controller 通过本机 Relay 发现 App 暴露的设备', () async {
    final device = CoyoteDeviceController();
    addTearDown(device.dispose);
    device.configure(
      const CoyoteConfig(connectionMode: CoyoteConnectionMode.loopback),
    );
    final waitingForScan = Completer<void>();
    device.addListener(() {
      if (device.phase == CoyoteConnectionPhase.waitingForScan &&
          !waitingForScan.isCompleted) {
        waitingForScan.complete();
      }
    });
    await device.connect();
    await waitingForScan.future.timeout(const Duration(seconds: 2));
    expect(device.phase, CoyoteConnectionPhase.waitingForScan);
    final endpoint = device.pairingSocketUri!;
    expect(endpoint.host, '127.0.0.1');

    final connected = Completer<void>();
    device.addListener(() {
      if (device.connected && !connected.isCompleted) connected.complete();
    });
    final socket = await WebSocket.connect(endpoint.toString());
    addTearDown(socket.close);
    final appFrames = StreamIterator<dynamic>(socket);
    expect(await appFrames.moveNext(), isTrue);
    expect(await appFrames.moveNext(), isTrue);
    socket.add(
      jsonEncode({
        'type': 'message',
        'data': {
          't': 'ev',
          'ev': 'devices.snapshot',
          'devices': [
            {
              'slotId': 'slot-local',
              'name': 'Coyote 3.0',
              'type': 'COYOTE_030',
              'slotState': {'hasDevice': true},
              'props': {
                'connectState': 'connected',
                'intensityA': 0,
                'intensityB': 0,
              },
            },
          ],
        },
      }),
    );
    await connected.future.timeout(const Duration(seconds: 2));
    expect(device.activeDevice?.slotId, 'slot-local');
    expect(device.activeDevice?.intensityA, 0);
    expect(device.activeDevice?.intensityB, 0);
    await appFrames.cancel();
    await device.disconnect();
  });
}
