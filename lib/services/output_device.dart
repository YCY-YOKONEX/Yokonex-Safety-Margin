import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/game_engine.dart';
import 'coyote_device.dart';
import 'ems_device.dart';

enum OutputDeviceType { yokonex, dglabCoyote }

class OutputDeviceController extends ChangeNotifier implements TriggerSink {
  OutputDeviceController({
    EmsDeviceController? yokonex,
    CoyoteDeviceController? coyote,
  }) : yokonex = yokonex ?? EmsDeviceController(),
       coyote = coyote ?? CoyoteDeviceController() {
    this.yokonex.addListener(_childChanged);
    this.coyote.addListener(_childChanged);
    this.yokonex.onFault = (message) =>
        _childFault(OutputDeviceType.yokonex, message);
    this.coyote.onFault = (message) =>
        _childFault(OutputDeviceType.dglabCoyote, message);
  }

  final EmsDeviceController yokonex;
  final CoyoteDeviceController coyote;
  OutputDeviceType selected = OutputDeviceType.yokonex;
  void Function(String message)? onFault;
  bool _disposed = false;

  bool get connected => switch (selected) {
    OutputDeviceType.yokonex => yokonex.connected,
    OutputDeviceType.dglabCoyote => coyote.connected,
  };

  bool get readyToOutput => switch (selected) {
    OutputDeviceType.yokonex => yokonex.readyToOutput,
    OutputDeviceType.dglabCoyote => coyote.readyToOutput,
  };

  Future<void> select(OutputDeviceType value) async {
    if (selected == value) return;
    await emergencyStop();
    selected = value;
    notifyListeners();
  }

  @override
  void emit(TriggerEvent event) {
    switch (selected) {
      case OutputDeviceType.yokonex:
        yokonex.emit(event);
      case OutputDeviceType.dglabCoyote:
        coyote.emit(event);
    }
  }

  @override
  void reset() {
    unawaited(emergencyStop());
  }

  Future<void> stop() => switch (selected) {
    OutputDeviceType.yokonex => yokonex.stop(),
    OutputDeviceType.dglabCoyote => coyote.stop(),
  };

  Future<void> emergencyStop() async {
    await Future.wait([
      yokonex.stop().catchError((Object _) {}),
      coyote.emergencyStop(notify: false).catchError((Object _) {}),
    ]);
    if (!_disposed) notifyListeners();
  }

  Future<void> disconnectAll() async {
    await emergencyStop();
    await Future.wait([
      yokonex.disconnect().catchError((Object _) {}),
      coyote.disconnect().catchError((Object _) {}),
    ]);
  }

  void _childChanged() {
    if (!_disposed) notifyListeners();
  }

  void _childFault(OutputDeviceType source, String message) {
    if (!_disposed && source == selected) onFault?.call(message);
  }

  @override
  void dispose() {
    _disposed = true;
    yokonex.removeListener(_childChanged);
    coyote.removeListener(_childChanged);
    yokonex.onFault = null;
    coyote.onFault = null;
    yokonex.dispose();
    coyote.dispose();
    super.dispose();
  }
}
