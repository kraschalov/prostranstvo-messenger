import 'dart:async';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Запись голосового сообщения. Одна сессия записи на раз.
class VoiceRecorder {
  VoiceRecorder._();

  static final VoiceRecorder instance = VoiceRecorder._();

  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  String? _path;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  bool get isRecording => _recording;

  Duration get elapsed => _elapsed;

  Future<bool> start() async {
    if (_recording) return false;
    try {
      if (await _recorder.hasPermission() != true) return false;
      final dir = await getTemporaryDirectory();
      _path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      final config = const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 44100,
      );
      await _recorder.start(config, path: _path!);
      _recording = true;
      _elapsed = Duration.zero;
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        _elapsed += const Duration(seconds: 1);
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Останавливает запись и возвращает путь к файлу (null при ошибке).
  Future<String?> stop() async {
    if (!_recording) return null;
    _ticker?.cancel();
    _ticker = null;
    try {
      final path = await _recorder.stop();
      _recording = false;
      return path ?? _path;
    } catch (_) {
      _recording = false;
      return null;
    }
  }
}