import 'package:flutter_tts/flutter_tts.dart';

abstract interface class SpeechOutput {
  Future<void> speak(String text, {required String languageTag});
  Future<void> stop();
  Future<void> dispose();
}

class SystemSpeechOutput implements SpeechOutput {
  SystemSpeechOutput({FlutterTts? engine}) : _engine = engine ?? FlutterTts();

  final FlutterTts _engine;
  String? _languageTag;
  int _generation = 0;
  bool _disposed = false;

  @override
  Future<void> speak(String text, {required String languageTag}) async {
    if (_disposed || text.trim().isEmpty) return;
    final generation = ++_generation;
    try {
      await _engine.stop();
      if (_disposed || generation != _generation) return;
      if (_languageTag != languageTag) {
        await _engine.setLanguage(languageTag);
        _languageTag = languageTag;
      }
      await _engine.setSpeechRate(.48);
      await _engine.setVolume(1);
      await _engine.setPitch(1);
      if (_disposed || generation != _generation) return;
      await _engine.speak(text, focus: true);
    } on Object {
      // 系统没有可用语音引擎时保留大字提示，不影响游戏与设备安全链路。
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    try {
      await _engine.stop();
    } on Object {
      // 停止语音失败不应阻塞暂停、急停或退出。
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
  }
}
