import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/game_coordinator.dart';
import '../domain/activity_region.dart';
import '../domain/coyote_protocol.dart';
import '../domain/ems_protocol.dart';
import '../domain/ems_waveform.dart';
import '../domain/game_engine.dart';
import '../domain/game_mode.dart';
import '../domain/pose_sample.dart';
import '../services/ems_device.dart';
import '../services/coyote_device.dart';
import '../services/output_device.dart';
import '../services/simulation_device.dart';
import '../services/speech_output.dart';
import 'app_localizations.dart';
import 'app_theme.dart';
import 'camera_stage.dart';

class SafetyMarginApp extends StatefulWidget {
  const SafetyMarginApp({super.key, this.coordinator, this.speechOutput});
  final GameCoordinator? coordinator;
  final SpeechOutput? speechOutput;

  @override
  State<SafetyMarginApp> createState() => _SafetyMarginAppState();
}

class _SafetyMarginAppState extends State<SafetyMarginApp> {
  late final AppLocaleController _locale = AppLocaleController();

  @override
  void initState() {
    super.initState();
    unawaited(_locale.load());
  }

  @override
  void dispose() {
    _locale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _locale,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: _locale.locale,
      supportedLocales: supportedAppLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      onGenerateTitle: (context) => context.l10n.text('役次元-画地为牢'),
      theme: buildAppTheme(),
      home: GameHome(
        coordinator: widget.coordinator,
        speechOutput: widget.speechOutput,
        onLocaleChanged: _locale.setLocale,
      ),
    ),
  );
}

class GameHome extends StatefulWidget {
  const GameHome({
    super.key,
    this.coordinator,
    this.speechOutput,
    required this.onLocaleChanged,
  });
  final GameCoordinator? coordinator;
  final SpeechOutput? speechOutput;
  final ValueChanged<Locale> onLocaleChanged;

  @override
  State<GameHome> createState() => _GameHomeState();
}

class _LanguageMenu extends StatelessWidget {
  const _LanguageMenu({required this.onSelected});

  final ValueChanged<Locale> onSelected;

  @override
  Widget build(BuildContext context) {
    final selected = Localizations.localeOf(context).languageCode;
    return PopupMenuButton<Locale>(
      key: const ValueKey('language_menu'),
      tooltip: context.l10n.text('语言'),
      onSelected: onSelected,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(
          context.l10n.text('语言'),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      itemBuilder: (context) => [
        for (final locale in supportedAppLocales)
          PopupMenuItem(
            value: locale,
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: locale.languageCode == selected
                      ? const Icon(Icons.check, size: 17)
                      : null,
                ),
                const SizedBox(width: 8),
                Text(appLanguageNames[locale.languageCode]!),
              ],
            ),
          ),
      ],
    );
  }
}

class _GameHomeState extends State<GameHome> with WidgetsBindingObserver {
  late final GameCoordinator c;
  int _noticeVersion = 0;
  int? _countdownRemaining;
  Timer? _countdownTimer;
  final _tickPlayer = AudioPlayer();
  final _goPlayer = AudioPlayer();
  final _alertPlayer = AudioPlayer();
  final _modePlayer = AudioPlayer();
  late final SpeechOutput _speech;
  late final bool _ownsSpeech;
  int _lastEventCount = 0;
  bool _modeAudioActive = false;
  int _modeAudioToken = 0;
  String? _lastPromptKey;
  TrackingStatus? _lastSpokenTracking;
  GamePhase? _lastSpokenPhase;
  SafetyGameMode? _lastReadyMode;
  String? _speechLocale;

  bool get _counting => _countdownRemaining != null;

  bool get _eventAlertVisible {
    if (c.engine.phase != GamePhase.running) return false;
    if (c.engine.triggering) return true;
    return switch (c.engine.tracking) {
      TrackingStatus.outside ||
      TrackingStatus.absent ||
      TrackingStatus.incomplete => true,
      TrackingStatus.inside || TrackingStatus.waiting => false,
    };
  }

  @override
  void initState() {
    super.initState();
    c = widget.coordinator ?? GameCoordinator(enableEms: true);
    _ownsSpeech = widget.speechOutput == null;
    _speech = widget.speechOutput ?? SystemSpeechOutput();
    c.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    unawaited(c.initialize());
  }

  void _changed() {
    if (!mounted) return;
    unawaited(_syncModeAudio());
    final eventCount = c.engine.events.length;
    String? priorityAnnouncement;
    // 每次新触发（越界/跟踪不完整/画面中无人）都提醒一次，与设备持续输出解耦。
    if (eventCount > _lastEventCount) {
      unawaited(_playSound(_alertPlayer, 'trigger_alert.wav'));
      final event = c.engine.events.last;
      priorityAnnouncement = context.l10n.text(
        _triggerReasonText(event.reason),
      );
    }
    _lastEventCount = eventCount;
    if (_noticeVersion != c.noticeVersion) {
      _noticeVersion = c.noticeVersion;
      if (c.notice != null) {
        priorityAnnouncement = context.l10n.message(c.notice!);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && c.notice != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.message(c.notice!))),
          );
        }
      });
    }
    _syncSpeech(priorityAnnouncement: priorityAnnouncement);
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final locale = _speechLanguageTag(Localizations.localeOf(context));
    if (_speechLocale == locale) return;
    _speechLocale = locale;
    _lastPromptKey = null;
    _lastReadyMode = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncSpeech();
    });
  }

  String _speechLanguageTag(Locale locale) => switch (locale.languageCode) {
    'zh' => 'zh-CN',
    'en' => 'en-US',
    'fr' => 'fr-FR',
    'de' => 'de-DE',
    'nl' => 'nl-NL',
    'es' => 'es-ES',
    'ko' => 'ko-KR',
    'ja' => 'ja-JP',
    'it' => 'it-IT',
    'ru' => 'ru-RU',
    _ => locale.toLanguageTag(),
  };

  String _triggerReasonText(TriggerReason reason) => switch (reason) {
    TriggerReason.outside => '关节越界',
    TriggerReason.absent => '离开画面',
    TriggerReason.movement => '木头人移动',
    TriggerReason.pose => '姿势未完成',
    TriggerReason.obstacle => '碰到禁区',
    TriggerReason.balance => '失去平衡',
    TriggerReason.wrongZone => '进入错误区域',
    TriggerReason.customPose => '未对齐目标姿势',
  };

  void _announce(String text) {
    final languageTag = _speechLocale;
    if (languageTag == null || text.trim().isEmpty) return;
    unawaited(_speech.speak(text, languageTag: languageTag));
  }

  void _syncSpeech({String? priorityAnnouncement}) {
    if (!mounted || c.loading) return;
    final phase = c.engine.phase;
    final prompt = context.l10n.text(c.modeSession.prompt(c.engine.elapsed));
    final templateIdentity = c.engine.config.mode == SafetyGameMode.customPose
        ? identityHashCode(c.customPoseTemplate)
        : 0;
    final promptKey = '${c.engine.config.mode.name}:$prompt:$templateIdentity';
    final phaseChanged = phase != _lastSpokenPhase;
    final promptChanged = promptKey != _lastPromptKey;
    final trackingChanged = c.engine.tracking != _lastSpokenTracking;
    final readyModeChanged = c.engine.config.mode != _lastReadyMode;

    _lastSpokenPhase = phase;
    _lastPromptKey = promptKey;
    _lastSpokenTracking = c.engine.tracking;
    _lastReadyMode = c.engine.config.mode;

    if (priorityAnnouncement != null) {
      _announce(priorityAnnouncement);
      return;
    }
    if (phaseChanged) {
      switch (phase) {
        case GamePhase.ready:
          _announce('${context.l10n.text(c.engine.config.mode.label)}。$prompt');
        case GamePhase.running:
          _announce('${context.l10n.text('游戏中')}。$prompt');
        case GamePhase.paused:
          _announce(context.l10n.text('游戏已暂停'));
        case GamePhase.finished:
          _announce(context.l10n.text('游戏结束'));
      }
      return;
    }
    if (phase == GamePhase.ready && readyModeChanged) {
      _announce('${context.l10n.text(c.engine.config.mode.label)}。$prompt');
      return;
    }
    if (phase == GamePhase.running && promptChanged) {
      final prefix = c.engine.config.mode == SafetyGameMode.customPose
          ? '${context.l10n.text('目标姿势已变化')}。'
          : '';
      _announce('$prefix$prompt');
      return;
    }
    if (phase == GamePhase.running && trackingChanged) {
      final trackingText = switch (c.engine.tracking) {
        TrackingStatus.absent => '画面中无人',
        TrackingStatus.incomplete => '跟踪不完整',
        TrackingStatus.outside => '请立即修正动作',
        TrackingStatus.inside => '姿势正确',
        TrackingStatus.waiting => '等待人体识别',
      };
      _announce(context.l10n.text(trackingText));
    }
  }

  Future<void> _syncModeAudio() async {
    final shouldPlay =
        c.engine.phase == GamePhase.running &&
        c.engine.config.mode == SafetyGameMode.redLightGreenLight &&
        c.modeSession.isGreenLight(c.engine.elapsed);
    if (shouldPlay == _modeAudioActive) return;
    _modeAudioActive = shouldPlay;
    final token = ++_modeAudioToken;
    try {
      if (shouldPlay) {
        await _modePlayer.setReleaseMode(ReleaseMode.loop);
        await _modePlayer.setVolume(.32);
        if (token != _modeAudioToken || !_modeAudioActive) return;
        await _modePlayer.play(AssetSource('sounds/game_move.wav'));
      } else {
        await _modePlayer.stop();
      }
    } on Object {
      // 音频提示不可用时，画面状态仍提供完整的红绿灯判定。
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(c.setForeground(state == AppLifecycleState.resumed));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_changed);
    c.dispose();
    _countdownTimer?.cancel();
    unawaited(_tickPlayer.dispose());
    unawaited(_goPlayer.dispose());
    unawaited(_alertPlayer.dispose());
    unawaited(_modePlayer.dispose());
    if (_ownsSpeech) {
      unawaited(_speech.dispose());
    } else {
      unawaited(_speech.stop());
    }
    super.dispose();
  }

  void _startCountdown() {
    final seconds = c.engine.config.startCountdown.inSeconds;
    if (seconds <= 0) {
      c.start();
      return;
    }
    setState(() => _countdownRemaining = seconds);
    _announce('${context.l10n.text('请进入监测区域')}。$seconds');
    unawaited(_playSound(_tickPlayer, 'countdown_tick.wav'));
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remaining = (_countdownRemaining ?? 1) - 1;
      if (remaining <= 0) {
        timer.cancel();
        _countdownTimer = null;
        if (mounted) setState(() => _countdownRemaining = null);
        unawaited(_playSound(_goPlayer, 'countdown_go.wav'));
        _announce(context.l10n.text('开始'));
        c.start();
        return;
      }
      if (mounted) setState(() => _countdownRemaining = remaining);
      _announce('$remaining');
      unawaited(_playSound(_tickPlayer, 'countdown_tick.wav'));
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    if (_countdownRemaining != null) setState(() => _countdownRemaining = null);
    unawaited(_speech.stop());
  }

  Future<void> _playSound(AudioPlayer player, String asset) async {
    try {
      await player.play(AssetSource('sounds/$asset'));
    } on Object {
      // 声音播放失败不应影响倒计时流程本身。
    }
  }

  Future<void> _settings() async {
    final result = await showModalBottomSheet<GameConfig>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (_) => _SettingsSheet(config: c.engine.config),
    );
    if (mounted && result != null) c.updateConfig(result);
  }

  Future<void> _emsSettings() async {
    if (c.output == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (_) => _OutputSettingsSheet(coordinator: c),
    );
  }

  Future<void> _gameModeSettings() async {
    switch (c.engine.config.mode) {
      case SafetyGameMode.redLightGreenLight:
        final result = await showModalBottomSheet<RedLightSettings>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
          ),
          builder: (_) => _RedLightSettingsSheet(
            settings: c.engine.config.redLightSettings,
          ),
        );
        if (mounted && result != null) c.updateRedLightSettings(result);
      case SafetyGameMode.customPose:
        final result = await Navigator.of(context).push<CustomPoseSettings>(
          MaterialPageRoute(
            builder: (_) => _CustomPoseEditor(
              settings: c.engine.config.customPoseSettings,
              coordinator: c,
            ),
          ),
        );
        if (mounted && result != null) c.updateCustomPoseSettings(result);
      default:
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = c.engine.phase;
    final ready = phase == GamePhase.ready;
    final finished = phase == GamePhase.finished;
    final active = !ready && !finished;
    return PopScope(
      canPop: !active && !_counting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_counting) _cancelCountdown();
        if (phase == GamePhase.running) c.pause();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Scaffold(
            appBar: AppBar(
              toolbarHeight: 64,
              title: Text(
                context.l10n.text(finished ? '本局结果' : '画地为牢'),
                maxLines: 2,
                softWrap: true,
              ),
              actions: [
                if (!finished && !ready)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Center(
                      child: Text(
                        context.l10n.text(
                          phase == GamePhase.running ? '游戏中' : '已暂停',
                        ),
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                _LanguageMenu(onSelected: widget.onLocaleChanged),
              ],
              bottom: !finished && ready && c.output != null
                  ? PreferredSize(
                      preferredSize: const Size.fromHeight(48),
                      child: SizedBox(
                        height: 48,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Tooltip(
                              message: context.l10n.text('EMS 设备'),
                              child: TextButton.icon(
                                onPressed: c.loading ? null : _emsSettings,
                                style: TextButton.styleFrom(
                                  foregroundColor: c.output!.readyToOutput
                                      ? AppColors.green
                                      : AppColors.muted,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                ),
                                icon: Icon(
                                  c.output!.connected
                                      ? Icons.bluetooth_connected
                                      : Icons.bluetooth_disabled,
                                ),
                                label: Text(context.l10n.text('连接设备')),
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
            body: SafeArea(
              top: false,
              child: finished
                  ? _Results(c: c)
                  : LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 540),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (!ready) _GameScore(c: c),
                                ColoredBox(
                                  color: AppColors.camera,
                                  child: SizedBox(
                                    height:
                                        (constraints.maxHeight -
                                                (ready ? 240 : 220))
                                            .clamp(180.0, 720.0)
                                            .toDouble(),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Center(
                                          child: CameraStage(coordinator: c),
                                        ),
                                        if (c.camera.error == null)
                                          Positioned(
                                            top: 12,
                                            left: 16,
                                            right: 16,
                                            child: IgnorePointer(
                                              child: _TrackingBar(c: c),
                                            ),
                                          ),
                                        if (c.camera.error == null &&
                                            !c.loading &&
                                            !_counting)
                                          Positioned(
                                            left: 14,
                                            right: 14,
                                            top: 58,
                                            child: IgnorePointer(
                                              child: _GamePromptOverlay(c: c),
                                            ),
                                          ),
                                        if (c.engine.phase ==
                                                GamePhase.running &&
                                            c.engine.config.mode ==
                                                SafetyGameMode.combo &&
                                            c.modeSession.combo > 0)
                                          Positioned(
                                            left: 16,
                                            right: 16,
                                            bottom: 16,
                                            child: _ComboBurst(
                                              combo: c.modeSession.combo,
                                            ),
                                          ),
                                        if (ready && !_counting)
                                          Positioned(
                                            right: 12,
                                            bottom: 12,
                                            child: IconButton.filledTonal(
                                              tooltip: context.l10n.text(
                                                '切换摄像头',
                                              ),
                                              onPressed:
                                                  c.camera.canSwitch &&
                                                      !c.camera.initializing &&
                                                      !c.loading &&
                                                      !c.editing
                                                  ? c.switchCamera
                                                  : null,
                                              icon: const Icon(
                                                Icons.cameraswitch_outlined,
                                              ),
                                              style: IconButton.styleFrom(
                                                backgroundColor:
                                                    AppColors.panel,
                                                foregroundColor: AppColors.ink,
                                              ),
                                            ),
                                          ),
                                        if (_counting)
                                          Positioned.fill(
                                            child: _CountdownOverlay(
                                              remaining: _countdownRemaining!,
                                              onCancel: _cancelCountdown,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (ready && !_counting)
                                  _ModeSelector(
                                    c: c,
                                    onSettings: _gameModeSettings,
                                  ),
                                if (ready &&
                                    c.engine.config.mode.requiresRegion)
                                  _PreparationBar(c: c, enabled: !_counting),
                                if (ready)
                                  _SetupSummary(
                                    config: c.engine.config,
                                    onTap: c.loading || _counting
                                        ? null
                                        : _settings,
                                    onDuration: c.loading || _counting
                                        ? null
                                        : (duration) => c.updateConfig(
                                            c.engine.config.copyWith(
                                              duration: duration,
                                            ),
                                          ),
                                  )
                                else
                                  _SessionStatus(c: c),
                                const SizedBox(height: 12),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
            bottomNavigationBar: finished
                ? null
                : SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: ready
                          ? FilledButton.icon(
                              key: const ValueKey('start_game'),
                              onPressed: c.canStart && !_counting
                                  ? _startCountdown
                                  : null,
                              icon: const Icon(Icons.play_arrow),
                              label: Text(
                                context.l10n.text(
                                  _counting
                                      ? '准备中…'
                                      : c.output == null
                                      ? '开始游戏'
                                      : !c.output!.connected
                                      ? c.outputDeviceType ==
                                                OutputDeviceType.dglabCoyote
                                            ? '连接郊狼'
                                            : '连接 EMS 设备'
                                      : !c.output!.readyToOutput
                                      ? '设置强度'
                                      : '开始游戏',
                                ),
                              ),
                            )
                          : Row(
                              children: [
                                Expanded(
                                  flex: 2,
                                  child: FilledButton.icon(
                                    key: const ValueKey('pause_resume'),
                                    onPressed: phase == GamePhase.running
                                        ? c.pause
                                        : c.canResume
                                        ? c.resume
                                        : null,
                                    icon: Icon(
                                      phase == GamePhase.running
                                          ? Icons.pause
                                          : Icons.play_arrow,
                                    ),
                                    label: Text(
                                      context.l10n.text(
                                        phase == GamePhase.running
                                            ? '暂停'
                                            : '继续游戏',
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                if (c.output != null) ...[
                                  IconButton.filled(
                                    key: const ValueKey('emergency_stop'),
                                    tooltip: '立即停止全部设备输出',
                                    onPressed: c.emergencyStop,
                                    style: IconButton.styleFrom(
                                      backgroundColor: AppColors.alert,
                                    ),
                                    icon: const Icon(
                                      Icons.stop_circle_outlined,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                ],
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: c.finish,
                                    icon: const Icon(Icons.stop_outlined),
                                    label: Text(context.l10n.text('结束')),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
          ),
          if (_eventAlertVisible)
            const Positioned.fill(
              child: IgnorePointer(
                ignoring: true,
                child: CustomPaint(
                  key: ValueKey('event_alert_glow'),
                  painter: _EventAlertGlowPainter(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EventAlertGlowPainter extends CustomPainter {
  const _EventAlertGlowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    // 用多层模糊边框制造四周红光，不遮挡摄像头画面和底部操作按钮。
    final rect = Offset.zero & size;
    for (final layer in const [
      (width: 34.0, alpha: .08, blur: 22.0),
      (width: 20.0, alpha: .13, blur: 12.0),
      (width: 8.0, alpha: .28, blur: 4.0),
    ]) {
      canvas.drawRect(
        rect,
        Paint()
          ..color = const Color(0xFFFF2638).withValues(alpha: layer.alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = layer.width
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, layer.blur),
      );
    }
    canvas.drawRect(
      rect.deflate(2),
      Paint()
        ..color = const Color(0xFFFF5260).withValues(alpha: .45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _EventAlertGlowPainter oldDelegate) => false;
}

class _ComboBurst extends StatelessWidget {
  const _ComboBurst({required this.combo});
  final int combo;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: animation, child: child),
      ),
      child: Center(
        key: ValueKey(combo),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.yellow.withValues(alpha: .92),
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 12)],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'COMBO x$combo',
              style: const TextStyle(
                color: AppColors.camera,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _PreparationBar extends StatelessWidget {
  const _PreparationBar({required this.c, this.enabled = true});
  final GameCoordinator c;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
    child: Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<RegionMode>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: RegionMode.freehand,
                  tooltip: context.l10n.text('自由圈画'),
                  icon: const Icon(Icons.gesture),
                  label: Text(context.l10n.text('自由圈画')),
                ),
                ButtonSegment(
                  value: RegionMode.rectangle,
                  tooltip: context.l10n.text('矩形画区'),
                  icon: const Icon(Icons.crop_square),
                  label: Text(context.l10n.text('矩形画区')),
                ),
              ],
              selected: {c.drawingMode},
              onSelectionChanged: !enabled || c.editing
                  ? null
                  : (selection) => c.setDrawingMode(selection.single),
              style: const ButtonStyle(
                minimumSize: WidgetStatePropertyAll(Size(64, 44)),
                visualDensity: VisualDensity.standard,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: context.l10n.text('重画区域'),
          onPressed: !enabled || c.region == null || c.editing
              ? null
              : c.clearRegion,
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    ),
  );
}

class _CountdownOverlay extends StatelessWidget {
  const _CountdownOverlay({required this.remaining, required this.onCancel});
  final int remaining;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black54,
    child: Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$remaining',
              key: const ValueKey('start_countdown'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 64,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.text('请进入监测区域'),
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const ValueKey('cancel_countdown'),
              onPressed: onCancel,
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
              child: Text(context.l10n.text('取消')),
            ),
          ],
        ),
      ),
    ),
  );
}

class _GameScore extends StatelessWidget {
  const _GameScore({required this.c});
  final GameCoordinator c;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.text('剩余时间'),
                style: const TextStyle(fontSize: 12, color: AppColors.muted),
              ),
              Text(
                formatDuration(c.engine.remaining, roundUp: true),
                style: const TextStyle(
                  fontSize: 36,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
        if (c.modeSession.hasScore) ...[
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                context.l10n.text(
                  c.engine.config.mode == SafetyGameMode.combo
                      ? '分数 / 连击'
                      : '分数',
                ),
                style: const TextStyle(fontSize: 12, color: AppColors.muted),
              ),
              Text(
                c.engine.config.mode == SafetyGameMode.combo
                    ? '${c.modeSession.score} / x${c.modeSession.combo}'
                    : '${c.modeSession.score}',
                style: const TextStyle(
                  fontSize: 22,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(width: 16),
        ],
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              context.l10n.text('模拟触发'),
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
            Text(
              '${c.engine.events.length}',
              style: const TextStyle(
                fontSize: 30,
                height: 1.3,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _TrackingBar extends StatelessWidget {
  const _TrackingBar({required this.c});
  final GameCoordinator c;

  @override
  Widget build(BuildContext context) {
    final status = c.engine.tracking;
    final color = switch (status) {
      TrackingStatus.inside => AppColors.green,
      TrackingStatus.outside ||
      TrackingStatus.absent ||
      TrackingStatus.incomplete => AppColors.alert,
      _ => AppColors.muted,
    };
    final requiresRegion = c.engine.config.mode.requiresRegion;
    final label = requiresRegion && c.region == null
        ? '区域未设置'
        : c.editing
        ? '画区中'
        : c.engine.phase == GamePhase.running
        ? c.modeSession.prompt(c.engine.elapsed)
        : switch (status) {
            TrackingStatus.waiting => '等待人体识别',
            TrackingStatus.inside => '全身在区域内',
            TrackingStatus.outside => '关节越界',
            TrackingStatus.absent => '画面中无人',
            TrackingStatus.incomplete => '跟踪不完整',
          };
    return Align(
      alignment: Alignment.topLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.paper.withValues(alpha: .92),
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              status == TrackingStatus.inside
                  ? Icons.check_circle_outline
                  : Icons.adjust,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                context.l10n.text(label),
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GamePromptOverlay extends StatelessWidget {
  const _GamePromptOverlay({required this.c});

  final GameCoordinator c;

  @override
  Widget build(BuildContext context) {
    final prompt = context.l10n.text(c.modeSession.prompt(c.engine.elapsed));
    final status = switch (c.engine.tracking) {
      TrackingStatus.absent => '画面中无人',
      TrackingStatus.incomplete => '跟踪不完整',
      TrackingStatus.outside => '请立即修正动作',
      TrackingStatus.waiting => '等待人体识别',
      TrackingStatus.inside => '',
    };
    final alert =
        status.isNotEmpty &&
        c.engine.phase == GamePhase.running &&
        c.engine.tracking != TrackingStatus.waiting;
    return Semantics(
      liveRegion: true,
      label: [prompt, if (alert) context.l10n.text(status)].join('。'),
      child: Container(
        key: const ValueKey('large_game_prompt'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .72),
          border: Border.all(
            color: alert ? AppColors.alert : AppColors.yellow,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(6),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              prompt,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                height: 1.08,
                fontWeight: FontWeight.w900,
                shadows: [Shadow(color: Colors.black, blurRadius: 4)],
              ),
            ),
            if (alert) ...[
              const SizedBox(height: 5),
              Text(
                context.l10n.text(status),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.alert,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.c, required this.onSettings});
  final GameCoordinator c;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<SafetyGameMode>(
            key: const ValueKey('game_mode_selector'),
            initialValue: c.engine.config.mode,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: context.l10n.text('游戏模式'),
              prefixIcon: const Icon(Icons.sports_esports_outlined),
            ),
            items: [
              for (final mode in SafetyGameMode.values)
                DropdownMenuItem(
                  value: mode,
                  child: Text(
                    context.l10n.text(mode.label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: c.loading || c.editing
                ? null
                : (mode) {
                    if (mode != null) c.updateGameMode(mode);
                  },
          ),
        ),
        if (c.engine.config.mode == SafetyGameMode.redLightGreenLight ||
            c.engine.config.mode == SafetyGameMode.customPose) ...[
          const SizedBox(width: 8),
          IconButton.filledTonal(
            key: const ValueKey('game_mode_settings'),
            tooltip: context.l10n.text('模式设置'),
            onPressed: onSettings,
            icon: const Icon(Icons.tune),
          ),
        ],
      ],
    ),
  );
}

class _RedLightSettingsSheet extends StatefulWidget {
  const _RedLightSettingsSheet({required this.settings});
  final RedLightSettings settings;

  @override
  State<_RedLightSettingsSheet> createState() => _RedLightSettingsSheetState();
}

class _RedLightSettingsSheetState extends State<_RedLightSettingsSheet> {
  late int _moveSeconds = widget.settings.moveSeconds;
  late int _freezeSeconds = widget.settings.freezeSeconds;
  late bool _randomized = widget.settings.randomized;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(
      24,
      24,
      24,
      MediaQuery.viewInsetsOf(context).bottom + 24,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                context.l10n.text('木头人设置'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: context.l10n.text('关闭设置'),
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SecondsSlider(
          key: const ValueKey('red_light_move_seconds'),
          label: context.l10n.text('音乐可移动时间'),
          seconds: _moveSeconds,
          onChanged: (value) => setState(() => _moveSeconds = value),
        ),
        const SizedBox(height: 12),
        _SecondsSlider(
          key: const ValueKey('red_light_freeze_seconds'),
          label: context.l10n.text('静止时间'),
          seconds: _freezeSeconds,
          onChanged: (value) => setState(() => _freezeSeconds = value),
        ),
        SwitchListTile(
          key: const ValueKey('red_light_randomized'),
          contentPadding: EdgeInsets.zero,
          value: _randomized,
          onChanged: (value) => setState(() => _randomized = value),
          title: Text(context.l10n.text('每轮随机时间')),
          subtitle: Text(context.l10n.text('每轮在 1 秒到设置秒数之间随机')),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('save_red_light_settings'),
          onPressed: () => Navigator.pop(
            context,
            RedLightSettings(
              moveSeconds: _moveSeconds,
              freezeSeconds: _freezeSeconds,
              randomized: _randomized,
            ),
          ),
          icon: const Icon(Icons.check),
          label: Text(context.l10n.text('保存')),
        ),
      ],
    ),
  );
}

class _SecondsSlider extends StatelessWidget {
  const _SecondsSlider({
    super.key,
    required this.label,
    required this.seconds,
    required this.onChanged,
  });
  final String label;
  final int seconds;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            context.l10n.text('{value} 秒', {'value': seconds}),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
      Slider(
        value: seconds.toDouble(),
        min: 1,
        max: 60,
        divisions: 59,
        label: '$seconds s',
        onChanged: (value) => onChanged(value.round()),
      ),
    ],
  );
}

class _CustomPoseEditor extends StatefulWidget {
  const _CustomPoseEditor({required this.settings, required this.coordinator});
  final CustomPoseSettings settings;
  final GameCoordinator coordinator;

  @override
  State<_CustomPoseEditor> createState() => _CustomPoseEditorState();
}

class _CustomPoseEditorState extends State<_CustomPoseEditor> {
  late CustomPoseTemplate _template = widget.settings.template;
  late int _graceSeconds = widget.settings.mismatchGrace.inSeconds;
  late bool _randomEnabled = widget.settings.randomEnabled;
  late CustomPoseRandomMode _randomMode = widget.settings.randomMode;
  late bool _randomTimeRange =
      widget.settings.randomMinSeconds != widget.settings.randomMaxSeconds;
  late int _randomMinSeconds = widget.settings.randomMinSeconds;
  late int _randomMaxSeconds = widget.settings.randomMaxSeconds;
  final Stopwatch _previewClock = Stopwatch()..start();
  Duration? _mismatchStarted;
  Joint? _dragging;

  GameCoordinator get c => widget.coordinator;

  @override
  void initState() {
    super.initState();
    c.addListener(_previewChanged);
    _syncMismatchTimer();
  }

  @override
  void dispose() {
    c.removeListener(_previewChanged);
    super.dispose();
  }

  void _previewChanged() {
    if (!mounted) return;
    _syncMismatchTimer();
    setState(() {});
  }

  void _syncMismatchTimer() {
    final sample = c.sample;
    if (sample == null || customPoseMatches(sample, _template)) {
      _mismatchStarted = null;
    } else {
      _mismatchStarted ??= _previewClock.elapsed;
    }
  }

  int get _remainingSeconds {
    final started = _mismatchStarted;
    if (started == null) return _graceSeconds;
    final remaining =
        (_graceSeconds * 1000 -
                (_previewClock.elapsed - started).inMilliseconds)
            .clamp(0, _graceSeconds * 1000);
    return (remaining + 999) ~/ 1000;
  }

  void _startDrag(Offset local, PreviewTransform transform) {
    Joint? nearest;
    var distance = double.infinity;
    for (final joint in customPoseJoints) {
      final point = transform.toViewport(_template.points[joint]!);
      final current = (point - local).distance;
      if (current < distance) {
        nearest = joint;
        distance = current;
      }
    }
    if (distance <= 36) setState(() => _dragging = nearest);
  }

  void _drag(Offset local, PreviewTransform transform) {
    final joint = _dragging;
    if (joint == null || transform.viewport.isEmpty) return;
    setState(() {
      _template = _template.move(joint, transform.fromViewport(local));
      _syncMismatchTimer();
    });
  }

  String _previewStatus(BuildContext context) {
    final sample = c.sample;
    if (sample == null) return context.l10n.text('等待人体识别');
    if (!sample.personDetected) return context.l10n.text('请进入画面');
    final complete = customPoseJoints.every(
      (joint) => sample.landmarks[joint]?.isReliable ?? false,
    );
    if (customPoseMatches(sample, _template)) {
      return context.l10n.text('姿势已对齐');
    }
    if (!complete) return context.l10n.text('身体识别不完整');
    return context.l10n.text('调整姿势 · {seconds} 秒后触发', {
      'seconds': _remainingSeconds,
    });
  }

  void _setRandomMin(int value) {
    final min = value.clamp(1, _randomTimeRange ? _randomMaxSeconds : 300);
    setState(() {
      _randomMinSeconds = min;
      if (!_randomTimeRange) _randomMaxSeconds = min;
    });
  }

  void _setRandomMax(int value) {
    setState(() {
      _randomMaxSeconds = value.clamp(_randomMinSeconds, 300);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.l10n.text('绘制目标姿势')),
      actions: [
        IconButton(
          key: const ValueKey('reset_custom_pose'),
          tooltip: context.l10n.text('恢复默认姿势'),
          onPressed: () => setState(() {
            _template = CustomPoseTemplate.standard;
            _syncMismatchTimer();
          }),
          icon: const Icon(Icons.restart_alt),
        ),
      ],
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.text('拖动头、肩、肘、腕、髋、膝和脚踝关节点'),
              style: const TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                _PoseLegend(
                  color: AppColors.yellow,
                  label: context.l10n.text('目标姿势'),
                ),
                _PoseLegend(
                  color: AppColors.aligned,
                  label: context.l10n.text('已对齐'),
                ),
                _PoseLegend(
                  color: AppColors.alert,
                  label: context.l10n.text('需调整'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AspectRatio(
              aspectRatio: 3 / 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.camera,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final camera = c.camera;
                    final transform = PreviewTransform(
                      imageSize: camera.imageSize,
                      viewport: constraints.biggest,
                      mirrored: camera.mirrored,
                    );
                    final controller = camera.previewController;
                    final sample = c.sample;
                    final matches = sample == null
                        ? const <Joint, bool>{}
                        : customPoseJointMatches(sample, _template);
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          const ColoredBox(color: AppColors.camera),
                          if (controller != null &&
                              controller.value.isInitialized)
                            FittedBox(
                              fit: BoxFit.cover,
                              child: SizedBox(
                                width: camera.imageSize.width,
                                height: camera.imageSize.height,
                                child: CameraPreview(controller),
                              ),
                            ),
                          RawGestureDetector(
                            gestures: {
                              EagerGestureRecognizer:
                                  GestureRecognizerFactoryWithHandlers<
                                    EagerGestureRecognizer
                                  >(EagerGestureRecognizer.new, (_) {}),
                            },
                            child: Listener(
                              key: const ValueKey('custom_pose_canvas'),
                              behavior: HitTestBehavior.opaque,
                              onPointerDown: (details) =>
                                  _startDrag(details.localPosition, transform),
                              onPointerMove: (details) =>
                                  _drag(details.localPosition, transform),
                              onPointerUp: (_) =>
                                  setState(() => _dragging = null),
                              onPointerCancel: (_) =>
                                  setState(() => _dragging = null),
                              child: CustomPaint(
                                painter: _CustomPoseEditorPainter(
                                  transform: transform,
                                  template: _template,
                                  sample: sample,
                                  matches: matches,
                                  selected: _dragging,
                                ),
                              ),
                            ),
                          ),
                          if (camera.initializing || c.loading)
                            const Center(
                              child: CircularProgressIndicator(
                                color: AppColors.yellow,
                              ),
                            ),
                          if (camera.error != null)
                            IgnorePointer(
                              child: Center(
                                child: Container(
                                  margin: const EdgeInsets.all(24),
                                  padding: const EdgeInsets.all(12),
                                  color: AppColors.panel.withValues(alpha: .9),
                                  child: Text(
                                    context.l10n.message(camera.error!),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            left: 10,
                            right: 10,
                            bottom: 10,
                            child: IgnorePointer(
                              child: Container(
                                key: const ValueKey('custom_pose_live_status'),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.paper.withValues(alpha: .84),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  _previewStatus(context),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.shield_outlined, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    context.l10n.text('姿势预览不会触发设备输出'),
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              context.l10n.text('姿势不匹配超过此时间才触发'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Slider(
              key: const ValueKey('custom_pose_grace'),
              value: _graceSeconds.toDouble(),
              min: 1,
              max: 30,
              divisions: 29,
              label: '$_graceSeconds s',
              onChanged: (value) =>
                  setState(() => _graceSeconds = value.round()),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                context.l10n.text('{value} 秒', {'value': _graceSeconds}),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 24),
            SwitchListTile.adaptive(
              key: const ValueKey('custom_pose_random_enabled'),
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.text('随机变化姿势')),
              subtitle: Text(context.l10n.text('打开后，游戏中会按设定时间切换目标姿势')),
              value: _randomEnabled,
              onChanged: (value) => setState(() => _randomEnabled = value),
            ),
            if (_randomEnabled) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<CustomPoseRandomMode>(
                key: const ValueKey('custom_pose_random_mode'),
                initialValue: _randomMode,
                decoration: InputDecoration(
                  labelText: context.l10n.text('随机姿势类型'),
                ),
                items: [
                  for (final mode in CustomPoseRandomMode.values)
                    DropdownMenuItem(
                      value: mode,
                      child: Text(context.l10n.text(mode.label)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _randomMode = value);
                },
              ),
              const SizedBox(height: 14),
              SegmentedButton<bool>(
                key: const ValueKey('custom_pose_random_time_mode'),
                segments: [
                  ButtonSegment(
                    value: false,
                    label: Text(context.l10n.text('固定时间')),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text(context.l10n.text('随机范围')),
                  ),
                ],
                selected: {_randomTimeRange},
                onSelectionChanged: (values) {
                  final range = values.first;
                  setState(() {
                    _randomTimeRange = range;
                    if (!range) _randomMaxSeconds = _randomMinSeconds;
                  });
                },
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.text(
                  _randomTimeRange ? '每次变化间隔（1 至 300 秒）' : '姿势变化间隔（1 至 300 秒）',
                ),
                style: const TextStyle(color: AppColors.muted),
              ),
              Slider(
                key: const ValueKey('custom_pose_random_min'),
                value: _randomMinSeconds.toDouble(),
                min: 1,
                max: _randomTimeRange ? _randomMaxSeconds.toDouble() : 300,
                label: '$_randomMinSeconds s',
                onChanged: (value) => _setRandomMin(value.round()),
              ),
              if (_randomTimeRange)
                Slider(
                  key: const ValueKey('custom_pose_random_max'),
                  value: _randomMaxSeconds.toDouble(),
                  min: _randomMinSeconds.toDouble(),
                  max: 300,
                  label: '$_randomMaxSeconds s',
                  onChanged: (value) => _setRandomMax(value.round()),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  context.l10n.text(
                    _randomTimeRange ? '{min} 至 {max} 秒' : '{value} 秒',
                    _randomTimeRange
                        ? {'min': _randomMinSeconds, 'max': _randomMaxSeconds}
                        : {'value': _randomMinSeconds},
                  ),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('save_custom_pose'),
              onPressed: () => Navigator.pop(
                context,
                CustomPoseSettings(
                  template: _template,
                  mismatchGrace: Duration(seconds: _graceSeconds),
                  randomEnabled: _randomEnabled,
                  randomMode: _randomMode,
                  randomMinSeconds: _randomMinSeconds,
                  randomMaxSeconds: _randomTimeRange
                      ? _randomMaxSeconds
                      : _randomMinSeconds,
                ),
              ),
              icon: const Icon(Icons.check),
              label: Text(context.l10n.text('保存目标姿势')),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PoseLegend extends StatelessWidget {
  const _PoseLegend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(fontSize: 12)),
    ],
  );
}

class _CustomPoseEditorPainter extends CustomPainter {
  const _CustomPoseEditorPainter({
    required this.transform,
    required this.template,
    required this.sample,
    required this.matches,
    this.selected,
  });
  final PreviewTransform transform;
  final CustomPoseTemplate template;
  final PoseSample? sample;
  final Map<Joint, bool> matches;
  final Joint? selected;

  Offset point(Joint joint) => transform.toViewport(template.points[joint]!);

  @override
  void paint(Canvas canvas, Size size) {
    final targetPaint = Paint()
      ..color = AppColors.yellow.withValues(alpha: .82)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    for (final edge in customPoseEdges) {
      canvas.drawLine(point(edge.$1), point(edge.$2), targetPaint);
    }

    final current = sample;
    if (current != null && current.personDetected) {
      for (final edge in customPoseEdges) {
        final a = current.landmarks[edge.$1];
        final b = current.landmarks[edge.$2];
        if (a == null || b == null || !a.isReliable || !b.isReliable) continue;
        final aligned =
            (matches[edge.$1] ?? false) && (matches[edge.$2] ?? false);
        canvas.drawLine(
          transform.toViewport(a.position),
          transform.toViewport(b.position),
          Paint()
            ..color = aligned ? AppColors.aligned : AppColors.alert
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round,
        );
      }
      for (final joint in customPoseJoints) {
        final actual = current.landmarks[joint];
        if (actual == null || !actual.isReliable) continue;
        canvas.drawCircle(
          transform.toViewport(actual.position),
          6,
          Paint()
            ..color = matches[joint] ?? false
                ? AppColors.aligned
                : AppColors.alert,
        );
      }
    }

    for (final joint in customPoseJoints) {
      final center = point(joint);
      final radius = joint == Joint.nose ? 22.0 : 10.0;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = joint == selected
              ? AppColors.ink
              : AppColors.paper.withValues(alpha: .66)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = joint == selected
              ? AppColors.ink
              : matches[joint] ?? false
              ? AppColors.aligned
              : AppColors.yellow
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CustomPoseEditorPainter oldDelegate) =>
      oldDelegate.template != template ||
      oldDelegate.sample != sample ||
      oldDelegate.matches != matches ||
      oldDelegate.transform != transform ||
      oldDelegate.selected != selected;
}

class _SetupSummary extends StatelessWidget {
  const _SetupSummary({
    required this.config,
    required this.onTap,
    required this.onDuration,
  });
  final GameConfig config;
  final VoidCallback? onTap;
  final ValueChanged<Duration>? onDuration;

  @override
  Widget build(BuildContext context) {
    final minutes = config.duration.inMinutes;
    final preset =
        [3, 5, 10].contains(minutes) && config.duration.inSeconds % 60 == 0;
    final selectedDuration = preset ? minutes : 0;
    final durationSegments = <ButtonSegment<int>>[
      ButtonSegment(
        value: 3,
        label: Text(context.l10n.text('{value} 分钟', {'value': 3})),
      ),
      ButtonSegment(
        value: 5,
        label: Text(context.l10n.text('{value} 分钟', {'value': 5})),
      ),
      ButtonSegment(
        value: 10,
        label: Text(context.l10n.text('{value} 分钟', {'value': 10})),
      ),
      ButtonSegment(value: 0, label: Text(context.l10n.text('自定'))),
    ];

    void updateDuration(Set<int> selection) {
      final value = selection.isEmpty ? selectedDuration : selection.single;
      if (value == 0) {
        onTap?.call();
      } else {
        onDuration?.call(Duration(minutes: value));
      }
    }

    Widget durationSelector(List<ButtonSegment<int>> segments) {
      final values = segments.map((segment) => segment.value).toSet();
      return SegmentedButton<int>(
        showSelectedIcon: false,
        segments: segments,
        selected: values.contains(selectedDuration) ? {selectedDuration} : {},
        onSelectionChanged: onTap == null ? null : updateDuration,
        // 自定已选中时仍可再次打开编辑。
        emptySelectionAllowed: true,
        style: const ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(0, 44)),
          padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  context.l10n.text('游戏时长'),
                  style: const TextStyle(color: AppColors.muted),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                config.duration.inSeconds % 60 == 0
                    ? context.l10n.text('{value} 分钟', {'value': minutes})
                    : formatDuration(config.duration),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            key: const ValueKey('duration_presets'),
            builder: (context, constraints) {
              if (constraints.maxWidth >= 360) {
                return durationSelector(durationSegments);
              }
              // 小屏将四个选项拆成两行，避免长语言被压缩或截断。
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  durationSelector(durationSegments.take(2).toList()),
                  const SizedBox(height: 8),
                  durationSelector(durationSegments.skip(2).toList()),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
      const SizedBox(height: 5),
      Text(
        value,
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    ],
  );
}

class _SessionStatus extends StatelessWidget {
  const _SessionStatus({required this.c});
  final GameCoordinator c;

  @override
  Widget build(BuildContext context) {
    final triggering = c.engine.triggering;
    final paused = c.engine.phase == GamePhase.paused;
    final label = paused
        ? switch (c.engine.pauseReason) {
            PauseReason.background => '返回前台，等待继续',
            PauseReason.cameraFault => '摄像头中断，游戏已暂停',
            PauseReason.outputFault => '触发失败，游戏已暂停',
            _ => '游戏已暂停',
          }
        : triggering
        ? '越界中，持续触发'
        : '状态正常';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text(
            context.l10n.text(c.modeSession.prompt(c.engine.elapsed)),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (c.engine.config.mode == SafetyGameMode.redLightGreenLight) ...[
            const SizedBox(height: 4),
            Text(
              context.l10n.text('本阶段剩余 {seconds} 秒', {
                'seconds': c.modeSession
                    .lightPhaseRemaining(c.engine.elapsed)
                    .inSeconds,
              }),
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ],
          if (c.engine.config.mode == SafetyGameMode.customPose) ...[
            const SizedBox(height: 4),
            Text(
              context.l10n.text('持续不匹配 {seconds} 秒后触发', {
                'seconds':
                    c.engine.config.customPoseSettings.mismatchGrace.inSeconds,
              }),
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.text(label),
                  style: TextStyle(
                    fontSize: 14,
                    color: triggering ? AppColors.alert : null,
                    fontWeight: triggering ? FontWeight.w600 : null,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.config});
  final GameConfig config;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _duration = TextEditingController(
    text: (widget.config.duration.inSeconds / 60).toString().replaceFirst(
      RegExp(r'\.0$'),
      '',
    ),
  );
  late final _countdown = TextEditingController(
    text: '${widget.config.startCountdown.inSeconds}',
  );

  @override
  void dispose() {
    _duration.dispose();
    _countdown.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      GameConfig(
        duration: Duration(
          seconds: (double.parse(_duration.text) * 60).round(),
        ),
        startCountdown: Duration(seconds: int.parse(_countdown.text)),
        mode: widget.config.mode,
        redLightSettings: widget.config.redLightSettings,
        customPoseSettings: widget.config.customPoseSettings,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(
      24,
      24,
      24,
      MediaQuery.viewInsetsOf(context).bottom + 24,
    ),
    child: Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                context.l10n.text('游戏设置'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              IconButton(
                tooltip: context.l10n.text('关闭设置'),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 24),
          TextFormField(
            controller: _duration,
            decoration: InputDecoration(
              labelText: context.l10n.text('游戏时长'),
              suffixText: context.l10n.text('分钟'),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            validator: (value) {
              final minutes = double.tryParse(value ?? '');
              return minutes == null ||
                      !minutes.isFinite ||
                      minutes < 1 / 60 ||
                      minutes > 1440
                  ? context.l10n.text('请输入 0.02 至 1440 分钟')
                  : null;
            },
          ),
          const SizedBox(height: 18),
          TextFormField(
            controller: _countdown,
            decoration: InputDecoration(
              labelText: context.l10n.text('开始前准备倒计时'),
              suffixText: context.l10n.text('秒'),
              helperText: context.l10n.text('0 表示不倒计时，点击后立即开始'),
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            validator: (value) {
              final seconds = int.tryParse(value ?? '');
              return seconds == null || seconds < 0 || seconds > 30
                  ? context.l10n.text('请输入 0 至 30 秒')
                  : null;
            },
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: Text(context.l10n.text('保存')),
          ),
        ],
      ),
    ),
  );
}

class _OutputSettingsSheet extends StatefulWidget {
  const _OutputSettingsSheet({required this.coordinator});

  final GameCoordinator coordinator;

  @override
  State<_OutputSettingsSheet> createState() => _OutputSettingsSheetState();
}

class _OutputSettingsSheetState extends State<_OutputSettingsSheet> {
  @override
  void initState() {
    super.initState();
    widget.coordinator.addListener(_changed);
  }

  @override
  void dispose() {
    widget.coordinator.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.coordinator;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .9,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '输出设备',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: context.l10n.text('关闭设备设置'),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<OutputDeviceType>(
                key: const ValueKey('output_device_type'),
                segments: const [
                  ButtonSegment(
                    value: OutputDeviceType.yokonex,
                    icon: Icon(Icons.bluetooth),
                    label: Text('Yokonex'),
                  ),
                  ButtonSegment(
                    value: OutputDeviceType.dglabCoyote,
                    icon: Icon(Icons.qr_code_2),
                    label: Text('DG-LAB Coyote'),
                  ),
                  ButtonSegment(
                    value: OutputDeviceType.simulation,
                    icon: Icon(Icons.science_outlined),
                    label: Text('模拟输出'),
                  ),
                ],
                selected: {c.outputDeviceType},
                onSelectionChanged: (selection) {
                  if (selection.isNotEmpty) {
                    unawaited(c.updateOutputDeviceType(selection.first));
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: switch (c.outputDeviceType) {
              OutputDeviceType.yokonex => _EmsSettingsSheet(
                device: c.ems!,
                onSave: c.updateEmsConfig,
                embedded: true,
              ),
              OutputDeviceType.dglabCoyote => _CoyoteSettingsSheet(
                coordinator: c,
              ),
              OutputDeviceType.simulation => _SimulationSettingsSheet(
                coordinator: c,
              ),
            },
          ),
        ],
      ),
    );
  }
}

class _EmsSettingsSheet extends StatefulWidget {
  const _EmsSettingsSheet({
    required this.device,
    required this.onSave,
    this.embedded = false,
  });

  final EmsDeviceController device;
  final ValueChanged<EmsConfig> onSave;
  final bool embedded;

  @override
  State<_EmsSettingsSheet> createState() => _EmsSettingsSheetState();
}

class _EmsSettingsSheetState extends State<_EmsSettingsSheet> {
  late EmsConfig _config = widget.device.config;
  late final _intensityA = TextEditingController(text: '${_config.intensityA}');
  late final _intensityB = TextEditingController(text: '${_config.intensityB}');
  late final _ramp = TextEditingController(
    text: '${_config.intensityRampPerSecond}',
  );

  @override
  void initState() {
    super.initState();
    widget.device.addListener(_changed);
  }

  @override
  void dispose() {
    widget.device.removeListener(_changed);
    _intensityA.dispose();
    _intensityB.dispose();
    _ramp.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String _phaseLabel(EmsConnectionPhase phase) => switch (phase) {
    EmsConnectionPhase.idle => '未连接',
    EmsConnectionPhase.scanning => '扫描中',
    EmsConnectionPhase.connecting => '连接中',
    EmsConnectionPhase.connected => '已连接',
    EmsConnectionPhase.error => '连接异常',
  };

  void _setIntensityA(int value) {
    final clamped = value.clamp(0, EmsConfig.appMaxIntensity);
    setState(() => _config = _config.copyWith(intensityA: clamped));
    if (_intensityA.text != '$clamped') _intensityA.text = '$clamped';
  }

  void _setIntensityB(int value) {
    final clamped = value.clamp(0, EmsConfig.appMaxIntensity);
    setState(() => _config = _config.copyWith(intensityB: clamped));
    if (_intensityB.text != '$clamped') _intensityB.text = '$clamped';
  }

  void _setRamp(int value) {
    final clamped = value.clamp(0, EmsConfig.maxIntensityRampPerSecond);
    setState(() => _config = _config.copyWith(intensityRampPerSecond: clamped));
    if (_ramp.text != '$clamped') _ramp.text = '$clamped';
  }

  Widget _intensityChannel({
    required String label,
    required String channelKey,
    required int value,
    required TextEditingController controller,
    required ValueChanged<int> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            '$value / ${EmsConfig.appMaxIntensity}',
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      Row(
        children: [
          Expanded(
            child: Slider(
              key: ValueKey('ems_intensity_$channelKey'),
              value: value.toDouble(),
              min: 0,
              max: EmsConfig.appMaxIntensity.toDouble(),
              divisions: EmsConfig.appMaxIntensity,
              label: '$value',
              onChanged: (newValue) => onChanged(newValue.round()),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 64,
            child: TextField(
              key: ValueKey('ems_intensity_${channelKey}_input'),
              controller: controller,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(isDense: true),
              onChanged: (text) {
                final parsed = int.tryParse(text);
                if (parsed != null) onChanged(parsed);
              },
            ),
          ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        20,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.embedded)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  context.l10n.text('EMS 设备'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                IconButton(
                  tooltip: context.l10n.text('关闭设备设置'),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            )
          else
            Text(
              context.l10n.text('EMS 设备'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          Row(
            children: [
              Text(
                context.l10n.text(_phaseLabel(device.phase)),
                style: TextStyle(
                  color: device.connected ? AppColors.green : AppColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (device.connected) ...[
                const SizedBox(width: 8),
                Text('·', style: TextStyle(color: AppColors.muted)),
                const SizedBox(width: 8),
                Text(
                  key: const ValueKey('ems_generation_label'),
                  context.l10n.text(
                    device.config.generation == EmsGeneration.first
                        ? '一代电击'
                        : '二代电击',
                  ),
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 18),
          DropdownButtonFormField<int>(
            key: const ValueKey('ems_waveform'),
            initialValue: _config.waveform,
            decoration: InputDecoration(labelText: context.l10n.text('波形曲线')),
            items: [
              for (final curve in emsWaveformCurves)
                DropdownMenuItem(
                  value: curve.id,
                  child: Text(context.l10n.text(curve.label)),
                ),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() => _config = _config.copyWith(waveform: value));
              }
            },
          ),
          const SizedBox(height: 16),
          _intensityChannel(
            label: context.l10n.text('A 通道强度'),
            channelKey: 'a',
            value: _config.intensityA,
            controller: _intensityA,
            onChanged: _setIntensityA,
          ),
          const SizedBox(height: 18),
          _intensityChannel(
            label: context.l10n.text('B 通道强度'),
            channelKey: 'b',
            value: _config.intensityB,
            controller: _intensityB,
            onChanged: _setIntensityB,
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(child: Text(context.l10n.text('越界强度递增'))),
              SizedBox(
                width: 64,
                child: TextField(
                  key: const ValueKey('ems_ramp_input'),
                  controller: _ramp,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(isDense: true),
                  onChanged: (text) {
                    final parsed = int.tryParse(text);
                    if (parsed != null) _setRamp(parsed);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Text(context.l10n.text('/ 秒')),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.text('越界后立即持续输出，强度每秒叠加上述数值；回到区域内立即停止并恢复到基础强度。'),
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 18),
          if (device.connected)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                device.connectedDevice?.name ?? context.l10n.text('EMS 设备'),
              ),
              subtitle: Text(
                device.batteryPercent == null
                    ? context.l10n.text('电量读取中')
                    : context.l10n.text('电量 {value}%', {
                        'value': device.batteryPercent,
                      }),
              ),
              trailing: OutlinedButton(
                onPressed: device.disconnect,
                child: Text(context.l10n.text('断开')),
              ),
            )
          else ...[
            OutlinedButton.icon(
              key: const ValueKey('ems_scan'),
              onPressed: device.phase == EmsConnectionPhase.scanning
                  ? null
                  : device.scan,
              icon: const Icon(Icons.search),
              label: Text(
                context.l10n.text(
                  device.phase == EmsConnectionPhase.scanning ? '扫描中' : '扫描设备',
                ),
              ),
            ),
            for (final peripheral in device.devices)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(peripheral.name),
                subtitle: Text('${peripheral.rssi} dBm'),
                trailing: TextButton(
                  onPressed: device.phase == EmsConnectionPhase.connecting
                      ? null
                      : () => device.connect(peripheral),
                  child: Text(context.l10n.text('连接')),
                ),
              ),
          ],
          if (device.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                context.l10n.message(device.error!),
                style: const TextStyle(color: AppColors.alert),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('ems_save'),
            onPressed: () {
              widget.onSave(_config);
              Navigator.pop(context);
            },
            icon: const Icon(Icons.check),
            label: Text(context.l10n.text('保存设备设置')),
          ),
        ],
      ),
    );
  }
}

class _CoyoteSettingsSheet extends StatefulWidget {
  const _CoyoteSettingsSheet({required this.coordinator});

  final GameCoordinator coordinator;

  @override
  State<_CoyoteSettingsSheet> createState() => _CoyoteSettingsSheetState();
}

class _CoyoteSettingsSheetState extends State<_CoyoteSettingsSheet> {
  late CoyoteConfig _config = widget.coordinator.coyote!.config;

  CoyoteDeviceController get device => widget.coordinator.coyote!;

  @override
  void initState() {
    super.initState();
    device.addListener(_changed);
  }

  @override
  void dispose() {
    device.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String _phaseLabel(CoyoteConnectionPhase phase) => switch (phase) {
    CoyoteConnectionPhase.idle => '未连接',
    CoyoteConnectionPhase.connecting => '正在连接服务',
    CoyoteConnectionPhase.waitingForScan => '等待扫码',
    CoyoteConnectionPhase.waitingForDevice => 'App 已连接，等待郊狼',
    CoyoteConnectionPhase.connected => '已连接',
    CoyoteConnectionPhase.disconnected => '已断开',
    CoyoteConnectionPhase.error => '错误',
  };

  Future<void> _test() async {
    widget.coordinator.updateCoyoteConfig(_config);
    try {
      await device.testOutput();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已发送低强度短脉冲测试')));
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Bad state: ', '')),
          ),
        );
      }
    }
  }

  Future<void> _connect() async {
    try {
      if (!_config.isValid) throw StateError('专用中转地址必须是有效的 ws:// 或 wss:// 地址');
      widget.coordinator.updateCoyoteConfig(_config);
      if (device.phase == CoyoteConnectionPhase.idle) {
        await device.connect();
      } else {
        await device.reconnect();
      }
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Bad state: ', '')),
        ),
      );
    }
  }

  Future<void> _openOnThisDevice() async {
    final pairingUrl = device.pairingUrl;
    if (pairingUrl == null) return;
    try {
      final opened = await launchUrl(
        Uri.parse(pairingUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw StateError('无法打开 DG-LAB App');
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Bad state: ', '')),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final connectedDevice = device.activeDevice;
    final pairingUrl = device.pairingUrl;
    final pairingSocket = device.pairingSocketUri;
    final isConnecting = device.phase == CoyoteConnectionPhase.connecting;
    final canConnect =
        !isConnecting &&
        device.phase != CoyoteConnectionPhase.waitingForScan &&
        device.phase != CoyoteConnectionPhase.waitingForDevice &&
        device.phase != CoyoteConnectionPhase.connected;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        8,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'DG-LAB Coyote 3.0',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                _phaseLabel(device.phase),
                key: const ValueKey('coyote_status'),
                style: TextStyle(
                  color: device.connected ? AppColors.green : AppColors.muted,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<CoyoteConnectionMode>(
            key: const ValueKey('coyote_connection_mode'),
            initialValue: _config.connectionMode,
            decoration: const InputDecoration(labelText: '连接方式'),
            items: const [
              DropdownMenuItem(
                value: CoyoteConnectionMode.privateRelay,
                child: Text('我的专用服务器（推荐）'),
              ),
              DropdownMenuItem(
                value: CoyoteConnectionMode.officialRelay,
                child: Text('官方网络服务'),
              ),
              DropdownMenuItem(
                value: CoyoteConnectionMode.localNetwork,
                child: Text('局域网直连（两台设备）'),
              ),
              DropdownMenuItem(
                value: CoyoteConnectionMode.loopback,
                child: Text('本机回环（同一台手机）'),
              ),
            ],
            onChanged: device.phase == CoyoteConnectionPhase.idle
                ? (value) {
                    if (value != null) {
                      setState(
                        () => _config = _config.copyWith(connectionMode: value),
                      );
                    }
                  }
                : null,
          ),
          const SizedBox(height: 6),
          Text(switch (_config.connectionMode) {
            CoyoteConnectionMode.privateRelay =>
              '通过已部署的专用 WSS 中转，不要求两台手机处于同一局域网。',
            CoyoteConnectionMode.officialRelay => '通过 DG-LAB 官方 V4 中继，需要互联网。',
            CoyoteConnectionMode.localNetwork =>
              '本应用内置 V4 服务；两台手机需连接同一 Wi-Fi 或热点，不经过官方中继。',
            CoyoteConnectionMode.loopback =>
              '本应用和 DG-LAB App 安装在同一台手机时使用；需要允许本应用在后台运行。',
          }, style: const TextStyle(color: AppColors.muted)),
          if (_config.connectionMode == CoyoteConnectionMode.privateRelay) ...[
            const SizedBox(height: 10),
            TextFormField(
              key: const ValueKey('coyote_private_relay_url'),
              initialValue: _config.privateRelayUrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '专用 V4 中转地址',
                helperText: '已预置你的服务器；服务器迁移时可在这里修改',
              ),
              onChanged: (value) =>
                  _config = _config.copyWith(privateRelayUrl: value.trim()),
            ),
          ],
          if (pairingUrl != null &&
              device.phase == CoyoteConnectionPhase.waitingForScan) ...[
            const SizedBox(height: 16),
            Center(
              child: ColoredBox(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: QrImageView(
                    key: const ValueKey('coyote_qr'),
                    data: pairingUrl,
                    size: 210,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '使用 DG-LAB 官方 App 扫描二维码',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted),
            ),
            if (pairingSocket != null) ...[
              const SizedBox(height: 4),
              Text(
                '${pairingSocket.scheme}://${pairingSocket.host}:${pairingSocket.port}${pairingSocket.path}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ],
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('coyote_open_app'),
              onPressed: _openOnThisDevice,
              icon: const Icon(Icons.open_in_new),
              label: const Text('在本机 DG-LAB App 中连接'),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('coyote_connect'),
                  onPressed: canConnect ? _connect : null,
                  icon: Icon(
                    device.phase == CoyoteConnectionPhase.idle
                        ? Icons.link
                        : Icons.refresh,
                  ),
                  label: Text(
                    device.phase == CoyoteConnectionPhase.idle
                        ? '连接郊狼'
                        : isConnecting
                        ? '连接中'
                        : '重新连接',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: device.phase == CoyoteConnectionPhase.idle
                    ? null
                    : device.disconnect,
                icon: const Icon(Icons.link_off),
                label: const Text('断开'),
              ),
            ],
          ),
          if (connectedDevice != null) ...[
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.electrical_services),
              title: Text(connectedDevice.name),
              subtitle: Text(
                'A ${connectedDevice.intensityA ?? 0} · '
                'B ${connectedDevice.intensityB ?? 0} · '
                '电量 ${connectedDevice.power?.toString() ?? '--'}%',
              ),
            ),
          ],
          if (device.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                device.error!,
                style: const TextStyle(color: AppColors.alert),
              ),
            ),
          const Divider(height: 32),
          const Text('输出通道', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          SegmentedButton<CoyoteChannel>(
            key: const ValueKey('coyote_channel'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: CoyoteChannel.a, label: Text('A')),
              ButtonSegment(value: CoyoteChannel.b, label: Text('B')),
              ButtonSegment(value: CoyoteChannel.both, label: Text('A+B')),
            ],
            selected: {_config.channel},
            onSelectionChanged: (selection) => setState(
              () => _config = _config.copyWith(channel: selection.first),
            ),
          ),
          SwitchListTile(
            key: const ValueKey('coyote_directional_mapping'),
            contentPadding: EdgeInsets.zero,
            value: _config.directionalMapping,
            onChanged: (value) => setState(
              () => _config = _config.copyWith(directionalMapping: value),
            ),
            title: const Text('按越界侧映射 A/B'),
            subtitle: const Text('身体左侧触发 A，右侧触发 B；无法判断时使用上方通道'),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<CoyoteWaveform>(
            key: const ValueKey('coyote_waveform'),
            initialValue: _config.waveform,
            decoration: const InputDecoration(labelText: '波形'),
            items: [
              for (final waveform in coyoteWaveforms)
                DropdownMenuItem(
                  value: waveform.id,
                  child: Text(waveform.label),
                ),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() => _config = _config.copyWith(waveform: value));
              }
            },
          ),
          const SizedBox(height: 18),
          _CoyoteSlider(
            label: '触发强度',
            valueLabel: '${_config.triggerIntensity}',
            value: _config.triggerIntensity.toDouble(),
            min: 0,
            max: CoyoteConfig.protocolMaxIntensity.toDouble(),
            divisions: CoyoteConfig.protocolMaxIntensity,
            onChanged: (value) => setState(
              () => _config = _config.copyWith(triggerIntensity: value.round()),
            ),
          ),
          _CoyoteSlider(
            label: '最大允许强度',
            valueLabel: '${_config.maxIntensity}',
            value: _config.maxIntensity.toDouble(),
            min: 1,
            max: CoyoteConfig.protocolMaxIntensity.toDouble(),
            divisions: CoyoteConfig.protocolMaxIntensity - 1,
            onChanged: (value) => setState(
              () => _config = _config.copyWith(maxIntensity: value.round()),
            ),
          ),
          const SizedBox(height: 8),
          const Text('持续触发方式', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          SegmentedButton<CoyoteOutputDurationMode>(
            key: const ValueKey('coyote_output_duration_mode'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: CoyoteOutputDurationMode.untilRecovery,
                label: Text('无限制（直到恢复）'),
              ),
              ButtonSegment(
                value: CoyoteOutputDurationMode.maximum,
                label: Text('设置最长时间'),
              ),
            ],
            selected: {_config.outputDurationMode},
            onSelectionChanged: (selection) => setState(
              () => _config = _config.copyWith(
                outputDurationMode: selection.first,
              ),
            ),
          ),
          if (_config.outputDurationMode == CoyoteOutputDurationMode.maximum)
            _CoyoteSlider(
              label: '最长输出时间',
              valueLabel: '${_config.duration.inSeconds.clamp(1, 300)} 秒',
              value: _config.duration.inSeconds
                  .toDouble()
                  .clamp(1, 300)
                  .toDouble(),
              min: 1,
              max: 300,
              divisions: 299,
              onChanged: (value) => setState(
                () => _config = _config.copyWith(
                  duration: Duration(seconds: value.round()),
                ),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.only(top: 10, bottom: 8),
              child: Text(
                '越界或姿势错误期间持续输出；恢复正确姿势、急停、断线或结束游戏时立即停止。',
                style: TextStyle(color: AppColors.muted),
              ),
            ),
          _CoyoteSlider(
            label: 'Cooldown',
            valueLabel:
                '${(_config.cooldown.inMilliseconds / 1000).toStringAsFixed(1)} s',
            value: _config.cooldown.inMilliseconds
                .toDouble()
                .clamp(500, 10000)
                .toDouble(),
            min: 500,
            max: 10000,
            divisions: 19,
            onChanged: (value) => setState(
              () => _config = _config.copyWith(
                cooldown: Duration(milliseconds: value.round()),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('coyote_test'),
                  onPressed: device.connected ? _test : null,
                  icon: const Icon(Icons.bolt),
                  label: const Text('低强度测试'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('coyote_emergency_stop'),
                  onPressed: widget.coordinator.emergencyStop,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.alert,
                  ),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('立即停止'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('coyote_save'),
            onPressed: () {
              widget.coordinator.updateCoyoteConfig(_config);
              Navigator.pop(context);
            },
            icon: const Icon(Icons.check),
            label: const Text('保存设备设置'),
          ),
        ],
      ),
    );
  }
}

class _SimulationSettingsSheet extends StatefulWidget {
  const _SimulationSettingsSheet({required this.coordinator});

  final GameCoordinator coordinator;

  @override
  State<_SimulationSettingsSheet> createState() =>
      _SimulationSettingsSheetState();
}

class _SimulationSettingsSheetState extends State<_SimulationSettingsSheet> {
  late CoyoteConfig _config = widget.coordinator.simulation!.config;

  SimulationOutputController get device => widget.coordinator.simulation!;

  @override
  void initState() {
    super.initState();
    device.addListener(_changed);
  }

  @override
  void dispose() {
    device.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _test() async {
    widget.coordinator.updateSimulationConfig(_config);
    try {
      await device.testOutput();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已记录一次低强度模拟脉冲（不会发送到硬件）')));
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Bad state: ', '')),
          ),
        );
      }
    }
  }

  String _channels(List<int> channels) =>
      channels.map((value) => value == 0 ? 'A' : 'B').join('+');

  @override
  Widget build(BuildContext context) {
    final active = device.activePulse;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        8,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.science_outlined),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '模拟输出',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '可用 · 离线',
                style: TextStyle(
                  color: AppColors.green,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '模拟模式不会连接 Yokonex、DG-LAB 或任何外部设备。所有触发只会显示在本页面，适合在没有实体设备时验证游戏规则和输出链路。',
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (active != null)
            Card(
              key: const ValueKey('simulation_active'),
              color: Theme.of(context).colorScheme.primaryContainer,
              child: ListTile(
                leading: const Icon(Icons.bolt),
                title: Text(
                  '${active.isTest ? '测试' : 'Safety 事件'} · ${_channels(active.channels)} · ${active.intensity}',
                ),
                subtitle: Text(
                  active.untilRecovery
                      ? '${active.waveform.name} · 持续到姿势恢复'
                      : '${active.waveform.name} · 剩余 ${((device.activeRemaining ?? Duration.zero).inMilliseconds / 1000).toStringAsFixed(1)} s',
                ),
              ),
            )
          else
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.pause_circle_outline),
              title: Text('当前空闲'),
              subtitle: Text('没有正在执行的模拟输出'),
            ),
          if (device.history.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('最近模拟记录', style: TextStyle(fontWeight: FontWeight.w700)),
            for (final pulse in device.history.reversed.take(5))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  pulse.stopped ? Icons.stop_circle_outlined : Icons.bolt,
                  color: pulse.stopped ? AppColors.muted : AppColors.green,
                ),
                title: Text(
                  '${pulse.isTest ? '测试' : 'Safety 事件'} · ${_channels(pulse.channels)} · ${pulse.intensity}',
                ),
                subtitle: Text(
                  '${pulse.waveform.name} · ${pulse.stopped ? '已停止' : '已完成'}',
                ),
              ),
          ],
          const Divider(height: 28),
          const Text('输出通道', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          SegmentedButton<CoyoteChannel>(
            key: const ValueKey('simulation_channel'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: CoyoteChannel.a, label: Text('A')),
              ButtonSegment(value: CoyoteChannel.b, label: Text('B')),
              ButtonSegment(value: CoyoteChannel.both, label: Text('A+B')),
            ],
            selected: {_config.channel},
            onSelectionChanged: (selection) => setState(
              () => _config = _config.copyWith(channel: selection.first),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<CoyoteWaveform>(
            key: const ValueKey('simulation_waveform'),
            initialValue: _config.waveform,
            decoration: const InputDecoration(labelText: '波形（仅用于模拟记录）'),
            items: [
              for (final waveform in coyoteWaveforms)
                DropdownMenuItem(
                  value: waveform.id,
                  child: Text(waveform.label),
                ),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() => _config = _config.copyWith(waveform: value));
              }
            },
          ),
          const SizedBox(height: 18),
          _CoyoteSlider(
            label: '触发强度（模拟）',
            valueLabel: '${_config.triggerIntensity}',
            value: _config.triggerIntensity.toDouble(),
            min: 0,
            max: CoyoteConfig.protocolMaxIntensity.toDouble(),
            divisions: CoyoteConfig.protocolMaxIntensity,
            onChanged: (value) => setState(
              () => _config = _config.copyWith(triggerIntensity: value.round()),
            ),
          ),
          _CoyoteSlider(
            label: '最大允许强度',
            valueLabel: '${_config.maxIntensity}',
            value: _config.maxIntensity.toDouble(),
            min: 1,
            max: CoyoteConfig.protocolMaxIntensity.toDouble(),
            divisions: CoyoteConfig.protocolMaxIntensity - 1,
            onChanged: (value) => setState(
              () => _config = _config.copyWith(maxIntensity: value.round()),
            ),
          ),
          const SizedBox(height: 8),
          const Text('持续触发方式', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          SegmentedButton<CoyoteOutputDurationMode>(
            key: const ValueKey('simulation_output_duration_mode'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: CoyoteOutputDurationMode.untilRecovery,
                label: Text('无限制（直到恢复）'),
              ),
              ButtonSegment(
                value: CoyoteOutputDurationMode.maximum,
                label: Text('设置最长时间'),
              ),
            ],
            selected: {_config.outputDurationMode},
            onSelectionChanged: (selection) => setState(
              () => _config = _config.copyWith(
                outputDurationMode: selection.first,
              ),
            ),
          ),
          if (_config.outputDurationMode == CoyoteOutputDurationMode.maximum)
            _CoyoteSlider(
              label: '最长输出时间',
              valueLabel: '${_config.duration.inSeconds.clamp(1, 300)} 秒',
              value: _config.duration.inSeconds
                  .toDouble()
                  .clamp(1, 300)
                  .toDouble(),
              min: 1,
              max: 300,
              divisions: 299,
              onChanged: (value) => setState(
                () => _config = _config.copyWith(
                  duration: Duration(seconds: value.round()),
                ),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.only(top: 10, bottom: 8),
              child: Text(
                '异常期间保持模拟输出；恢复正确姿势、急停或结束游戏时立即停止。',
                style: TextStyle(color: AppColors.muted),
              ),
            ),
          _CoyoteSlider(
            label: 'Cooldown',
            valueLabel:
                '${(_config.cooldown.inMilliseconds / 1000).toStringAsFixed(1)} s',
            value: _config.cooldown.inMilliseconds.toDouble().clamp(500, 60000),
            min: 500,
            max: 60000,
            divisions: 119,
            onChanged: (value) => setState(
              () => _config = _config.copyWith(
                cooldown: Duration(milliseconds: value.round()),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('simulation_test'),
                  onPressed: _test,
                  icon: const Icon(Icons.bolt),
                  label: const Text('模拟测试'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('simulation_emergency_stop'),
                  onPressed: widget.coordinator.emergencyStop,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.alert,
                  ),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('立即停止'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const ValueKey('simulation_clear_history'),
            onPressed: device.clearHistory,
            icon: const Icon(Icons.delete_sweep_outlined),
            label: Text('清空记录（${device.history.length}）'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('simulation_save'),
            onPressed: () {
              widget.coordinator.updateSimulationConfig(_config);
              Navigator.pop(context);
            },
            icon: const Icon(Icons.check),
            label: const Text('保存模拟设置'),
          ),
        ],
      ),
    );
  }
}

class _CoyoteSlider extends StatelessWidget {
  const _CoyoteSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(valueLabel, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
      Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: valueLabel,
        onChanged: onChanged,
      ),
    ],
  );
}

class _Results extends StatelessWidget {
  const _Results({required this.c});
  final GameCoordinator c;

  String _sideLabel(BuildContext context, TriggerSide side) => switch (side) {
    TriggerSide.left => context.l10n.text('左侧'),
    TriggerSide.right => context.l10n.text('右侧'),
    TriggerSide.both => context.l10n.text('双侧'),
    TriggerSide.unknown => '',
  };

  String _reasonLabel(BuildContext context, TriggerReason reason) =>
      context.l10n.text(switch (reason) {
        TriggerReason.outside => '关节越界',
        TriggerReason.absent => '离开画面',
        TriggerReason.movement => '木头人移动',
        TriggerReason.pose => '姿势未完成',
        TriggerReason.obstacle => '碰到禁区',
        TriggerReason.balance => '失去平衡',
        TriggerReason.wrongZone => '进入错误区域',
        TriggerReason.customPose => '未对齐目标姿势',
      });

  @override
  Widget build(BuildContext context) {
    final stats = c.engine.stats;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.flag_outlined,
                    size: 34,
                    color: AppColors.green,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    context.l10n.text('游戏结束'),
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    context.l10n.text(c.engine.config.mode.label),
                    style: const TextStyle(color: AppColors.muted),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: _Metric(
                          label: context.l10n.text('实际游戏时长'),
                          value: formatDuration(c.engine.elapsed),
                        ),
                      ),
                      Expanded(
                        child: _Metric(
                          label: context.l10n.text('模拟触发次数'),
                          value: '${c.engine.events.length}',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: _Metric(
                          label: context.l10n.text('异常累计'),
                          value: formatDuration(stats.abnormalDuration),
                        ),
                      ),
                      Expanded(
                        child: _Metric(
                          label: context.l10n.text('最长安全时段'),
                          value: formatDuration(stats.longestSafeDuration),
                        ),
                      ),
                    ],
                  ),
                  if (c.modeSession.hasScore) ...[
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: _Metric(
                            label: context.l10n.text('分数'),
                            value: '${c.modeSession.score}',
                          ),
                        ),
                        Expanded(
                          child: _Metric(
                            label: context.l10n.text(
                              c.engine.config.mode == SafetyGameMode.balance
                                  ? '最长平衡'
                                  : '完成动作',
                            ),
                            value:
                                c.engine.config.mode == SafetyGameMode.balance
                                ? formatDuration(c.modeSession.bestHold)
                                : '${c.modeSession.completedChallenges}',
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    context.l10n.text(
                      c.engine.config.mode == SafetyGameMode.classic
                          ? '越界 {outside} · 离开 {absent}'
                          : '违规 {outside} · 离开 {absent}',
                      {
                        'outside': stats.outsideCount,
                        'absent': stats.absentCount,
                      },
                    ),
                    style: const TextStyle(color: AppColors.muted),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    context.l10n.text('左 {left} · 右 {right} · 双侧 {both}', {
                      'left': stats.leftCount,
                      'right': stats.rightCount,
                      'both': stats.bothCount,
                    }),
                    style: const TextStyle(color: AppColors.muted),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 10),
              child: Text(
                context.l10n.text('触发记录'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Expanded(
              child: c.engine.events.isEmpty
                  ? Center(
                      child: Text(
                        context.l10n.text('本局没有触发记录'),
                        style: const TextStyle(color: AppColors.muted),
                      ),
                    )
                  : ListView.separated(
                      itemCount: c.engine.events.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 24, endIndent: 24),
                      itemBuilder: (context, index) {
                        final event = c.engine.events[index];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 24,
                          ),
                          leading: Text(
                            '${event.sequence}'.padLeft(2, '0'),
                            style: const TextStyle(color: AppColors.muted),
                          ),
                          title: Text(_reasonLabel(context, event.reason)),
                          subtitle: Text(
                            [
                              if (_sideLabel(context, event.side).isNotEmpty)
                                _sideLabel(context, event.side),
                              context.l10n.text('持续 {duration}', {
                                'duration': formatDuration(
                                  event.durationUntil(c.engine.elapsed),
                                ),
                              }),
                            ].join(' · '),
                          ),
                          trailing: Text(
                            formatDuration(event.elapsed),
                            style: const TextStyle(
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: FilledButton.icon(
                onPressed: c.playAgain,
                icon: const Icon(Icons.replay),
                label: Text(context.l10n.text('再来一局')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String formatDuration(Duration duration, {bool roundUp = false}) {
  final seconds = roundUp
      ? (duration.inMilliseconds / 1000).ceil()
      : duration.inSeconds;
  final hours = seconds ~/ 3600;
  final minutes = (seconds ~/ 60) % 60;
  final rest = seconds % 60;
  final mmss =
      '${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
  return hours > 0 ? '$hours:$mmss' : mmss;
}
