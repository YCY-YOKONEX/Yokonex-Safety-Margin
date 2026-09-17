import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';

import '../app/game_coordinator.dart';
import '../domain/activity_region.dart';
import '../domain/ems_protocol.dart';
import '../domain/ems_waveform.dart';
import '../domain/game_engine.dart';
import '../domain/pose_sample.dart';
import '../services/ems_device.dart';
import 'app_localizations.dart';
import 'app_theme.dart';
import 'camera_stage.dart';

class SafetyMarginApp extends StatefulWidget {
  const SafetyMarginApp({super.key, this.coordinator});
  final GameCoordinator? coordinator;

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
        onLocaleChanged: _locale.setLocale,
      ),
    ),
  );
}

class GameHome extends StatefulWidget {
  const GameHome({super.key, this.coordinator, required this.onLocaleChanged});
  final GameCoordinator? coordinator;
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
  int _lastEventCount = 0;

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
    c.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    unawaited(c.initialize());
  }

  void _changed() {
    if (!mounted) return;
    final eventCount = c.engine.events.length;
    // 每次新触发（越界/跟踪不完整/画面中无人）都提醒一次，与设备持续输出解耦。
    if (eventCount > _lastEventCount) {
      unawaited(_playSound(_alertPlayer, 'trigger_alert.wav'));
    }
    _lastEventCount = eventCount;
    if (_noticeVersion != c.noticeVersion) {
      _noticeVersion = c.noticeVersion;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && c.notice != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.message(c.notice!))),
          );
        }
      });
    }
    setState(() {});
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
    super.dispose();
  }

  void _startCountdown() {
    final seconds = c.engine.config.startCountdown.inSeconds;
    if (seconds <= 0) {
      c.start();
      return;
    }
    setState(() => _countdownRemaining = seconds);
    unawaited(_playSound(_tickPlayer, 'countdown_tick.wav'));
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remaining = (_countdownRemaining ?? 1) - 1;
      if (remaining <= 0) {
        timer.cancel();
        _countdownTimer = null;
        if (mounted) setState(() => _countdownRemaining = null);
        unawaited(_playSound(_goPlayer, 'countdown_go.wav'));
        c.start();
        return;
      }
      if (mounted) setState(() => _countdownRemaining = remaining);
      unawaited(_playSound(_tickPlayer, 'countdown_tick.wav'));
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    if (_countdownRemaining != null) setState(() => _countdownRemaining = null);
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
    final device = c.ems;
    if (device == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (_) =>
          _EmsSettingsSheet(device: device, onSave: c.updateEmsConfig),
    );
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
              bottom: !finished && ready && c.ems != null
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
                                  foregroundColor: c.ems!.readyToOutput
                                      ? AppColors.green
                                      : AppColors.muted,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                ),
                                icon: Icon(
                                  c.ems!.connected
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
                                if (ready)
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
                                            GameConfig(
                                              duration: duration,
                                              startCountdown: c
                                                  .engine
                                                  .config
                                                  .startCountdown,
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
                                      : c.ems == null
                                      ? '开始游戏'
                                      : !c.ems!.connected
                                      ? '连接 EMS 设备'
                                      : (c.ems!.config.intensityA == 0 &&
                                            c.ems!.config.intensityB == 0)
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
    final label = c.region == null
        ? '区域未设置'
        : c.editing
        ? '画区中'
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
        children: [
          const Divider(height: 1),
          const SizedBox(height: 16),
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

class _EmsSettingsSheet extends StatefulWidget {
  const _EmsSettingsSheet({required this.device, required this.onSave});

  final EmsDeviceController device;
  final ValueChanged<EmsConfig> onSave;

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

class _Results extends StatelessWidget {
  const _Results({required this.c});
  final GameCoordinator c;

  @override
  Widget build(BuildContext context) => Center(
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
                        title: Text(
                          context.l10n.text(
                            event.reason == TriggerReason.outside
                                ? '关节越界'
                                : '离开画面',
                          ),
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
