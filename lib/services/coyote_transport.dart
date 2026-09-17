import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
