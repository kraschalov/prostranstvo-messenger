import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mesenger/core/calls/call_log.dart';
import 'package:mesenger/core/notifications/notification_service.dart';
import 'package:mesenger/core/utils/maps.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/data/local/secure/secure_store.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/data/models/user_profile.dart';
import 'package:mesenger/data/remote/websocket_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';

/// Резервные TURN-параметры (используются, только если сервер не отдал
/// свои через /api/server_info). Секретов здесь быть не должно:
/// значения подставляет сервер хозяина. Пусто = только STUN.
const kTurnHost = '';
const kTurnUser = '';
const kTurnPass = '';

class CallSession {
  final String callId;
  final UserProfile peer;
  final bool video;
  final bool outgoing;
  RTCPeerConnection? pc;
  MediaStream? localStream;
  MediaStream? remoteStream;
  RTCVideoRenderer? localRenderer;
  RTCVideoRenderer? remoteRenderer;
  bool muted = false;
  bool cameraOn = true;
  bool speakerOn = false;
  bool accepted = false;

  CallSession({
    required this.callId,
    required this.peer,
    required this.video,
    required this.outgoing,
  });

  Future<void> dispose() async {
    pc?.close();
    pc?.dispose();
    try {
      await localRenderer?.dispose();
    } catch (_) {}
    try {
      await remoteRenderer?.dispose();
    } catch (_) {}
    localStream?.getTracks().forEach((t) => t.stop());
    remoteStream?.getTracks().forEach((t) => t.stop());
  }
}

class CallService {
  CallService._();

  static final CallService instance = CallService._();

  // Непрерывный рингтон играет НАТИВНЫЙ сервис (MediaPlayer в цикле), т.к. на
  // HyperOS/MIUI звук колкита (Ringtone) играет один раз («пик»). Полноэкранный
  // экран звонка при этом по-прежнему показывает flutter_callkit_incoming.
  static const _ringChannel = MethodChannel('mesenger/incoming_ring');

  /// Имя выбранного рингтона (raw-ресурс без расширения). Хранится в Hive
  /// настройках 'ringtone'; по умолчанию ringtone.wav.
  String get _ringtoneName {
    try {
      final v = HiveService.instance.settings['ringtone'] as String?;
      return (v != null && v.trim().isNotEmpty) ? v.trim() : 'ringtone';
    } catch (_) {
      return 'ringtone';
    }
  }

  Future<void> _startNativeRing(String caller) async {
    try {
      if (Platform.isAndroid) {
        await _ringChannel.invokeMethod('startRing', {
          'caller': caller,
          'ringtone': _ringtoneName,
        });
      }
    } catch (_) {}
  }

  Future<void> _stopNativeRing() async {
    try {
      if (Platform.isAndroid) {
        await _ringChannel.invokeMethod('stopRing');
      }
    } catch (_) {}
  }

  // Входящий звонок через flutter_callkit_incoming (полноэкранный системный
  // экран поверх блокировки со звуком/вибро/кнопками). Самописный нативный
  // CallForegroundService снят — он не вылетал на живом устройстве.
  final _currentCallId = <String>[];

  Future<void> _showCallkit(String caller, {bool video = false}) async {
    try {
      // Полноэкранный вызов поверх блокировки требует разрешений
      // (Android 13+ notification, Android 14+ full screen intent).
      try {
        await FlutterCallkitIncoming.requestNotificationPermission({
          'title': 'Пространство',
          'rationaleMessagePermission': 'Нужно разрешение, чтобы показывать входящие звонки.',
          'postNotificationMessageRequired':
              'Разрешите уведомления приложению, чтобы видеть входящие звонки.',
        });
      } catch (_) {}
      try {
        await FlutterCallkitIncoming.requestFullIntentPermission();
      } catch (_) {}
      // Удаляем колкит-каналы, чтобы звонок звучал нашим рингтоном в цикле, а
      // не «пикал» дефолтным звуком канала, созданного в прошлой версии.
      await NotificationService.instance.deleteCallkitChannels();
      final id = 'call-${DateTime.now().millisecondsSinceEpoch}';
      _currentCallId.add(id);
      final params = CallKitParams(
        id: id,
        nameCaller: caller,
        appName: 'Пространство',
        handle: caller,
        type: video ? 1 : 0,
        duration: 60000,
        extra: <String, dynamic>{},
        // ВАЖНО: showNotification=false отключает фоновый сервис плагина при
        // accept (startForegroundService). Иначе на HyperOS/MIUI плагин зовёт
        // startForeground c уведомлением ongoing → RemoteServiceException
        // «Bad notification for startForeground» → приложение крашится при
        // нажатии «Ответить».
        callingNotification: NotificationParams(showNotification: false),
        android: AndroidParams(
          isCustomNotification: true,
          isShowLogo: false,
          ringtonePath: _ringtoneName,
          backgroundColor: '#0955fa',
          actionColor: '#4CAF50',
          textColor: '#ffffff',
          incomingCallNotificationChannelName: 'Входящие звонки',
          isShowCallID: false,
          isShowFullLockedScreen: true,
          // ВАЖНО: isFullScreen=true → колкит показывает полноэкранный
          // CallkitIncomingActivity и НЕ вызывает showIncomingNotification →
          // НЕ играет свой Ringtone. Иначе на прошивках, где Ringtone колкита
          // работает (Redmi/MIUI), звук дублируется с нашим RingSoundService.
          isFullScreen: true,
          textAccept: 'Ответить',
          textDecline: 'Отклонить',
        ),
        ios: IOSParams(
          handleType: 'generic',
          supportsVideo: video,
        ),
      );
      await FlutterCallkitIncoming.showCallkitIncoming(params);
    } catch (e) {
      debugPrint('CALLKIT SHOW FAIL: $e');
    }
  }

  Future<void> _hideCallkit() async {
    try {
      for (final id in _currentCallId) {
        try {
          await FlutterCallkitIncoming.endCall(id);
        } catch (_) {}
      }
      _currentCallId.clear();
      // Дополнительно гасим входящее уведомление плагина (clearIncoming
      // Notification), иначе на HyperOS экран/плашка входящего продолжает
      // висеть после отмены вызова.
      try {
        await FlutterCallkitIncoming.hideCallkitIncoming(const CallKitParams(
          id: 'all',
          nameCaller: '',
          appName: 'Пространство',
          handle: '',
          type: 0,
        ));
      } catch (_) {}
    } catch (_) {}
  }

  /// Запрос разрешения на микрофон (и камеру для видеозвонка).
  /// Для исходящего запрос идёт со стороны ChatScreen; здесь гарантируем
  /// и для входящего, иначе getUserMedia падает и кнопка «Ответить»
  /// кажется неработающей.
  Future<bool> ensureMediaPermissions(CallSession s) async {
    try {
      // Таймаут: при ответе с заблокированного экрана системный диалог
      // разрешений может не показаться, и request() зависает навсегда.
      final mic = await Permission.microphone.request()
          .timeout(const Duration(seconds: 8));
      final cam = s.video
          ? await Permission.camera.request().timeout(const Duration(seconds: 8))
          : PermissionStatus.granted;
      return mic.isGranted && (s.video ? cam.isGranted : true);
    } catch (_) {
      return false;
    }
  }

  /// Заранее запрашивает микрофон/камеру (вызывается при старте приложения),
  /// чтобы к моменту ответа на звонок разрешения уже были выданы и acceptCall
  /// не висел на системном диалоге с заблокированного экрана.
  Future<void> requestMediaPermissions() async {
    try {
      await Permission.microphone.request().timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  CallSession? _active;
  Map<String, dynamic>? _pendingOffer;
  StreamSubscription? _sub;
  StreamSubscription<CallEvent?>? _ckSub;
  // Защита от гонки: пока идёт acceptCall, событие actionCallEnded (которое
  // колкит шлёт в ответ на нашу прошлую endCall) НЕ должно вызывать hangup.
  bool _accepting = false;
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get events => _events.stream;

  CallSession? get active => _active;

  ValueChanged<CallSession>? onIncoming;

  void start() {
    _sub ??= WebsocketService.instance.events.listen(_onWs);
    _ckSub ??= FlutterCallkitIncoming.onEvent.listen(_onCallkitEvent);
    unawaited(CallLog.instance.init());
    // Заранее запрашиваем микрофон, чтобы «Ответить» не висело на системном
    // диалоге при входящем звонке с заблокированного экрана.
    unawaited(requestMediaPermissions());
  }

  void _onCallkitEvent(CallEvent? event) {
    final name = event?.eventName ?? '';
    switch (name) {
      case CallEventConstants.actionCallAccept:
        unawaited(acceptCall());
        break;
      case CallEventConstants.actionCallDecline:
        declineCall();
        break;
      case CallEventConstants.actionCallEnded:
        // Во время acceptCall не обрываем звонок (см. комментарий к _accepting).
        if (_accepting) break;
        hangup();
        break;
      default:
        break;
    }
  }

  String get _currentDomain =>
      WebsocketService.instance.currentServerDomain ?? 'localhost';

  String _targetFor(UserProfile peer) {
    if (peer.server == _currentDomain || peer.server.isEmpty) {
      return 'user:${peer.id}';
    }
    return 'remote:${peer.server}:${peer.id}';
  }

  /// ICE-конфиг: TURN забираем с сервера через /api/server_info
  /// (см. ApiClient.refreshServerInfo). Фолбэк — старые константы,
  /// чтобы звонки не умирали, пока кэш конфига пуст.
  Map<String, dynamic> get _iceConfig {
    final api = ApiClient.instance;
    final enabled = api.turnEnabled;
    var host = api.turnHost;
    var user = api.turnUser;
    var pass = api.turnPass;
    final port = api.turnPort;
    if (host.isEmpty && kTurnHost.isNotEmpty) {
      host = kTurnHost.contains(':') ? kTurnHost.split(':').first : kTurnHost;
      user = kTurnUser;
      pass = kTurnPass;
    }
    final turnUri = host.contains(':') ? host : '$host:$port';
    final servers = <Map<String, dynamic>>[
      {'urls': ['stun:stun.l.google.com:19302']},
    ];
    if (enabled && user.isNotEmpty && pass.isNotEmpty) {
      servers.add({
        'urls': [
          'turn:$turnUri?transport=udp',
          'turn:$turnUri?transport=tcp',
        ],
        'username': user,
        'credential': pass,
      });
    }
    return {'iceServers': servers};
  }

  Future<CallSession> startCall(UserProfile peer, {required bool video}) async {
    final session = CallSession(
      callId: 'c_${DateTime.now().millisecondsSinceEpoch}',
      peer: peer,
      video: video,
      outgoing: true,
    );
    _active = session;
    await _setupPeerConnection(session);
    final offer = await session.pc!.createOffer();
    await session.pc!.setLocalDescription(offer);
    WebsocketService.instance.send({
      'type': 'call_offer',
      'call_id': session.callId,
      'to': [_targetFor(peer)],
      'sdp': offer.toMap(),
      // Явно сообщаем тип звонка. SDP от flutter_webrtc может содержать
      // m=video с a=recvonly даже для голосового звонка — принимать тип по
      // SDP нельзя (принимающий тогда получит «Ответить с видео» для
      // обычного голосового вызова).
      'video': video,
    });
    _emit({'event': 'outgoing', 'session': session});
    return session;
  }

  Future<void> acceptCall() async {
    final session = _active;
    final offer = _pendingOffer;
    if (session == null || offer == null || session.outgoing) return;
    // Single-flight: accept может прийти ДВАЖДЫ (фоновый маркер + UI-событие
    // от колкита). Второй вызов пока идёт accept — игнорируем, иначе
    // повторный _setupPeerConnection на той же сессии ломает WebRTC и
    // приложение выглядит «крашащимся» при ответе.
if (_accepting) return;
    // Событие accept обработано главным изолятом — очищаем отложенный маркер.
    unawaited(SecureStore.instance.clearDeferredAccept());
    _accepting = true;
    session.accepted = true;
    unawaited(CallLog.instance.write('ACCEPT start call=${session.callId}'));
    // ВАЖНО: не вызываем _hideCallkit() здесь! endCall() триггерит событие
    // actionCallEnded, и обработчик вызывает hangup() -> звонок обрывается
    // («Ответить» ронял вызов, в логах уходил call_hangup вместо call_answer).
    // Колкит сам убирает входящий экран при ACTION_CALL_ACCEPT.
    await _stopNativeRing();
    // Убираем уведомление о входящем звонке — пользователь ответил.
    await NotificationService.instance.cancelCall(session.callId);
    try {
      // Гарантируем доступ к микрофону/камере ДО getUserMedia, иначе
      // ответ провалится и зелёная кнопка «не сработает».
      final ok = await ensureMediaPermissions(session);
      unawaited(CallLog.instance.write('ACCEPT perms ok=$ok'));
      if (!ok) {
        _closeActive();
        _emit({'event': 'ended', 'callId': session.callId, 'reason': 'Нет доступа к микрофону'});
        return;
      }
      // После ответа из колкит-экрана Flutter-движок только поднимается на
      // передний план; даём ему время захватить микрофон, иначе getUserMedia
      // падает («Failed to create new track»), и ответ кажется «крашем».
      await Future<void>.delayed(const Duration(milliseconds: 800));
      try {
        await _setupPeerConnection(session).timeout(const Duration(seconds: 20));
      } catch (ge) {
        // Один повтор после короткой паузы — микрофон может стать доступен.
        debugPrint('RETRY getUserMedia: $ge');
        unawaited(CallLog.instance.write('ACCEPT getUserMedia FAIL: $ge'));
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        await _setupPeerConnection(session).timeout(const Duration(seconds: 20));
      }
      final sdp = asStringMap(offer['sdp']) ?? {};
      unawaited(CallLog.instance.write('ACCEPT sdp ok=${sdp.isNotEmpty} type=${sdp['type']}'));
      if (sdp.isEmpty || sdp['sdp'] == null) {
        _closeActive();
        _emit({'event': 'ended', 'callId': session.callId, 'reason': 'Нет данных о вызове'});
        return;
      }
      try {
        await session.pc!.setRemoteDescription(
          RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?),
        );
        unawaited(CallLog.instance.write('ACCEPT setRemoteDescription OK'));
      } catch (e, st) {
        unawaited(CallLog.instance.write('ACCEPT setRemoteDescription FAIL: $e\n$st'));
        rethrow;
      }
      final answer = await session.pc!.createAnswer();
      unawaited(CallLog.instance.write('ACCEPT createAnswer OK'));
      await session.pc!.setLocalDescription(answer);
      unawaited(CallLog.instance.write('ACCEPT setLocalDescription OK'));
      WebsocketService.instance.send({
        'type': 'call_answer',
        'call_id': session.callId,
        'to': [_targetFor(session.peer)],
        'sdp': answer.toMap(),
      });
      unawaited(CallLog.instance.write('ACCEPT sent call_answer'));
      unawaited(_applyDefaultAudio(session));
      _emit({'event': 'connected', 'session': session});
    } catch (e, st) {
      debugPrint('ACCEPT FAIL: $e\n$st');
      unawaited(CallLog.instance.write('ACCEPT FAIL: $e\n$st'));
      // Сообщаем собеседнику, что ответ не состоялся — иначе у него звонок
      // «висит» бесконечно. Затем закрываем локальную сессию.
      WebsocketService.instance.send({
        'type': 'call_hangup',
        'call_id': session.callId,
        'to': [_targetFor(session.peer)],
      });
      _closeActive();
      _emit({
        'event': 'ended',
        'callId': session.callId,
        'reason': 'Не удалось ответить',
      });
    } finally {
      _accepting = false;
    }
  }

  /// Обработка отложенного «Ответить» из фона: колкит-событие accept пришло в
  /// фоновый колбэк (главный изолят был приостановлен), а не в onEvent.
  /// Фоновый колбэк сохранил маркер accept; здесь, при возврате приложения на
  /// передний план, повторяем acceptCall по активной входящей.
  Future<void> acceptDeferredIfPending() async {
    try {
      final callId = await SecureStore.instance.readDeferredAccept();
      if (callId == null || callId.isEmpty) return;
      await SecureStore.instance.clearDeferredAccept();
      final session = _active;
      final offer = _pendingOffer;
      if (session == null || offer == null || session.outgoing) return;
      if (session.callId != callId) return;
      debugPrint('DEFERRED ACCEPT for $callId');
      await acceptCall();
    } catch (_) {}
  }

  void declineCall() {
    _sendHangup();
    _closeActive();
  }

  void hangup() {
    _sendHangup();
    _closeActive();
  }

  void toggleMute() {
    final s = _active;
    if (s == null) return;
    s.muted = !s.muted;
    s.localStream?.getAudioTracks().forEach((t) {
      Helper.setMicrophoneMute(s.muted, t);
    });
    _emit({'event': 'state', 'session': s});
  }

  Future<void> toggleCamera() async {
    final s = _active;
    if (s == null || !s.video) return;
    s.cameraOn = !s.cameraOn;
    s.localStream?.getVideoTracks().forEach((t) => t.enabled = s.cameraOn);
    _emit({'event': 'state', 'session': s});
  }

/// Переключение динамика: трубка (earpiece) ⇄ громкая связь (speaker).
  /// Сначала плагинные helper'ы, ПОСЛЕДНИМ — нативный setSpeech (он же
  /// закрепляет маршрут; на HyperOS плагин AudioSwitch при своём ходе может
  /// вернуть earpiece, поэтому нативный не должен перебиваться).
  Future<void> toggleSpeaker() async {
    final s = _active;
    if (s == null) return;
    s.speakerOn = !s.speakerOn;
    try {
      await Helper.setSpeakerphoneOn(s.speakerOn);
      await Helper.selectAudioOutput(s.speakerOn ? 'speaker' : 'earpiece');
      await _ringChannel.invokeMethod('setSpeaker', {'enable': s.speakerOn});
      unawaited(CallLog.instance.write('SPK toggle speakerOn=${s.speakerOn}'));
    } catch (e) {
      unawaited(CallLog.instance.write('SPK toggle FAIL: $e'));
    }
    if (_active == s && s.speakerOn) {
      // Повторный форс speaker: WebRTC возвращает earpiece при старте аудио.
      for (final delay in const [Duration(milliseconds: 350), Duration(milliseconds: 900)]) {
        Future<void>.delayed(delay, () async {
          if (_active != s) return;
          try {
            await Helper.setSpeakerphoneOn(true);
            await Helper.selectAudioOutput('speaker');
            await _ringChannel.invokeMethod('setSpeaker', {'enable': true});
          } catch (_) {}
        });
      }
    }
    _emit({'event': 'state', 'session': s});
  }

  /// По умолчанию: голосовой звонок — ТРУБКА (ушной динамик), видео-звонок —
  /// ГРОМКАЯ СВЯЗЬ (внешний динамик, чтобы удобнее смотреть видео).
  Future<void> _applyDefaultAudio(CallSession s) async {
    final speaker = s.video;
    s.speakerOn = speaker;
    try {
      await Helper.setSpeakerphoneOn(speaker);
      await Helper.selectAudioOutput(speaker ? 'speaker' : 'earpiece');
      await _ringChannel.invokeMethod('setSpeaker', {'enable': speaker});
    } catch (_) {}
    if (!speaker) return;
    // На HyperOS/Android 16 WebRTC переустанавливает earpiece, когда начинает
    // играть медиа-трек (видео). Повторно форсируем speaker в момент старта
    // трека, чтобы громкая связь осталась включённой.
    Future<void>.delayed(const Duration(milliseconds: 500), () async {
      if (_active != s) return;
      try {
        await Helper.setSpeakerphoneOn(true);
        await Helper.selectAudioOutput('speaker');
        await _ringChannel.invokeMethod('setSpeaker', {'enable': true});
      } catch (_) {}
    });
    Future<void>.delayed(const Duration(milliseconds: 1600), () async {
      if (_active != s) return;
      try {
        await Helper.setSpeakerphoneOn(true);
        await Helper.selectAudioOutput('speaker');
        await _ringChannel.invokeMethod('setSpeaker', {'enable': true});
      } catch (_) {}
    });
  }

  Future<void> _setupPeerConnection(CallSession s) async {
    final pc = await createPeerConnection(_iceConfig);
    s.pc = pc;

    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': s.video
          ? {
              'facingMode': 'user',
              'width': 640,
              'height': 480,
            }
          : false,
    });
    s.localStream = stream;
    final localRenderer = RTCVideoRenderer();
    await localRenderer.initialize();
    localRenderer.srcObject = stream;
    s.localRenderer = localRenderer;
    for (final track in stream.getTracks()) {
      pc.addTrack(track, stream);
    }

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate?.isNotEmpty == true) {
        unawaited(CallLog.instance.write(
            'ICE send cand=${candidate.candidate!.substring(0, 60)}'));
        WebsocketService.instance.send({
          'type': 'call_ice',
          'call_id': s.callId,
          'to': [_targetFor(s.peer)],
          'candidate': candidate.toMap(),
        });
      }
    };

    pc.onTrack = (event) async {
      try {
        if (event.streams.isNotEmpty) {
          s.remoteStream = event.streams.first;
          final remoteRenderer = RTCVideoRenderer();
          await remoteRenderer.initialize();
          remoteRenderer.srcObject = event.streams.first;
          s.remoteRenderer = remoteRenderer;
          _emit({'event': 'remote', 'session': s});
        }
      } catch (e, st) {
        debugPrint('ONTRACK FAIL: $e\n$st');
        unawaited(CallLog.instance.write('ONTRACK FAIL: $e'));
      }
    };

    pc.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _emit({'event': 'ended', 'callId': s.callId, 'reason': 'Соединение потеряно'});
        _closeActive();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        unawaited(_applyDefaultAudio(s));
        _emit({'event': 'connected', 'session': s});
      }
    };
  }

  void _onWs(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    if (type == null || !type.startsWith('call_')) return;
    final callId = event['call_id'] as String? ?? '';
    final sender = asStringMap(event['sender']) ?? {};
    final sdp = asStringMap(event['sdp']);

    switch (type) {
      case 'call_offer':
        unawaited(CallLog.instance.write('INCOMING call_offer from user=${sender['id']} id=$callId'));
        if (_active != null) {
          _sendBusy();
          return;
        }
        final peer = UserProfile(
          id: (sender['id'] as num?)?.toInt() ?? 0,
          username: sender['username']?.toString() ?? '?',
          handle: '@${sender['username']}@$_currentDomain',
          displayName: sender['username']?.toString() ?? '?',
          gender: 'unknown',
          age: 0,
          city: '',
          goal: '',
          interests: const [],
          bio: '',
          photoPath: '',
        coverPath: '',
          role: 'STANDARD_USER',
          publicKey: '',
          server: _currentDomain,
          online: false,
        );
        // Тип video определяется ЯВНЫМ полем offer (video: true/false),
        // а не анализом SDP: SDP голосового звонка содержит m=video recvonly,
        // из-за чего принимающий видел только «Ответить с видео».
        final explicitVideo = event['video'];
        final isVideo = explicitVideo is bool
            ? explicitVideo
            : _sdpHasVideo(sdp);
        final session = CallSession(
          callId: callId,
          peer: peer,
          video: isVideo,
          outgoing: false,
        );
        _active = session;
        _pendingOffer = event;
        // Нативный входящий звонок НЕПРЕРЫВНО (Foreground Service: рингтон в
        // цикле + вибрация + экран над блокировкой). Раньше — flutter_local
        // notifications («плюк» один раз как текст) не звучал.
        unawaited(_showCallkit(peer.title, video: isVideo));
        // Асинхронный старт нативного рингтона в цикле.
        unawaited(_startNativeRing(peer.title));
        _emit({'event': 'incoming', 'session': session});
        onIncoming?.call(session);
        break;

      case 'call_answer':
        final s = _active;
        if (s == null || !s.outgoing || sdp == null) return;
        unawaited(() async {
          try {
            await s.pc?.setRemoteDescription(
              RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?),
            );
          } catch (e, st) {
            debugPrint('ANSWER SDP FAIL: $e\n$st');
            unawaited(CallLog.instance.write('ANSWER SDP FAIL: $e\n$st'));
          }
        }());
        break;

      case 'call_ice':
        final s = _active;
        final cand = asStringMap(event['candidate']);
        if (s == null || cand == null || s.pc == null) return;
        unawaited(CallLog.instance.write(
            'ICE recv cand=${(cand['candidate'] as String? ?? '').substring(0, (cand['candidate'] as String? ?? '').length.clamp(0, 60))}'));
        unawaited(() async {
          try {
            await s.pc!.addCandidate(RTCIceCandidate(
              cand['candidate'] as String?,
              cand['sdpMid'] as String?,
              (cand['sdpMLineIndex'] as num?)?.toInt(),
            ));
          } catch (e) {
            debugPrint('ICE ADD FAIL: $e');
          }
        }());
        break;

      case 'call_hangup':
        unawaited(CallLog.instance.write('INCOMING call_hangup id=$callId'));
        _emit({'event': 'ended', 'callId': callId});
        _closeActive();
        break;
    }
  }

  bool _sdpHasVideo(Map<String, dynamic>? sdp) {
    if (sdp == null) return false;
    final body = sdp['sdp'] as String? ?? '';
    return body.contains('m=video');
  }

  void _sendBusy() {
    final s = _active;
    if (s != null) {
      WebsocketService.instance.send({
        'type': 'call_hangup',
        'call_id': s.callId,
        'to': [_targetFor(s.peer)],
      });
    }
  }

  void _sendHangup() {
    final s = _active;
    if (s != null) {
      WebsocketService.instance.send({
        'type': 'call_hangup',
        'call_id': s.callId,
        'to': [_targetFor(s.peer)],
      });
    }
  }

  void _closeActive() {
    final s = _active;
    if (s != null) {
      unawaited(NotificationService.instance.cancelCall(s.callId));
    }
    // Останавливаем непрерывный рингтон (если это был входящий звонок).
    unawaited(_hideCallkit());
    unawaited(_stopNativeRing());
    _pendingOffer = null;
    _active = null;
    if (s != null) {
      unawaited(s.dispose());
    }
  }

  void _emit(Map<String, dynamic> e) {
    if (!_events.isClosed) {
      _events.add(e);
    }
  }
}
