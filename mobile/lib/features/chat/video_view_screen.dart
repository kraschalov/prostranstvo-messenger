import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Просмотр видеовложения (видеокружка). Тап по видео — пауза/продолжить.
class VideoViewScreen extends StatefulWidget {
  final String url;

  const VideoViewScreen({super.key, required this.url});

  @override
  State<VideoViewScreen> createState() => _VideoViewScreenState();
}

class _VideoViewScreenState extends State<VideoViewScreen> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      if (!mounted) return;
      setState(() => _controller = c);
    } catch (_) {}
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black),
      body: c == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: GestureDetector(
                onTap: () {
                  if (c.value.isPlaying) {
                    c.pause();
                  } else {
                    c.play();
                  }
                },
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              ),
            ),
    );
  }
}
