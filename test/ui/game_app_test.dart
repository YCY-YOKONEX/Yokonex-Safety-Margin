import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_margin/app/game_coordinator.dart';
import 'package:safety_margin/domain/game_engine.dart';
import 'package:safety_margin/domain/game_mode.dart';
import 'package:safety_margin/domain/pose_sample.dart';
import 'package:safety_margin/domain/coyote_protocol.dart';
import 'package:safety_margin/services/settings_store.dart';
import 'package:safety_margin/services/coyote_device.dart';
import 'package:safety_margin/services/coyote_transport.dart';
import 'package:safety_margin/services/ems_device.dart';
import 'package:safety_margin/services/speech_output.dart';
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
  Uri? lastUri;

  @override
  Stream<CoyoteTransportEvent> get events => controller.stream;

  @override
  Future<void> connect(Uri uri) async {
    connects++;
    lastUri = uri;
  }

  @override
  Future<void> send(Map<String, dynamic> frame) async {}

  @override
  Future<void> close() async {}

  Future<void> dispose() => controller.close();
}

class _RecordingSpeechOutput implements SpeechOutput {
  final spoken = <String>[];
  int stops = 0;

  @override
  Future<void> speak(String text, {required String languageTag}) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('指定姿势使用大字显示并在提示变化时语音播报', (tester) async {
    late FakePoseCamera camera;
    final speech = _RecordingSpeechOutput();
    final c = GameCoordinator(
      cameraFactory: (readEpoch) => camera = FakePoseCamera(readEpoch),
      store: FakeSettingsStore(
        const SavedSetup(
          config: GameConfig(
            mode: SafetyGameMode.poseChallenge,
            startCountdown: Duration.zero,
          ),
        ),
      ),
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(
      SafetyMarginApp(coordinator: c, speechOutput: speech),
    );
    await tester.pumpAndSettle();
    camera.emit(fullPose());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('start_game')));
    await tester.pump();

    final prompt = c.modeSession.challenge!.label;
    final promptText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('large_game_prompt')),
        matching: find.text(prompt),
      ),
    );
    expect(promptText.style?.fontSize, 28);
    expect(speech.spoken.any((text) => text.contains(prompt)), isTrue);
  });

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

  testWidgets('可选择全部游戏模式且无需画区的模式可以开始', (tester) async {
    late FakePoseCamera camera;
    final store = FakeSettingsStore(
      const SavedSetup(
        config: GameConfig(
          startCountdown: Duration.zero,
          mode: SafetyGameMode.redLightGreenLight,
        ),
        cameraId: 'front',
      ),
    );
    final c = GameCoordinator(
      cameraFactory: (readEpoch) => camera = FakePoseCamera(readEpoch),
      store: store,
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(SafetyMarginApp(coordinator: c));
    await tester.pumpAndSettle();
    camera.emit(fullPose());
    await tester.pump();

    expect(find.byKey(const ValueKey('game_mode_selector')), findsOneWidget);
    expect(find.text('自由圈画'), findsNothing);
    expect(c.canStart, isTrue);
    await tester.tap(find.byKey(const ValueKey('game_mode_selector')));
    await tester.pumpAndSettle();
    for (final mode in SafetyGameMode.values) {
      expect(find.text(mode.label), findsWidgets);
    }
    await tester.tap(find.text('闪避模式').last);
    await tester.pumpAndSettle();
    expect(c.engine.config.mode, SafetyGameMode.dodge);
    expect(store.setup.config.mode, SafetyGameMode.dodge);
    camera.emit(fullPose());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('start_game')));
    await tester.pumpAndSettle();
    expect(c.engine.phase, GamePhase.running);
    expect(find.text('闪避移动禁区'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('木头人可以保存移动、静止和随机设置', (tester) async {
    late FakePoseCamera camera;
    final store = FakeSettingsStore(
      const SavedSetup(
        config: GameConfig(mode: SafetyGameMode.redLightGreenLight),
        cameraId: 'front',
      ),
    );
    final c = GameCoordinator(
      cameraFactory: (readEpoch) => camera = FakePoseCamera(readEpoch),
      store: store,
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(SafetyMarginApp(coordinator: c));
    await tester.pumpAndSettle();
    camera.emit(fullPose());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('game_mode_settings')));
    await tester.pumpAndSettle();

    final moveSlider = tester.widget<Slider>(
      find.descendant(
        of: find.byKey(const ValueKey('red_light_move_seconds')),
        matching: find.byType(Slider),
      ),
    );
    moveSlider.onChanged!(8);
    final freezeSlider = tester.widget<Slider>(
      find.descendant(
        of: find.byKey(const ValueKey('red_light_freeze_seconds')),
        matching: find.byType(Slider),
      ),
    );
    freezeSlider.onChanged!(6);
    await tester.tap(find.byKey(const ValueKey('red_light_randomized')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save_red_light_settings')));
    await tester.pumpAndSettle();

    expect(c.engine.config.redLightSettings.moveSeconds, 8);
    expect(c.engine.config.redLightSettings.freezeSeconds, 6);
    expect(c.engine.config.redLightSettings.randomized, isTrue);
    expect(store.setup.config.redLightSettings.randomized, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自定义姿势编辑器可拖动关节点并保存超时', (tester) async {
    late FakePoseCamera camera;
    final store = FakeSettingsStore(
      const SavedSetup(
        config: GameConfig(mode: SafetyGameMode.customPose),
        cameraId: 'front',
      ),
    );
    final c = GameCoordinator(
      cameraFactory: (readEpoch) => camera = FakePoseCamera(readEpoch),
      store: store,
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(SafetyMarginApp(coordinator: c));
    await tester.pumpAndSettle();
    camera.emit(fullPose());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('game_mode_settings')));
    await tester.pumpAndSettle();

    final canvas = find.byKey(const ValueKey('custom_pose_canvas'));
    expect(
      find.byKey(const ValueKey('custom_pose_live_status')),
      findsOneWidget,
    );
    expect(find.text('姿势已对齐'), findsOneWidget);
    expect(find.text('姿势预览不会触发设备输出'), findsOneWidget);
    expect(c.engine.events, isEmpty);
    final rect = tester.getRect(canvas);
    final before =
        c.engine.config.customPoseSettings.template.points[Joint.nose]!;
    await tester.dragFrom(
      Offset(
        rect.left + rect.width * before.dx,
        rect.top + rect.height * before.dy,
      ),
      const Offset(60, 0),
    );
    await tester.pump();
    expect(find.textContaining('调整姿势'), findsOneWidget);
    expect(c.engine.events, isEmpty);
    final randomToggle = find.byKey(
      const ValueKey('custom_pose_random_enabled'),
    );
    await tester.ensureVisible(randomToggle);
    await tester.tap(randomToggle);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('custom_pose_random_mode')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('custom_pose_random_time_mode')),
      findsOneWidget,
    );
    final grace = tester.widget<Slider>(
      find.byKey(const ValueKey('custom_pose_grace')),
    );
    grace.onChanged!(5);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('save_custom_pose')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save_custom_pose')));
    await tester.pumpAndSettle();

    final saved = c.engine.config.customPoseSettings;
    expect(saved.mismatchGrace, const Duration(seconds: 5));
    expect(saved.randomEnabled, isTrue);
    expect(saved.template.points[Joint.nose], isNot(before));
    expect(store.setup.config.customPoseSettings.mismatchGrace.inSeconds, 5);
    expect(c.engine.events, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('结果页显示异常统计、方向和触发时间轴', (tester) async {
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
    camera.emit(fullPose(outside: true));
    await tester.pump();
    c.finish();
    await tester.pumpAndSettle();

    expect(find.text('异常累计'), findsOneWidget);
    expect(find.text('最长安全时段'), findsOneWidget);
    expect(find.text('左侧 · 持续 00:00'), findsOneWidget);
    expect(find.text('越界 1 · 离开 0'), findsOneWidget);
    expect(find.text('左 1 · 右 0 · 双侧 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  testWidgets('切换到 DG-LAB 后使用预置专用服务器并显示配对二维码', (tester) async {
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
    await tester.ensureVisible(find.text('DG-LAB Coyote'));
    await tester.tap(find.text('DG-LAB Coyote'));
    await tester.pumpAndSettle();
    expect(find.text('DG-LAB Coyote 3.0'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('coyote_connection_mode')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('coyote_private_relay_url')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('coyote_channel')), findsOneWidget);
    expect(find.byKey(const ValueKey('coyote_waveform')), findsOneWidget);
    expect(find.text('最大允许强度'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('coyote_output_duration_mode')),
      findsOneWidget,
    );
    expect(find.text('无限制（直到恢复）'), findsOneWidget);
    expect(find.text('设置最长时间'), findsOneWidget);
    expect(find.byKey(const ValueKey('coyote_emergency_stop')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('coyote_connect')));
    await tester.pump();
    expect(coyoteTransport.connects, 1);
    expect(
      coyoteTransport.lastUri.toString(),
      CoyoteConfig.defaultPrivateRelayUrl,
    );
    coyoteTransport.controller.add(
      const CoyoteTransportMessage({
        'type': 'hello',
        'clientId': 'controller-id',
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('等待扫码'), findsOneWidget);
    expect(find.byKey(const ValueKey('coyote_qr')), findsOneWidget);
    expect(find.byKey(const ValueKey('coyote_open_app')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('coyote_directional_mapping')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await emsTransport.close();
    await coyoteTransport.dispose();
  });

  testWidgets('模拟输出无需设备即可测试并急停', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final emsTransport = _WidgetEmsTransport();
    final c = GameCoordinator(
      ems: EmsDeviceController(transport: emsTransport),
      cameraFactory: (epoch) => FakePoseCamera(epoch),
      store: FakeSettingsStore(),
      keepAwake: (_) async {},
      autoTick: false,
    );
    await tester.pumpWidget(SafetyMarginApp(coordinator: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('EMS 设备'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('模拟输出'));
    await tester.tap(find.text('模拟输出'));
    await tester.pumpAndSettle();
    expect(find.text('模拟输出'), findsNWidgets(2));
    expect(find.textContaining('不会连接'), findsOneWidget);
    expect(find.byKey(const ValueKey('simulation_test')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('simulation_test')));
    await tester.tap(find.byKey(const ValueKey('simulation_test')));
    await tester.pump();
    expect(find.byKey(const ValueKey('simulation_active')), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('simulation_emergency_stop')),
    );
    await tester.tap(find.byKey(const ValueKey('simulation_emergency_stop')));
    await tester.pump();
    expect(find.text('当前空闲'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await emsTransport.close();
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
