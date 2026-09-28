import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mesenger/core/calls/call_service.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/theme/app_theme.dart';

class CallScreen extends StatefulWidget {
  final CallSession session;

  const CallScreen({super.key, required this.session});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _SafeVideo extends StatelessWidget {
  final RTCVideoRenderer renderer;

  const _SafeVideo(this.renderer);

  @override
  Widget build(BuildContext context) {
    // RTCVideoView с неготовым renderer (textureId == null) бросает исключение
    // при отрисовке и показывает «Ошибка интерфейса» (содержимое попадает в
    // ErrorWidget). Рендерим только когда текстура реально создана.
    try {
      if (renderer.textureId == null) return const SizedBox.shrink();
      return RTCVideoView(
        renderer,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }
}

class _CallScreenState extends State<CallScreen> {
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  bool _connected = false;

  CallSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _sub = CallService.instance.events.listen(_onEvent);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_connected && mounted) {
        setState(() => _elapsed += const Duration(seconds: 1));
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  void _onEvent(Map<String, dynamic> event) {
    final etype = event['event'] as String?;
    final session = event['session'] as CallSession?;
    if (session != null && session.callId != session.callId) return;
    if (!mounted) return;
    switch (etype) {
      case 'connected':
        setState(() => _connected = true);
        break;
      case 'remote':
        setState(() {});
        break;
      case 'ended':
        _showEnded(event['reason'] as String?);
        break;
      case 'state':
        setState(() {});
        break;
    }
  }

  void _showEnded(String? reason) {
    if (!mounted) return;
    final msg = reason ?? 'Звонок завершён';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
    Navigator.of(context).pop();
  }

  String get _elapsedText {
    final m = _elapsed.inMinutes.toString().padLeft(2, '0');
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final isOutgoing = session.outgoing;
    final isVideo = session.video;
    final incoming = !isOutgoing && !session.accepted;
    final hasRemote = session.remoteRenderer != null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Удалённое видео (или заглушка)
            if (_connected && hasRemote && isVideo && session.remoteRenderer != null)
              Positioned.fill(
                child: _SafeVideo(session.remoteRenderer!),
              )
            else
              Positioned.fill(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 56,
                        backgroundColor: AppColors.accent.withValues(alpha: 0.3),
                        child: Text(
                          session.peer.title.isNotEmpty
                              ? session.peer.title[0].toUpperCase()
                              : '?',
                          style: const TextStyle(fontSize: 44, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        session.peer.title,
                        style: const TextStyle(fontSize: 22, color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
            // Шапка: статус
            Positioned(
              top: 24,
              left: 24,
              right: 24,
              child: Column(
                children: [
                  Text(
                    incoming
                        ? S.chatCallIncoming
                        : _connected
                            ? _elapsedText
                            : (isOutgoing ? 'Звонок…' : 'Соединение…'),
                    style: const TextStyle(fontSize: 16, color: Colors.white70),
                  ),
                  if (!incoming && _connected)
                    const SizedBox(height: 4),
                  if (!incoming && _connected)
                    Text(
                      _elapsedText,
                      style: const TextStyle(fontSize: 14, color: Colors.white54),
                    ),
                ],
              ),
            ),
            // Локальное видео (PiP)
            if (isVideo &&
                session.localRenderer != null &&
                (incoming || _connected))
              Positioned(
                top: 80,
                right: 16,
                width: 110,
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _SafeVideo(session.localRenderer!),
                ),
              ),
            // Кнопки управления
            Positioned(
              left: 0,
              right: 0,
              bottom: 40,
              child: incoming
                  ? _incomingControls()
                  : _activeControls(isVideo),
            ),
          ],
        ),
      ),
    );
  }

  Widget _incomingControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _roundButton(
          icon: Icons.call_end,
          color: AppColors.danger,
          tooltip: 'Отклонить',
          onTap: () {
            CallService.instance.declineCall();
            Navigator.of(context).pop();
          },
        ),
        _roundButton(
          icon: Icons.call,
          color: const Color(0xFF2ECC71),
          tooltip: 'Ответить',
          onTap: () async {
            try {
              await CallService.instance.acceptCall();
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Не удалось ответить: $e')),
                );
              }
            }
          },
        ),
      ],
    );
  }

  Widget _activeControls(bool isVideo) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _roundButton(
          icon: session.muted ? Icons.mic_off : Icons.mic,
          color: session.muted ? Colors.white : AppColors.surfaceAlt,
          tooltip: 'Микрофон',
          onTap: () => CallService.instance.toggleMute(),
        ),
        _roundButton(
          icon: session.speakerOn ? Icons.volume_up : Icons.volume_down,
          color: session.speakerOn ? AppColors.accent : AppColors.surfaceAlt,
          tooltip: session.speakerOn ? 'Трубка' : 'Громкая связь',
          onTap: () => CallService.instance.toggleSpeaker(),
        ),
        if (isVideo)
          _roundButton(
            icon: session.cameraOn ? Icons.videocam : Icons.videocam_off,
            color: session.cameraOn ? AppColors.surfaceAlt : Colors.white,
            tooltip: 'Камера',
            onTap: () => CallService.instance.toggleCamera(),
          ),
        _roundButton(
          icon: Icons.call_end,
          color: AppColors.danger,
          tooltip: S.chatCallAudio,
          onTap: () {
            CallService.instance.hangup();
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }

  Widget _roundButton({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Icon(icon, color: Colors.black87, size: 28),
          ),
        ),
      ),
    );
  }
}
