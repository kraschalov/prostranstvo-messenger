import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Запись видеокружочка: полноэкранная камера, тап по круглой кнопке —
/// запись, повторный тап — стоп. Возвращает путь к видеофайлу через pop.
class VideoCircleScreen extends StatefulWidget {
  const VideoCircleScreen({super.key});

  @override
  State<VideoCircleScreen> createState() => _VideoCircleScreenState();
}

class _VideoCircleScreenState extends State<VideoCircleScreen> {
  CameraController? _controller;
  bool _recording = false;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(front, ResolutionPreset.medium);
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _ready = true;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось открыть камеру');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final c = _controller;
    if (c == null || !_ready) return;
    if (_recording) {
      try {
        final file = await c.stopVideoRecording();
        if (mounted) Navigator.of(context).pop(file.path);
      } catch (_) {
        if (mounted) setState(() => _error = 'Не удалось остановить запись');
      }
    } else {
      try {
        await c.startVideoRecording();
        if (mounted) setState(() => _recording = true);
      } catch (_) {
        if (mounted) setState(() => _error = 'Не удалось начать запись');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_ready && _controller != null)
            SizedBox.expand(
              child: CameraPreview(_controller!),
            )
          else
            Center(
              child: _error != null
                  ? Text(_error!, style: const TextStyle(color: Colors.white))
                  : const CircularProgressIndicator(),
            ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 40),
                child: GestureDetector(
                  onTap: _toggle,
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _recording ? Colors.redAccent : Colors.white,
                      border: Border.all(color: Colors.white, width: 4),
                    ),
                    child: Center(
                      child: Icon(
                        _recording ? Icons.stop : Icons.videocam,
                        color: _recording ? Colors.white : Colors.black,
                        size: 32,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
