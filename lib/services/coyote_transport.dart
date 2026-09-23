import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

sealed class CoyoteTransportEvent {
  const CoyoteTransportEvent();
}

class CoyoteTransportMessage extends CoyoteTransportEvent {
  const CoyoteTransportMessage(this.data);
  final Map<String, dynamic> data;
}

class CoyoteTransportDisconnected extends CoyoteTransportEvent {
  const CoyoteTransportDisconnected([this.reason]);
  final String? reason;
}

class CoyoteTransportFailure extends CoyoteTransportEvent {
  const CoyoteTransportFailure(this.error);
  final Object error;
}

abstract interface class CoyoteTransport {
  Stream<CoyoteTransportEvent> get events;
  Future<void> connect(Uri uri);
  Future<void> send(Map<String, dynamic> frame);
  Future<void> close();
}

abstract interface class CoyotePairingEndpoint {
  Uri? get pairingBaseUri;
}

/// Routes normal URLs to the official relay client and `dglab-local://` URLs
/// to an embedded V4 relay. The embedded server has no external runtime.
class AdaptiveCoyoteTransport
    implements CoyoteTransport, CoyotePairingEndpoint {
  final _events = StreamController<CoyoteTransportEvent>.broadcast();
  CoyoteTransport? _active;
  StreamSubscription<CoyoteTransportEvent>? _subscription;

  @override
  Stream<CoyoteTransportEvent> get events => _events.stream;

  @override
  Uri? get pairingBaseUri {
    final active = _active;
    return switch (active) {
      final CoyotePairingEndpoint endpoint => endpoint.pairingBaseUri,
      _ => null,
    };
  }

  @override
  Future<void> connect(Uri uri) async {
    await close();
    final transport = uri.scheme == 'dglab-local'
        ? EmbeddedV4CoyoteTransport(loopback: uri.host == 'loopback')
        : IoCoyoteTransport();
    _active = transport;
    _subscription = transport.events.listen(_events.add);
    await transport.connect(uri);
  }

  @override
  Future<void> send(Map<String, dynamic> frame) {
    final active = _active;
    if (active == null) throw StateError('DG-LAB transport 未连接');
    return active.send(frame);
  }

  @override
  Future<void> close() async {
    final subscription = _subscription;
    final active = _active;
    _subscription = null;
    _active = null;
    await subscription?.cancel();
    await active?.close();
  }
}

/// Minimal in-process implementation of the official V4 relay protocol.
class EmbeddedV4CoyoteTransport
    implements CoyoteTransport, CoyotePairingEndpoint {
  EmbeddedV4CoyoteTransport({required this.loopback});

  final bool loopback;
  final _events = StreamController<CoyoteTransportEvent>.broadcast();
  final Map<String, WebSocket> _clients = {};
  final Random _random = Random.secure();
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _serverSubscription;
  Timer? _heartbeat;
  String? _controllerId;

  @override
  Stream<CoyoteTransportEvent> get events => _events.stream;

  @override
  Uri? pairingBaseUri;

  @override
  Future<void> connect(Uri uri) async {
    await close();
    final bindAddress = loopback
        ? InternetAddress.loopbackIPv4
        : InternetAddress.anyIPv4;
    final server = await HttpServer.bind(bindAddress, 0, shared: false);
    _server = server;
    final advertisedHost = loopback ? '127.0.0.1' : await _localIpv4();
    if (advertisedHost == null) {
      await server.close(force: true);
      _server = null;
      throw StateError('未找到局域网 IPv4 地址，请先连接 Wi-Fi 或开启热点');
    }
    pairingBaseUri = Uri(
      scheme: 'ws',
      host: advertisedHost,
      port: server.port,
      path: '/v4',
    );
    final controllerId = _newId();
    _controllerId = controllerId;
    _serverSubscription = server.listen(
      _handleRequest,
      onError: (Object error) => _events.add(CoyoteTransportFailure(error)),
    );
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      final frame = jsonEncode(const {'type': 'heartbeat'});
      for (final socket in _clients.values) {
        if (socket.readyState == WebSocket.open) socket.add(frame);
      }
    });
    _events.add(
      CoyoteTransportMessage({'type': 'hello', 'clientId': controllerId}),
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.upgradeRequired;
      await request.response.close();
      return;
    }
    if (request.uri.queryParameters['tid'] != _controllerId) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      final clientId = _newId();
      _clients[clientId] = socket;
      socket.add(jsonEncode({'type': 'hello', 'clientId': clientId}));
      socket.add(
        jsonEncode({'type': 'controller_attached', 'clientId': _controllerId}),
      );
      _events.add(
        CoyoteTransportMessage({
          'type': 'client_attached',
          'clientId': clientId,
        }),
      );
      socket.listen(
        (dynamic value) => _handleClientFrame(clientId, socket, value),
        onError: (Object error) => _events.add(CoyoteTransportFailure(error)),
        onDone: () => _removeClient(clientId, socket),
        cancelOnError: false,
      );
    } on Object catch (error) {
      _events.add(CoyoteTransportFailure(error));
    }
  }

  void _handleClientFrame(String clientId, WebSocket socket, dynamic value) {
    if (value is! String) return;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return;
      final frame = Map<String, dynamic>.from(decoded);
      if (frame['type'] == 'ping') {
        socket.add(
          jsonEncode({
            'type': 'pong',
            'ts': DateTime.now().millisecondsSinceEpoch,
          }),
        );
        return;
      }
      if (frame['type'] == 'message' && frame['data'] is Map) {
        _events.add(
          CoyoteTransportMessage({
            'type': 'message',
            'clientId': clientId,
            'data': Map<String, dynamic>.from(frame['data'] as Map),
          }),
        );
      }
    } on Object catch (error) {
      _events.add(CoyoteTransportFailure(error));
    }
  }

  void _removeClient(String clientId, WebSocket socket) {
    if (!identical(_clients[clientId], socket)) return;
    _clients.remove(clientId);
    _events.add(
      CoyoteTransportMessage({
        'type': 'client_disconnected',
        'clientId': clientId,
      }),
    );
  }

  @override
  Future<void> send(Map<String, dynamic> frame) async {
    switch (frame['type']) {
      case 'ping':
        _events.add(
          CoyoteTransportMessage({
            'type': 'pong',
            'ts': DateTime.now().millisecondsSinceEpoch,
          }),
        );
        return;
      case 'message':
        final clientId = frame['clientId'];
        final socket = clientId is String ? _clients[clientId] : null;
        if (socket == null || socket.readyState != WebSocket.open) {
          throw StateError('DG-LAB App 未连接');
        }
        socket.add(jsonEncode({'type': 'message', 'data': frame['data']}));
        return;
      default:
        throw StateError('不支持的 DG-LAB V4 服务帧');
    }
  }

  @override
  Future<void> close() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    final controllerId = _controllerId;
    _controllerId = null;
    pairingBaseUri = null;
    final sockets = _clients.values.toList(growable: false);
    _clients.clear();
    for (final socket in sockets) {
      if (socket.readyState == WebSocket.open) {
        socket.add(
          jsonEncode({
            'type': 'controller_disconnected',
            'clientId': controllerId,
          }),
        );
      }
      await socket.close(4000, 'controller_disconnected');
    }
    await _serverSubscription?.cancel();
    _serverSubscription = null;
    await _server?.close(force: true);
    _server = null;
  }

  String _newId() {
    String value;
    do {
      // 官方 V4 Relay 使用 4 个随机字节，即 8 位十六进制 clientId。
      value = List.generate(
        4,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
    } while (value == _controllerId || _clients.containsKey(value));
    return value;
  }

  Future<String?> _localIpv4() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    interfaces.sort((a, b) => _interfaceRank(a).compareTo(_interfaceRank(b)));
    final addresses = interfaces.expand((value) => value.addresses).toList();
    for (final address in addresses) {
      if (_isPrivateIpv4(address.address)) return address.address;
    }
    return addresses.firstOrNull?.address;
  }

  int _interfaceRank(NetworkInterface interface) {
    final name = interface.name.toLowerCase();
    if (name.contains('wlan') || name.contains('wifi')) return 0;
    if (name.contains('ap') || name == 'en0') return 1;
    if (name.contains('eth')) return 2;
    if (name.contains('rmnet') || name.contains('cell')) return 9;
    return 5;
  }

  bool _isPrivateIpv4(String value) {
    final parts = value.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    final a = parts[0]!;
    final b = parts[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }
}

class IoCoyoteTransport implements CoyoteTransport {
  final _events = StreamController<CoyoteTransportEvent>.broadcast();
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;

  @override
  Stream<CoyoteTransportEvent> get events => _events.stream;

  @override
  Future<void> connect(Uri uri) async {
    await close();
    final socket = await WebSocket.connect(
      uri.toString(),
    ).timeout(const Duration(seconds: 8));
    _socket = socket;
    _subscription = socket.listen(
      (dynamic value) {
        if (value is! String) return;
        try {
          final decoded = jsonDecode(value);
          if (decoded is Map<String, dynamic>) {
            _events.add(CoyoteTransportMessage(decoded));
          }
        } on Object catch (error) {
          _events.add(CoyoteTransportFailure(error));
        }
      },
      onError: (Object error) => _events.add(CoyoteTransportFailure(error)),
      onDone: () {
        if (identical(_socket, socket)) {
          _socket = null;
          _events.add(CoyoteTransportDisconnected(socket.closeReason));
        }
      },
      cancelOnError: false,
    );
  }

  @override
  Future<void> send(Map<String, dynamic> frame) async {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw StateError('DG-LAB WebSocket 未连接');
    }
    socket.add(jsonEncode(frame));
  }

  @override
  Future<void> close() async {
    final subscription = _subscription;
    final socket = _socket;
    _subscription = null;
    _socket = null;
    await subscription?.cancel();
    await socket?.close(WebSocketStatus.normalClosure, 'client_close');
  }
}
