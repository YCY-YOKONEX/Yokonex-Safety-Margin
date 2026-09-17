import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safety_margin/domain/game_engine.dart';
import 'package:safety_margin/domain/coyote_protocol.dart';
import 'package:safety_margin/domain/ems_protocol.dart';
import 'package:safety_margin/services/output_device.dart';
import 'package:safety_margin/services/settings_store.dart';
import '../support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('参数、区域和摄像头保存在本机', () async {
    final store = LocalSettingsStore();
    await store.save(
      SavedSetup(
        config: const GameConfig(duration: Duration(minutes: 2)),
        region: testRegion(),
        cameraId: 'front',
        emsConfig: const EmsConfig(
          generation: EmsGeneration.first,
          intensityA: 120,
          intensityB: 60,
          waveform: 2,
        ),
        outputDeviceType: OutputDeviceType.dglabCoyote,
        coyoteConfig: const CoyoteConfig(
          channel: CoyoteChannel.both,
          triggerIntensity: 8,
          maxIntensity: 16,
          duration: Duration(milliseconds: 900),
          cooldown: Duration(seconds: 4),
        ),
      ),
    );
    final loaded = await store.load();
    expect(loaded.config.duration, const Duration(minutes: 2));
    expect(loaded.region!.points, testRegion().points);
    expect(loaded.cameraId, 'front');
    expect(loaded.emsConfig.generation, EmsGeneration.first);
    expect(loaded.emsConfig.intensityA, 120);
    expect(loaded.emsConfig.intensityB, 60);
    expect(loaded.emsConfig.waveform, 2);
    expect(loaded.outputDeviceType, OutputDeviceType.dglabCoyote);
    expect(loaded.coyoteConfig.channel, CoyoteChannel.both);
    expect(loaded.coyoteConfig.triggerIntensity, 8);
    expect(loaded.coyoteConfig.maxIntensity, 16);
  });
  test('连续保存按顺序完成，区域清除可以持久化', () async {
    final store = LocalSettingsStore();
    final first = store.save(
      SavedSetup(region: testRegion(), cameraId: 'front'),
    );
    final second = store.save(const SavedSetup(cameraId: 'back'));
    await Future.wait([first, second]);
    expect((await store.load()).region, isNull);
    expect((await store.load()).cameraId, 'back');
  });
  test('损坏的存储回到默认设置', () async {
    SharedPreferences.setMockInitialValues({
      LocalSettingsStore.storageKey: '{bad json',
    });
    final setup = await LocalSettingsStore().load();
    expect(setup.region, isNull);
    expect(setup.config.duration, const Duration(minutes: 5));
  });
}
