import 'dart:math' as math;
import 'dart:ui';

import 'activity_region.dart';
import 'pose_sample.dart';

enum SafetyGameMode {
  classic,
  redLightGreenLight,
  shrinkingZone,
  poseChallenge,
  dodge,
  balance,
  combo,
  dualZone,
}

extension SafetyGameModeInfo on SafetyGameMode {
  bool get requiresRegion => switch (this) {
    SafetyGameMode.classic ||
    SafetyGameMode.shrinkingZone ||
    SafetyGameMode.dualZone => true,
    _ => false,
  };

  String get label => switch (this) {
    SafetyGameMode.classic => '经典安全区',
    SafetyGameMode.redLightGreenLight => '木头人',
    SafetyGameMode.shrinkingZone => '缩圈模式',
    SafetyGameMode.poseChallenge => '指定姿势',
    SafetyGameMode.dodge => '闪避模式',
    SafetyGameMode.balance => '平衡挑战',
    SafetyGameMode.combo => '连击模式',
    SafetyGameMode.dualZone => '双区模式',
  };
}

enum PoseChallenge {
  raiseLeftHand,
  raiseRightHand,
  raiseLeftLeg,
  raiseRightLeg,
  squat,
  armsOut,
}

extension PoseChallengeInfo on PoseChallenge {
  String get label => switch (this) {
    PoseChallenge.raiseLeftHand => '举起左手',
    PoseChallenge.raiseRightHand => '举起右手',
    PoseChallenge.raiseLeftLeg => '抬起左腿',
    PoseChallenge.raiseRightLeg => '抬起右腿',
    PoseChallenge.squat => '保持下蹲',
    PoseChallenge.armsOut => '双手展开',
  };

  TriggerSide get side => switch (this) {
    PoseChallenge.raiseLeftHand ||
    PoseChallenge.raiseLeftLeg => TriggerSide.left,
    PoseChallenge.raiseRightHand ||
    PoseChallenge.raiseRightLeg => TriggerSide.right,
    PoseChallenge.squat || PoseChallenge.armsOut => TriggerSide.both,
  };
}

enum ModeViolation { boundary, movement, pose, obstacle, balance, wrongZone }

class ModeObservation {
  const ModeObservation(
    this.status, {
    this.side = TriggerSide.unknown,
    this.violation = ModeViolation.boundary,
    this.forceDirectional = false,
  });

  final TrackingStatus status;
  final TriggerSide side;
  final ModeViolation violation;
  final bool forceDirectional;
}

class GameModeSession {
  GameModeSession({math.Random? random}) : _random = random ?? math.Random();

  static const greenDuration = Duration(seconds: 5);
  static const redDuration = Duration(seconds: 3);
  static const challengeGrace = Duration(seconds: 2);
  static const challengeHold = Duration(milliseconds: 1000);
  static const comboHold = Duration(milliseconds: 700);
  static const movementThreshold = .025;

  final math.Random _random;
  SafetyGameMode mode = SafetyGameMode.classic;
  PoseChallenge? challenge;
  int score = 0;
  int combo = 0;
  int bestCombo = 0;
  int completedChallenges = 0;
  Duration currentHold = Duration.zero;
  Duration bestHold = Duration.zero;
  Duration _challengeStarted = Duration.zero;
  Duration? _holdStarted;
  PoseSample? _freezeReference;
  bool _lastRedLight = false;
  bool _violationActive = false;

  bool get hasScore => switch (mode) {
    SafetyGameMode.poseChallenge ||
    SafetyGameMode.balance ||
    SafetyGameMode.combo => true,
    _ => false,
  };

  void reset(SafetyGameMode value) {
    mode = value;
    challenge = null;
    score = 0;
    combo = 0;
    bestCombo = 0;
    completedChallenges = 0;
    currentHold = Duration.zero;
    bestHold = Duration.zero;
    _challengeStarted = Duration.zero;
    _holdStarted = null;
    _freezeReference = null;
    _lastRedLight = false;
    _violationActive = false;
    if (mode == SafetyGameMode.poseChallenge || mode == SafetyGameMode.combo) {
      _pickChallenge();
    }
  }

  bool isGreenLight(Duration elapsed) {
    final cycle = greenDuration + redDuration;
    return elapsed.inMilliseconds % cycle.inMilliseconds <
        greenDuration.inMilliseconds;
  }

  String prompt(Duration elapsed) => switch (mode) {
    SafetyGameMode.classic => '保持全身在安全区域内',
    SafetyGameMode.redLightGreenLight =>
      isGreenLight(elapsed) ? '音乐播放：可以移动' : '木头人：保持静止',
    SafetyGameMode.shrinkingZone => '安全区域正在缩小',
    SafetyGameMode.poseChallenge => challenge?.label ?? '准备姿势',
    SafetyGameMode.dodge => '闪避移动禁区',
    SafetyGameMode.balance => '双手展开并单脚站立',
    SafetyGameMode.combo => challenge?.label ?? '准备姿势',
    SafetyGameMode.dualZone => '左侧留在 A 区，右侧留在 B 区',
  };

  ActivityRegion? effectiveRegion(
    ActivityRegion? base,
    Duration elapsed,
    Duration total,
  ) {
    if (base == null || !mode.requiresRegion) return null;
    if (mode != SafetyGameMode.shrinkingZone) return base;
    final progress = total.inMilliseconds <= 0
        ? 1.0
        : (elapsed.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    return base.scaled(1 - .55 * progress);
  }

  Rect obstacleAt(Duration elapsed) {
    final seconds = elapsed.inMilliseconds / 1000;
    final phase = (seconds / 3) % 2;
    final sweep = phase <= 1 ? phase : 2 - phase;
    final x = .04 + .72 * sweep;
    final y = .34 + .16 * math.sin(seconds * 1.35);
    return Rect.fromLTWH(x, y, .20, .18);
  }

  (ActivityRegion, ActivityRegion)? dualZones(ActivityRegion? base) {
    if (base == null) return null;
    final bounds = base.bounds;
    final middle = bounds.center.dx;
    return (
      ActivityRegion.rectangle(bounds.topLeft, Offset(middle, bounds.bottom)),
      ActivityRegion.rectangle(Offset(middle, bounds.top), bounds.bottomRight),
    );
  }

  ModeObservation evaluate(
    PoseSample sample,
    ActivityRegion? baseRegion,
    Duration elapsed,
    Duration total,
  ) {
    return switch (mode) {
      SafetyGameMode.classic => _regionObservation(sample, baseRegion),
      SafetyGameMode.redLightGreenLight => _redLightObservation(
        sample,
        elapsed,
      ),
      SafetyGameMode.shrinkingZone => _regionObservation(
        sample,
        effectiveRegion(baseRegion, elapsed, total),
      ),
      SafetyGameMode.poseChallenge => _challengeObservation(
        sample,
        elapsed,
        comboMode: false,
      ),
      SafetyGameMode.dodge => _dodgeObservation(sample, elapsed),
      SafetyGameMode.balance => _balanceObservation(sample, elapsed),
      SafetyGameMode.combo => _challengeObservation(
        sample,
        elapsed,
        comboMode: true,
      ),
      SafetyGameMode.dualZone => _dualZoneObservation(sample, baseRegion),
    };
  }

  ModeObservation _regionObservation(
    PoseSample sample,
    ActivityRegion? region,
  ) {
    final status = sample.classify(region);
    return ModeObservation(
      status,
      side: status == TrackingStatus.outside
          ? sample.outsideSide(region)
          : TriggerSide.unknown,
    );
  }

  ModeObservation _redLightObservation(PoseSample sample, Duration elapsed) {
    final availability = _availability(sample, monitoredJoints);
    if (availability != TrackingStatus.inside) {
      return ModeObservation(availability, violation: ModeViolation.movement);
    }
    final red = !isGreenLight(elapsed);
    if (!red) {
      _freezeReference = null;
      _lastRedLight = false;
      return const ModeObservation(TrackingStatus.inside);
    }
    if (!_lastRedLight || _freezeReference == null) {
      _freezeReference = sample;
      _lastRedLight = true;
      return const ModeObservation(TrackingStatus.inside);
    }
    final side = _movementSide(_freezeReference!, sample);
    return ModeObservation(
      side == TriggerSide.unknown
          ? TrackingStatus.inside
          : TrackingStatus.outside,
      side: side,
      violation: ModeViolation.movement,
    );
  }

  ModeObservation _challengeObservation(
    PoseSample sample,
    Duration elapsed, {
    required bool comboMode,
  }) {
    final current = challenge;
    if (current == null) return const ModeObservation(TrackingStatus.waiting);
    final required = _requiredJoints(current);
    final availability = _availability(sample, required);
    if (availability != TrackingStatus.inside) {
      _holdStarted = null;
      currentHold = Duration.zero;
      return ModeObservation(
        availability,
        side: current.side,
        violation: ModeViolation.pose,
      );
    }
    final correct = _matches(sample, current);
    if (correct) {
      _violationActive = false;
      _holdStarted ??= elapsed;
      currentHold = elapsed - _holdStarted!;
      final target = comboMode ? comboHold : challengeHold;
      if (currentHold >= target) {
        completedChallenges++;
        if (comboMode) {
          combo++;
          bestCombo = math.max(bestCombo, combo);
          score += 100 * combo;
        } else {
          score += 100;
        }
        _pickChallenge();
        _challengeStarted = elapsed;
        _holdStarted = null;
        currentHold = Duration.zero;
      }
      return const ModeObservation(TrackingStatus.inside);
    }
    _holdStarted = null;
    currentHold = Duration.zero;
    if (elapsed - _challengeStarted < challengeGrace) {
      return const ModeObservation(TrackingStatus.inside);
    }
    if (comboMode && !_violationActive) combo = 0;
    _violationActive = true;
    return ModeObservation(
      TrackingStatus.outside,
      side: current.side,
      violation: ModeViolation.pose,
    );
  }

  ModeObservation _dodgeObservation(PoseSample sample, Duration elapsed) {
    final availability = _availability(sample, monitoredJoints);
    if (availability != TrackingStatus.inside) {
      return ModeObservation(availability, violation: ModeViolation.obstacle);
    }
    final obstacle = obstacleAt(elapsed);
    var left = false;
    var right = false;
    for (final joint in monitoredJoints) {
      final point = sample.landmarks[joint]!;
      if (!obstacle.contains(point.position)) continue;
      if (leftMonitoredJoints.contains(joint)) left = true;
      if (rightMonitoredJoints.contains(joint)) right = true;
    }
    final side = _side(left, right);
    return ModeObservation(
      side == TriggerSide.unknown
          ? TrackingStatus.inside
          : TrackingStatus.outside,
      side: side,
      violation: ModeViolation.obstacle,
    );
  }

  ModeObservation _balanceObservation(PoseSample sample, Duration elapsed) {
    const required = {
      Joint.leftShoulder,
      Joint.rightShoulder,
      Joint.leftElbow,
      Joint.rightElbow,
      Joint.leftWrist,
      Joint.rightWrist,
      Joint.leftAnkle,
      Joint.rightAnkle,
    };
    final availability = _availability(sample, required);
    if (availability != TrackingStatus.inside) {
      _closeBalanceHold(elapsed);
      return ModeObservation(availability, violation: ModeViolation.balance);
    }
    final balanced =
        _matches(sample, PoseChallenge.armsOut) &&
        (_matches(sample, PoseChallenge.raiseLeftLeg) ||
            _matches(sample, PoseChallenge.raiseRightLeg));
    if (balanced) {
      _holdStarted ??= elapsed;
      currentHold = elapsed - _holdStarted!;
      bestHold = currentHold > bestHold ? currentHold : bestHold;
      score = bestHold.inMilliseconds ~/ 100;
      return const ModeObservation(TrackingStatus.inside);
    }
    _closeBalanceHold(elapsed);
    if (elapsed < challengeGrace) {
      return const ModeObservation(TrackingStatus.inside);
    }
    return const ModeObservation(
      TrackingStatus.outside,
      side: TriggerSide.both,
      violation: ModeViolation.balance,
    );
  }

  ModeObservation _dualZoneObservation(
    PoseSample sample,
    ActivityRegion? base,
  ) {
    if (base == null) return const ModeObservation(TrackingStatus.waiting);
    if (!sample.personDetected) {
      return const ModeObservation(
        TrackingStatus.absent,
        violation: ModeViolation.wrongZone,
        forceDirectional: true,
      );
    }
    final zones = dualZones(base)!;
    var complete = true;
    var left = false;
    var right = false;
    for (final joint in monitoredJoints) {
      final point = sample.landmarks[joint];
      if (point == null || !point.isReliable) {
        complete = false;
        continue;
      }
      if (leftMonitoredJoints.contains(joint) &&
          !zones.$1.containsWithMargin(point.position, boundaryTolerance)) {
        left = true;
      }
      if (rightMonitoredJoints.contains(joint) &&
          !zones.$2.containsWithMargin(point.position, boundaryTolerance)) {
        right = true;
      }
    }
    final side = _side(left, right);
    return ModeObservation(
      side != TriggerSide.unknown
          ? TrackingStatus.outside
          : complete
          ? TrackingStatus.inside
          : TrackingStatus.incomplete,
      side: side,
      violation: ModeViolation.wrongZone,
      forceDirectional: true,
    );
  }

  TrackingStatus _availability(PoseSample sample, Set<Joint> required) {
    if (!sample.personDetected) return TrackingStatus.absent;
    for (final joint in required) {
      if (!(sample.landmarks[joint]?.isReliable ?? false)) {
        return TrackingStatus.incomplete;
      }
    }
    return TrackingStatus.inside;
  }

  Set<Joint> _requiredJoints(PoseChallenge value) => switch (value) {
    PoseChallenge.raiseLeftHand => const {Joint.leftShoulder, Joint.leftWrist},
    PoseChallenge.raiseRightHand => const {
      Joint.rightShoulder,
      Joint.rightWrist,
    },
    PoseChallenge.raiseLeftLeg => const {Joint.leftAnkle, Joint.rightAnkle},
    PoseChallenge.raiseRightLeg => const {Joint.leftAnkle, Joint.rightAnkle},
    PoseChallenge.squat => const {
      Joint.leftShoulder,
      Joint.rightShoulder,
      Joint.leftHip,
      Joint.rightHip,
      Joint.leftKnee,
      Joint.rightKnee,
      Joint.leftAnkle,
      Joint.rightAnkle,
    },
    PoseChallenge.armsOut => const {
      Joint.leftShoulder,
      Joint.rightShoulder,
      Joint.leftElbow,
      Joint.rightElbow,
      Joint.leftWrist,
      Joint.rightWrist,
    },
  };

  bool _matches(PoseSample sample, PoseChallenge value) {
    Offset p(Joint joint) => sample.landmarks[joint]!.position;
    return switch (value) {
      PoseChallenge.raiseLeftHand =>
        p(Joint.leftWrist).dy < p(Joint.leftShoulder).dy - .05,
      PoseChallenge.raiseRightHand =>
        p(Joint.rightWrist).dy < p(Joint.rightShoulder).dy - .05,
      PoseChallenge.raiseLeftLeg =>
        p(Joint.leftAnkle).dy < p(Joint.rightAnkle).dy - .08,
      PoseChallenge.raiseRightLeg =>
        p(Joint.rightAnkle).dy < p(Joint.leftAnkle).dy - .08,
      PoseChallenge.squat => _isSquatting(sample),
      PoseChallenge.armsOut =>
        (p(Joint.leftWrist).dy - p(Joint.leftShoulder).dy).abs() < .10 &&
            (p(Joint.rightWrist).dy - p(Joint.rightShoulder).dy).abs() < .10 &&
            p(Joint.leftWrist).dx < p(Joint.leftElbow).dx &&
            p(Joint.rightWrist).dx > p(Joint.rightElbow).dx,
    };
  }

  bool _isSquatting(PoseSample sample) {
    Offset p(Joint joint) => sample.landmarks[joint]!.position;
    final shoulderY =
        (p(Joint.leftShoulder).dy + p(Joint.rightShoulder).dy) / 2;
    final hipY = (p(Joint.leftHip).dy + p(Joint.rightHip).dy) / 2;
    final kneeY = (p(Joint.leftKnee).dy + p(Joint.rightKnee).dy) / 2;
    final ankleY = (p(Joint.leftAnkle).dy + p(Joint.rightAnkle).dy) / 2;
    final torso = hipY - shoulderY;
    return torso > .08 && kneeY - hipY < torso * .55 && ankleY - kneeY > .08;
  }

  TriggerSide _movementSide(PoseSample before, PoseSample after) {
    var left = false;
    var right = false;
    for (final joint in monitoredJoints) {
      final a = before.landmarks[joint];
      final b = after.landmarks[joint];
      if (a == null || b == null || !a.isReliable || !b.isReliable) continue;
      if ((a.position - b.position).distance <= movementThreshold) continue;
      if (leftMonitoredJoints.contains(joint)) left = true;
      if (rightMonitoredJoints.contains(joint)) right = true;
    }
    return _side(left, right);
  }

  TriggerSide _side(bool left, bool right) {
    if (left && right) return TriggerSide.both;
    if (left) return TriggerSide.left;
    if (right) return TriggerSide.right;
    return TriggerSide.unknown;
  }

  void _pickChallenge() {
    final values = PoseChallenge.values;
    final current = challenge;
    if (current == null) {
      challenge = values[_random.nextInt(values.length)];
      return;
    }
    var index = _random.nextInt(values.length - 1);
    final currentIndex = values.indexOf(current);
    if (index >= currentIndex) index++;
    challenge = values[index];
  }

  void _closeBalanceHold(Duration elapsed) {
    if (_holdStarted != null) {
      currentHold = elapsed - _holdStarted!;
      bestHold = currentHold > bestHold ? currentHold : bestHold;
    }
    _holdStarted = null;
    currentHold = Duration.zero;
  }
}
