import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<Map<String, dynamic>> nextFrame(StreamIterator<dynamic> stream) async {
  if (!await stream.moveNext()) throw StateError('WebSocket closed early');
  final value = stream.current;
  if (value is! String) throw StateError('Expected a text WebSocket frame');
  return Map<String, dynamic>.from(jsonDecode(value) as Map);
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/verify_dglab_relay.dart <ws-or-wss-url>',
    );
    exitCode = 64;
    return;
  }
  final base = Uri.parse(arguments.single);
  final controller = await WebSocket.connect(
    base.toString(),
  ).timeout(const Duration(seconds: 10));
  final controllerFrames = StreamIterator<dynamic>(controller);
  WebSocket? client;
  StreamIterator<dynamic>? clientFrames;
  try {
    final controllerHello = await nextFrame(controllerFrames);
    if (controllerHello['type'] != 'hello' ||
        controllerHello['clientId'] is! String) {
      throw StateError('Controller hello frame is invalid');
    }
    final targetId = controllerHello['clientId'] as String;
    client = await WebSocket.connect(
      base.replace(queryParameters: {'tid': targetId}).toString(),
    ).timeout(const Duration(seconds: 10));
    clientFrames = StreamIterator<dynamic>(client);
    final clientHello = await nextFrame(clientFrames);
    final controllerAttached = await nextFrame(clientFrames);
    final clientAttached = await nextFrame(controllerFrames);
    if (clientHello['type'] != 'hello' ||
        controllerAttached['type'] != 'controller_attached' ||
        clientAttached['type'] != 'client_attached') {
      throw StateError('V4 attach handshake is invalid');
    }
    final clientId = clientAttached['clientId'] as String;
    controller.add(
      jsonEncode({
        'type': 'message',
        'clientId': clientId,
        'data': {'t': 'req', 'reqId': 'relay-check', 'm': 'ping'},
      }),
    );
    final forwarded = await nextFrame(clientFrames);
    if (forwarded['type'] != 'message' ||
        (forwarded['data'] as Map?)?['reqId'] != 'relay-check') {
      throw StateError('Controller-to-client forwarding failed');
    }
    client.add(
      jsonEncode({
        'type': 'message',
        'data': {'t': 'resp', 'reqId': 'relay-check', 'result': {}},
      }),
    );
    final returned = await nextFrame(controllerFrames);
    if (returned['type'] != 'message' ||
        returned['clientId'] != clientId ||
        (returned['data'] as Map?)?['reqId'] != 'relay-check') {
      throw StateError('Client-to-controller forwarding failed');
    }
    stdout.writeln('DG-LAB V4 relay verification passed.');
  } finally {
    await clientFrames?.cancel();
    await client?.close();
    await controllerFrames.cancel();
    await controller.close();
  }
}
