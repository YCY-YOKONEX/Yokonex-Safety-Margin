import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/activity_region.dart';
import '../domain/coyote_protocol.dart';
import '../domain/ems_protocol.dart';
import '../domain/game_engine.dart';
import 'output_device.dart';

class SavedSetup {
  const SavedSetup({
    this.config = const GameConfig(),
    this.region,
    this.cameraId,
    this.emsConfig = const EmsConfig(),
    this.outputDeviceType = OutputDeviceType.yokonex,
    this.coyoteConfig = const CoyoteConfig(),
    this.simulationConfig = const CoyoteConfig(),
  });
  final GameConfig config;
  final ActivityRegion? region;
  final String? cameraId;
  final EmsConfig emsConfig;
  final OutputDeviceType outputDeviceType;
  final CoyoteConfig coyoteConfig;
  final CoyoteConfig simulationConfig;
}

abstract interface class SettingsStore {
  Future<SavedSetup> load();
  Future<void> save(SavedSetup setup);
}

class LocalSettingsStore implements SettingsStore {
  static const storageKey = 'safety_margin.setup.v1';
  Future<void> _writes = Future.value();

  @override
  Future<SavedSetup> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null) return const SavedSetup();
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return SavedSetup(
        config: GameConfig.fromJson(json['config'] as Map<String, dynamic>),
        region: json['region'] == null
            ? null
            : ActivityRegion.fromJson(json['region'] as Map<String, dynamic>),
        cameraId: json['cameraId'] as String?,
        emsConfig: json['emsConfig'] == null
            ? const EmsConfig()
            : EmsConfig.fromJson(json['emsConfig'] as Map<String, dynamic>),
        outputDeviceType: json['outputDeviceType'] == null
            ? OutputDeviceType.yokonex
            : OutputDeviceType.values.byName(
                json['outputDeviceType'] as String,
              ),
        coyoteConfig: json['coyoteConfig'] == null
            ? const CoyoteConfig()
            : CoyoteConfig.fromJson(
                json['coyoteConfig'] as Map<String, dynamic>,
              ),
        simulationConfig: json['simulationConfig'] == null
            ? (json['coyoteConfig'] == null
                  ? const CoyoteConfig()
                  : CoyoteConfig.fromJson(
                      json['coyoteConfig'] as Map<String, dynamic>,
                    ))
            : CoyoteConfig.fromJson(
                json['simulationConfig'] as Map<String, dynamic>,
              ),
      );
    } on Object {
      // 损坏或不兼容的本机记录不能阻止进入准备页。
      return const SavedSetup();
    }
  }

  @override
  Future<void> save(SavedSetup setup) {
    final payload = jsonEncode({
      'config': setup.config.toJson(),
      'region': setup.region?.toJson(),
      'cameraId': setup.cameraId,
      'emsConfig': setup.emsConfig.toJson(),
      'outputDeviceType': setup.outputDeviceType.name,
      'coyoteConfig': setup.coyoteConfig.toJson(),
      'simulationConfig': setup.simulationConfig.toJson(),
    });
    final write = _writes.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(storageKey, payload)) {
        throw StateError('保存失败');
      }
    });
    _writes = write.catchError((Object _) {});
    return write;
  }
}
