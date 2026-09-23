import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/game_engine.dart';
import 'coyote_device.dart';
import 'ems_device.dart';
import 'simulation_device.dart';

enum OutputDeviceType { yokonex, dglabCoyote, simulation }

class OutputDeviceController extends ChangeNotifier implements TriggerSink {
  OutputDeviceController({
    EmsDeviceController? yokonex,
    CoyoteDeviceController? coyote,
    SimulationOutputController? simulation,
  }) : yokonex = yokonex ?? EmsDeviceController(),
       coyote = coyote ?? CoyoteDeviceController(),
       simulation = simulation ?? SimulationOutputController() {
    this.yokonex.addListener(_childChanged);
    this.coyote.addListener(_childChanged);
    this.yokonex.onFault = (message) =>
        _childFault(OutputDeviceType.yokonex, message);
    this.coyote.onFault = (message) =>
        _childFault(OutputDeviceType.dglabCoyote, message);
    this.simulation.addListener(_childChanged);
  }

  final EmsDeviceController yokonex;
  final CoyoteDeviceController coyote;
  final SimulationOutputController simulation;
  OutputDeviceType selected = OutputDeviceType.yokonex;
  void Function(String message)? onFault;
  bool _disposed = false;

  bool get connected => switch (selected) {
    OutputDeviceType.yokonex => yokonex.connected,
    OutputDeviceType.dglabCoyote => coyote.connected,
    OutputDeviceType.simulation => simulation.connected,
  };

  bool get readyToOutput => switch (selected) {
    OutputDeviceType.yokonex => yokonex.readyToOutput,
    OutputDeviceType.dglabCoyote => coyote.readyToOutput,
    OutputDeviceType.simulation => simulation.readyToOutput,
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
      case OutputDeviceType.simulation:
        simulation.emit(event);
    }
  }

  @override
  void reset() {
    unawaited(emergencyStop());
  }

  Future<void> stop() => switch (selected) {
    OutputDeviceType.yokonex => yokonex.stop(),
    OutputDeviceType.dglabCoyote => coyote.stop(),
    OutputDeviceType.simulation => simulation.stop(),
  };

  Future<void> emergencyStop() async {
    await Future.wait([
      yokonex.stop().catchError((Object _) {}),
      coyote.emergencyStop(notify: false).catchError((Object _) {}),
      simulation.emergencyStop().catchError((Object _) {}),
    ]);
    if (!_disposed) notifyListeners();
  }

  Future<void> disconnectAll() async {
    await emergencyStop();
    await Future.wait([
      yokonex.disconnect().catchError((Object _) {}),
      coyote.disconnect().catchError((Object _) {}),
      simulation.stop().catchError((Object _) {}),
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
    simulation.removeListener(_childChanged);
    yokonex.onFault = null;
    coyote.onFault = null;
    yokonex.dispose();
    coyote.dispose();
    simulation.dispose();
    super.dispose();
  }
}
