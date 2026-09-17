import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/app/game_coordinator.dart';
import 'package:safety_margin/domain/game_engine.dart';
import 'package:safety_margin/domain/pose_sample.dart';
import 'package:safety_margin/services/settings_store.dart';
import 'package:safety_margin/services/coyote_device.dart';
import 'package:safety_margin/services/coyote_transport.dart';
import 'package:safety_margin/services/ems_device.dart';
import 'package:safety_margin/ui/game_app.dart';
import 'package:safety_margin/ui/app_localizations.dart';
import 'package:safety_margin/ui/app_theme.dart';
import '../support/fakes.dart';

class _WidgetEmsTransport implements EmsTransport {
  final scanController = StreamController<EmsPeripheral>.broadcast();
  final linkController = StreamController<EmsLinkState>.broadcast();
  final notificationController = StreamController<List<int>>.broadcast();
  int permissionRequests = 0;

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
  Future<void> write(String deviceId, List<int> value) async {}

  Future<void> close() async {
    await scanController.close();
    await linkController.close();
    await notificationController.close();
  }
}

class _WidgetCoyoteTransport implements CoyoteTransport {
  final controller = StreamController<CoyoteTransportEvent>.broadcast(
    sync: true,
  );
  int connects = 0;

  @override
  Stream<CoyoteTransportEvent> get events => controller.stream;

  @override
  Future<void> connect(Uri uri) async {
    connects++;
  }

  @override
  Future<void> send(Map<String, dynamic> frame) async {}

  @override
  Future<void> close() async {}

  Future<void> dispose() => controller.close();
}

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(768, 1024),
  ]) {
    testWidgets('准备、游戏和结果界面无溢出 $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late FakePoseCamera camera;
      final c = GameCoordinator(
        cameraFactory: (readEpoch) => camera = FakePoseCamera(readEpoch),
        store: FakeSettingsStore(
          SavedSetup(
            // 该用例只关心各屏幕尺寸下的布局是否溢出，跳过准备倒计时。
            config: const GameConfig(startCountdown: Duration.zero),
            region: testRegion(),
            cameraId: 'front',
          ),
        ),
        keepAwake: (_) async {},
        autoTick: false,
      );
      await tester.pumpWidget(SafetyMarginApp(coordinator: c));
      await tester.pumpAndSettle();
      camera.emit(fullPose());
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(const ValueKey('region_canvas'))).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const ValueKey('start_game'))).top,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('start_game')));
      await tester.pumpAndSettle();
      expect(c.engine.phase, GamePhase.running);
      expect(find.text('05:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(const ValueKey('region_canvas'))).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const ValueKey('pause_resume'))).top,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('pause_resume')));
      await tester.pumpAndSettle();
      expect(c.engine.phase, GamePhase.paused);
      camera.emit(fullPose());
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pause_resume')));
      await tester.pumpAndSettle();
      expect(c.engine.phase, GamePhase.running);
      camera.fail();
      await tester.pumpAndSettle();
      expect(c.engine.phase, GamePhase.paused);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('结束'));
      await tester.pumpAndSettle();
      expect(find.text('本局结果'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('再来一局'));
      await tester.pumpAndSettle();
      expect(c.engine.phase, GamePhase.ready);
      expect(c.canStart, isFalse);
    });
  }

  testWidgets('开始游戏先倒计时，可取消，倒计时结束后才真正开始', (tester) async {
    late FakePoseCamera camera;
    final c = GameCoordinator(
      cameraFactory: (readEpoch) => camera = FakePoseCamera(readEpoch),
      store: FakeSettingsStore(
        SavedSetup(
          config: const GameConfig(startCountdown: Duration(seconds: 3)),
          region: testRegion(),
          cameraId: 'front',
        ),
      ),
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(SafetyMarginApp(coordinator: c));
    await tester.pumpAndSettle();
    camera.emit(fullPose());
    await tester.pump();
    String countdownText() => tester
        .widget<Text>(find.byKey(const ValueKey('start_countdown')))
        .data!;

    // 取消倒计时不会真正开始游戏。
    await tester.tap(find.byKey(const ValueKey('start_game')));
    await tester.pump();
    expect(countdownText(), '3');
    expect(c.engine.phase, GamePhase.ready);
    await tester.tap(find.byKey(const ValueKey('cancel_countdown')));
    await tester.pump();
    expect(find.byKey(const ValueKey('start_countdown')), findsNothing);
    expect(c.engine.phase, GamePhase.ready);

    // 不需要画面中已有人也能开始倒计时；倒计时期间人物没有进入区域也不会提前判定。
    await tester.tap(find.byKey(const ValueKey('start_game')));
    await tester.pump();
    expect(countdownText(), '3');
    await tester.pump(const Duration(seconds: 1));
    expect(countdownText(), '2');
    expect(c.engine.phase, GamePhase.ready);
    await tester.pump(const Duration(seconds: 1));
    expect(countdownText(), '1');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(c.engine.phase, GamePhase.running);
  });

  testWidgets('越界或跟踪异常时显示屏幕四周红光，恢复后消失', (tester) async {
    late FakePoseCamera camera;
    final c = GameCoordinator(
      cameraFactory: (readEpoch) => camera = FakePoseCamera(readEpoch),
      store: FakeSettingsStore(
        SavedSetup(
          config: const GameConfig(startCountdown: Duration.zero),
          region: testRegion(),
          cameraId: 'front',
        ),
      ),
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(SafetyMarginApp(coordinator: c));
    await tester.pumpAndSettle();
    camera.emit(fullPose());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('start_game')));
    await tester.pumpAndSettle();
    expect(c.engine.phase, GamePhase.running);

    // 跟踪不完整也属于异常状态，但不会立即触发声音输出，适合验证红光。
    camera.emit(PoseSample({}));
    await tester.pump();
    expect(find.byKey(const ValueKey('event_alert_glow')), findsOneWidget);

    camera.emit(fullPose());
    await tester.pump();
    expect(find.byKey(const ValueKey('event_alert_glow')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('矩形和自由圈画手势可生成区域', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = GameCoordinator(
      cameraFactory: (readEpoch) => FakePoseCamera(readEpoch),
      store: FakeSettingsStore(),
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(SafetyMarginApp(coordinator: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('矩形画区'));
    await tester.pumpAndSettle();
    final canvas = tester.getRect(find.byKey(const ValueKey('region_canvas')));
    expect(c.camera.ready, isTrue);
    expect(c.loading, isFalse);
    await tester.dragFrom(
      canvas.topLeft + const Offset(30, 30),
      const Offset(280, 400),
    );
    await tester.pumpAndSettle();
    expect(c.region, isNotNull, reason: '快速斜向拖动必须生成矩形');
    await tester.tap(find.byTooltip('重画区域'));
    await tester.pumpAndSettle();
    final rectangle = await tester.startGesture(
      canvas.topLeft + const Offset(30, 80),
    );
    await rectangle.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(c.editing, isTrue);
    await rectangle.moveTo(canvas.topLeft + const Offset(310, 430));
    await rectangle.up();
    await tester.pumpAndSettle();
    expect(c.region, isNotNull);
    await tester.tap(find.byTooltip('重画区域'));
    await tester.pumpAndSettle();
    expect(c.region, isNull);
    await tester.tap(find.byTooltip('自由圈画'));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      canvas.topLeft + const Offset(30, 30),
    );
    await gesture.moveTo(canvas.topLeft + const Offset(300, 30));
    await gesture.moveTo(canvas.topLeft + const Offset(300, 400));
    await gesture.moveTo(canvas.topLeft + const Offset(30, 400));
    await gesture.moveTo(canvas.topLeft + const Offset(30, 30));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(c.region, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('游戏时长表单校验并保存', (tester) async {
    final c = GameCoordinator(
      cameraFactory: (readEpoch) => FakePoseCamera(readEpoch),
      store: FakeSettingsStore(),
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(SafetyMarginApp(coordinator: c));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('自定'));
    await tester.tap(find.text('自定'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNWidgets(2));
    await tester.enterText(find.byType(TextFormField).at(0), '0');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 0.02 至 1440 分钟'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).at(0), '4');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(c.engine.config.duration, const Duration(minutes: 4));
  });

  testWidgets('暗色首页快捷时长保留区域', (tester) async {
    final region = testRegion();
    final store = FakeSettingsStore(
      SavedSetup(region: region, cameraId: 'front'),
    );
    final c = GameCoordinator(
      cameraFactory: (epoch) => FakePoseCamera(epoch),
      store: store,
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(SafetyMarginApp(coordinator: c));
    await tester.pumpAndSettle();
    final theme = Theme.of(tester.element(find.byType(Scaffold)));
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, AppColors.paper);
    expect(theme.colorScheme.primary, AppColors.wine);
    await tester.ensureVisible(find.byKey(const ValueKey('duration_presets')));
    await tester.tap(find.text('10 分钟'));
    await tester.pumpAndSettle();
    expect(c.engine.config.duration, const Duration(minutes: 10));
    expect(store.setup.region, same(region));
    expect(tester.takeException(), isNull);
  });

  testWidgets('自定时长可重复编辑，关闭不保存', (tester) async {
    final c = GameCoordinator(
      cameraFactory: (epoch) => FakePoseCamera(epoch),
      store: FakeSettingsStore(
        const SavedSetup(config: GameConfig(duration: Duration(minutes: 7))),
      ),
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(SafetyMarginApp(coordinator: c));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('自定'));
    await tester.tap(find.text('自定'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), '9');
    await tester.tap(find.byTooltip('关闭设置'));
    await tester.pumpAndSettle();
    expect(c.engine.config.duration, const Duration(minutes: 7));
    await tester.tap(find.text('自定'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), '6.5');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(c.engine.config.duration, const Duration(seconds: 390));
    await tester.tap(find.text('自定'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('小屏放大字体与键盘下仍可编辑并保存游戏时长', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final c = GameCoordinator(
      cameraFactory: (epoch) => FakePoseCamera(epoch),
      store: FakeSettingsStore(),
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(SafetyMarginApp(coordinator: c));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('自定'));
    await tester.tap(find.text('自定'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pumpAndSettle();
    final duration = find.byType(TextFormField).at(0);
    await tester.ensureVisible(duration);
    await tester.enterText(duration, '6');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(c.engine.config.duration, const Duration(minutes: 6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('EMS 设置页提供波形曲线和 A/B 通道各自 180 级强度', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transport = _WidgetEmsTransport();
    final c = GameCoordinator(
      ems: EmsDeviceController(transport: transport),
      cameraFactory: (epoch) => FakePoseCamera(epoch),
      store: FakeSettingsStore(),
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(SafetyMarginApp(coordinator: c));
    await tester.pumpAndSettle();
    expect(transport.permissionRequests, 1);
    expect(find.text('前置摄像头'), findsNothing);
    expect(find.text('后置摄像头'), findsNothing);
    expect(find.text('连接设备'), findsOneWidget);
    await tester.tap(find.byTooltip('EMS 设备'));
    await tester.pumpAndSettle();
    expect(find.text('波形曲线'), findsOneWidget);
    expect(find.text('A 通道强度'), findsOneWidget);
    expect(find.text('B 通道强度'), findsOneWidget);
    expect(find.byKey(const ValueKey('ems_intensity_a')), findsOneWidget);
    expect(find.byKey(const ValueKey('ems_intensity_b')), findsOneWidget);
    expect(find.byKey(const ValueKey('ems_intensity_a_input')), findsOneWidget);
    expect(find.byKey(const ValueKey('ems_intensity_b_input')), findsOneWidget);
    expect(find.text('0 / 180'), findsNWidgets(2));
    expect(find.text('越界强度递增'), findsOneWidget);
    expect(find.byKey(const ValueKey('ems_ramp_input')), findsOneWidget);
    // 未连接设备时不展示代次标签（无法识别）。
    expect(find.byKey(const ValueKey('ems_generation_label')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ems_waveform')));
    await tester.pumpAndSettle();
    expect(find.text('阶梯递增'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await transport.close();
  });

  testWidgets('切换到 DG-LAB 后点击连接会显示官方配对二维码和安全控件', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final emsTransport = _WidgetEmsTransport();
    final coyoteTransport = _WidgetCoyoteTransport();
    final c = GameCoordinator(
      ems: EmsDeviceController(transport: emsTransport),
      coyote: CoyoteDeviceController(transport: coyoteTransport),
      cameraFactory: (epoch) => FakePoseCamera(epoch),
      store: FakeSettingsStore(),
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(SafetyMarginApp(coordinator: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('EMS 设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DG-LAB Coyote'));
    await tester.pumpAndSettle();
    expect(find.text('DG-LAB Coyote 3.0'), findsOneWidget);
    expect(find.byKey(const ValueKey('coyote_channel')), findsOneWidget);
    expect(find.byKey(const ValueKey('coyote_waveform')), findsOneWidget);
    expect(find.text('最大允许强度'), findsOneWidget);
    expect(find.byKey(const ValueKey('coyote_emergency_stop')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('coyote_connect')));
    await tester.pump();
    expect(coyoteTransport.connects, 1);
    coyoteTransport.controller.add(
      const CoyoteTransportMessage({
        'type': 'hello',
        'clientId': 'controller-id',
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('等待扫码'), findsOneWidget);
    expect(find.byKey(const ValueKey('coyote_qr')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await emsTransport.close();
    await coyoteTransport.dispose();
  });

  testWidgets('可切换九种外语且核心文案完整显示', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transport = _WidgetEmsTransport();
    final c = GameCoordinator(
      ems: EmsDeviceController(transport: transport),
      cameraFactory: (epoch) => FakePoseCamera(epoch),
      store: FakeSettingsStore(),
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(SafetyMarginApp(coordinator: c));
    await tester.pumpAndSettle();

    for (final locale in supportedAppLocales.skip(1)) {
      await tester.tap(find.byKey(const ValueKey('language_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(appLanguageNames[locale.languageCode]!).last);
      await tester.pumpAndSettle();

      final localizations = AppLocalizations(locale);
      expect(
        find.text(localizations.text('连接设备')),
        findsOneWidget,
        reason: locale.languageCode,
      );
      expect(find.text('连接设备'), findsNothing, reason: locale.languageCode);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('language_menu')),
          matching: find.text(localizations.text('语言')),
        ),
        findsOneWidget,
        reason: locale.languageCode,
      );
      expect(tester.takeException(), isNull, reason: locale.languageCode);
    }

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await transport.close();
  });
}
