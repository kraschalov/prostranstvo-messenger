import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesenger/core/calls/call_service.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/core/media/voice_recorder.dart';
import 'package:mesenger/core/theme/app_theme.dart';
import 'package:mesenger/data/local/hive/hive_service.dart';
import 'package:mesenger/data/models/chat_message.dart';
import 'package:mesenger/data/models/user_profile.dart';
import 'package:mesenger/data/repositories/chat_repository.dart';
import 'package:mesenger/data/remote/api_client.dart';
import 'package:mesenger/features/call/call_screen.dart';
import 'package:mesenger/features/chat/video_circle_screen.dart';
import 'package:mesenger/features/chat/video_view_screen.dart';
import 'package:mesenger/widgets/common.dart';
import 'package:mesenger/widgets/server_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String chatId;

  const ChatScreen({super.key, required this.chatId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late List<ChatMessage> _messages;
  StreamSubscription<dynamic>? _boxSub;
  bool _sending = false;
  UserProfile? _peerProfile;

  Map<String, dynamic>? get _contact {
    final contacts = HiveService.instance.contactsList;
    for (final c in contacts) {
      if (c is Map && c['chatId'] == widget.chatId) {
        return Map<String, dynamic>.from(c);
      }
    }
    return null;
  }

  int get _peerId => int.tryParse(widget.chatId.replaceFirst('dm_', '')) ?? 0;

  UserProfile get _peer {
    final loaded = _peerProfile;
    if (loaded != null) return loaded;
    final c = _contact;
    if (c != null) {
      return UserProfile(
        id: _peerId,
        username: c['handle']?.toString().replaceAll('@', '') ?? '?',
        handle: c['handle']?.toString() ?? '?',
        displayName: c['displayName']?.toString() ?? '?',
        gender: 'unknown',
        age: 0,
        city: c['city']?.toString() ?? '',
        goal: '',
        interests: const [],
        bio: c['bio']?.toString() ?? '',
        photoPath: '',
        coverPath: '',
        role: 'STANDARD_USER',
        publicKey: c['publicKey']?.toString() ?? '',
        server: c['server']?.toString() ?? '',
        online: false,
      );
    }
    // Fallback when contact not in local storage
    return UserProfile(
      id: _peerId,
      username: 'user_$_peerId',
      handle: '@user_$_peerId',
      displayName: 'Пользователь $_peerId',
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
      server: '',
      online: false,
    );
  }

  @override
  void initState() {
    super.initState();
    _messages = HiveService.instance
        .chatHistory(widget.chatId)
        .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList();
    _boxSub = HiveService.instance.chats.watch().listen((_) {
      if (mounted) _reload();
    });
    // Всегда подгружаем актуальный профиль собеседника с сервера и
    // обновляем контакт текущим публичным ключом. Раньше это делалось
    // только если контакта нет — если E2EE-ключ собеседника менялся
    // (переустановка, сбой хранилища), локальный контакт оставался со
    // старым ключом, шифрование шло мимо, и замкнутый круг не
    // разрывался. Источник истины для ключа — сервер.
    _loadPeerProfile();
    // Отправляем «прочитано» по накопленным входящим при ОТКРЫТИИ чата
    // (не только при изменении Hive): иначе read уходил лишь после нового
    // сообщения, и собеседник видел «получено» навсегда.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markIncomingRead();
    });
    // Длинный чат открывается сразу прокрученным вниз (к последним
    // сообщениям), а не с начала истории. Прокручиваем несколько раз:
    // первый кадр может показать спиннер вместо списка, поэтому ждём,
    // пока ListView с реальным числом сообщений отрисуется.
    WidgetsBinding.instance.addPostFrameCallback((_) => _forceScrollBottom());
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (mounted) _forceScrollBottom();
    });
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _forceScrollBottom();
    });
  }

  void _forceScrollBottom() {
    if (!_scroll.hasClients) return;
    try {
      final target = _scroll.position.maxScrollExtent;
      if (target > _scroll.offset) {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    } catch (_) {}
  }

  Future<void> _loadPeerProfile() async {
    try {
      final profile = await ApiClient.instance.fetchProfileById(_peerId);
      if (!mounted) return;
      final userProfile = UserProfile.fromJson(profile);
      setState(() => _peerProfile = userProfile);
      // Ключ шифрования собеседника должен браться ИЗ РЕАЛЬНЫХ входящих
      // сообщений (она актуальный, т.к. собеседник сам им шифровал), а НЕ с
      // сервера: серверный публичный ключ может устареть (пересоздание
      // ключа при сбое хранилища). Если в контакте уже есть непустой ключ —
      // сохраняем его, серверный профиль используем только для метаданных.
      var peerKey = userProfile.publicKey;
      try {
        final existing = _contact;
        if (existing != null &&
            (existing['publicKey']?.toString().isNotEmpty ?? false)) {
          peerKey = existing['publicKey'].toString();
        }
      } catch (_) {}
      await HiveService.instance.updateContact({
        'id': userProfile.id,
        'chatId': 'dm_${userProfile.id}',
        'handle': userProfile.handle,
        'server': userProfile.server,
        'publicKey': peerKey,
        'displayName': userProfile.title,
        'photoPath': userProfile.photoPath,
        'age': userProfile.age,
        'city': userProfile.city,
        'bio': userProfile.bio,
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _boxSub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _messages = HiveService.instance
          .chatHistory(widget.chatId)
          .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
          .toList();
    });
    _scrollToBottom();
    _markIncomingRead();
  }

  /// Отправляем собеседнику «прочитано» по всем его входящим сообщениям,
  /// которые ещё не помечены прочитанными (если отображение включено).
  void _markIncomingRead() {
    // Локально снимаем «не прочитано» (убираем зелёную точку в списке чатов).
    unawaited(HiveService.instance.markChatRead(widget.chatId));
    if (HiveService.instance.settings['show_receipts'] as bool? ?? true) {
      final ids = _messages
          .where((m) => !m.outbound && m.id.isNotEmpty)
          .map((m) => m.id)
          .toList();
      if (ids.isNotEmpty) {
        ChatRepository.instance.markIncomingRead(senderId: _peerId, msgIds: ids);
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    final peer = _peer;
    if (peer.publicKey.isEmpty) {
      if (mounted) showAppSnack(context, 'Нет ключа собеседника. Добавьте в контакты.', error: true);
      return;
    }
    setState(() => _sending = true);
    try {
      await ChatRepository.instance.sendMessage(_peer, text);
      _input.clear();
      _reload();
    } catch (_) {
      if (mounted) showAppSnack(context, S.chatFailed, error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _attach() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Картинка'),
              onTap: () => Navigator.pop(ctx, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Видеокружок'),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('Файл'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final peer = _peer;
    if (peer.publicKey.isEmpty) {
      if (mounted) showAppSnack(context, 'Нет ключа собеседника. Добавьте в контакты.', error: true);
      return;
    }
    try {
      if (action == 'image') {
        await _attachImage();
      } else if (action == 'video') {
        await _attachVideo();
      } else {
        await _attachFile();
      }
    } catch (e) {
      if (mounted) showAppSnack(context, 'Не удалось прикрепить файл', error: true);
    }
  }

  Future<void> _attachVideo() async {
    final path = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const VideoCircleScreen()),
    );
    if (path == null || !mounted) return;
    final peer = _peer;
    if (peer.publicKey.isEmpty) {
      if (mounted) showAppSnack(context, 'Нет ключа собеседника. Добавьте в контакты.', error: true);
      return;
    }
    final size = await File(path).length();
    if (size > 50 * 1024 * 1024) {
      if (mounted) showAppSnack(context, 'Видео больше 50 МБ', error: true);
      return;
    }
    try {
      final meta = await ApiClient.instance.uploadChatFile(
        path: path,
        filename: 'video_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );
      await ChatRepository.instance.sendFileMessage(peer, meta: meta);
      if (mounted) _reload();
    } catch (_) {
      if (mounted) showAppSnack(context, 'Не удалось отправить видео', error: true);
    }
  }

  Future<void> _attachImage() async {
    const typeGroup = XTypeGroup(label: 'images', extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif']);
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null || !mounted) return;
    final meta = await ApiClient.instance.uploadChatFile(
      path: file.path,
      filename: file.name,
    );
    await ChatRepository.instance.sendFileMessage(_peer, meta: meta);
    if (mounted) _reload();
  }

  Future<void> _attachFile() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    final size = await File(file.path).length();
    if (size > 50 * 1024 * 1024) {
      if (mounted) showAppSnack(context, 'Файл больше 50 МБ', error: true);
      return;
    }
    final meta = await ApiClient.instance.uploadChatFile(
      path: file.path,
      filename: file.name,
    );
    await ChatRepository.instance.sendFileMessage(_peer, meta: meta);
    if (mounted) _reload();
  }

  /// Запись голосового сообщения: тап «Записать» → запись, повторный тап —
  /// «Стоп и отправить». Файл уходит как аудио-вложение (m4a).
  Future<void> _recordVoice() async {
    final rec = VoiceRecorder.instance;
    if (rec.isRecording) {
      final path = await rec.stop();
      if (path == null || !mounted) {
        if (mounted) showAppSnack(context, 'Не удалось записать', error: true);
        return;
      }
      final size = await File(path).length();
      if (size < 512) {
        if (mounted) showAppSnack(context, 'Слишком короткое сообщение', error: true);
        return;
      }
      final peer = _peer;
      if (peer.publicKey.isEmpty) {
        if (mounted) showAppSnack(context, 'Нет ключа собеседника. Добавьте в контакты.', error: true);
        return;
      }
      try {
        final meta = await ApiClient.instance.uploadChatFile(
          path: path,
          filename: 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
        );
        await ChatRepository.instance.sendFileMessage(peer, meta: meta);
        if (mounted) _reload();
      } catch (_) {
        if (mounted) showAppSnack(context, 'Не удалось отправить голосовое', error: true);
      }
    } else {
      final ok = await rec.start();
      if (!ok) {
        if (mounted) showAppSnack(context, 'Нет доступа к микрофону', error: true);
        return;
      }
      if (mounted) showAppSnack(context, 'Идёт запись… нажмите ещё раз для отправки');
    }
  }

  Future<void> _schedule() async {
    final text = _input.text.trim();
    if (text.isEmpty) {
      showAppSnack(context, S.required, error: true);
      return;
    }
    final now = DateTime.now();
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (time == null) return;
    final at = DateTime(now.year, now.month, now.day, time.hour, time.minute);
    if (at.isBefore(now)) {
      showAppSnack(context, 'Время уже прошло', error: true);
      return;
    }
    await ChatRepository.instance.scheduleMessage(_peer, text, at);
    _input.clear();
    _reload();
    if (mounted) showAppSnack(context, S.chatScheduled);
  }

  Future<void> _showMessageActions(ChatMessage message) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.outbound)
              ListTile(
                leading: const Icon(Icons.schedule),
                title: const Text(S.chatScheduled),
                onTap: () => Navigator.pop(ctx, 'reschedule'),
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text(S.edit),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text(S.chatDeleteForMe),
              onTap: () => Navigator.pop(ctx, 'delete_me'),
            ),
            if (message.outbound)
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined),
                title: const Text(S.chatDeleteForAll),
                onTap: () => Navigator.pop(ctx, 'delete_all'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    switch (action) {
      case 'edit':
        _editMessage(message);
        break;
      case 'delete_me':
        await ChatRepository.instance.deleteForMe(widget.chatId, message.id);
        _reload();
        break;
      case 'delete_all':
        await ChatRepository.instance.deleteForAll(_peer, message.id);
        await HiveService.instance.deleteMessageLocal(widget.chatId, message.id);
        _reload();
        break;
      case 'reschedule':
        _schedule();
        break;
    }
  }

  Future<void> _editMessage(ChatMessage message) async {
    final controller = TextEditingController(text: message.payloadB64);
    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(S.edit),
        content: TextField(
          controller: controller,
          maxLines: 3,
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(S.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text(S.save),
          ),
        ],
      ),
    );
    if (newText == null || newText.trim().isEmpty || newText == message.payloadB64) return;
    await ChatRepository.instance.editMessage(_peer, message.id, newText.trim());
    if (mounted) _reload();
  }

  Future<void> _startCall({required bool video}) async {
    final peer = _peer;
    final mic = await Permission.microphone.request();
    final cam = video ? await Permission.camera.request() : PermissionStatus.granted;
    if (!mic.isGranted || (video && !cam.isGranted)) {
      if (mounted) showAppSnack(context, 'Нет доступа к микрофону/камере', error: true);
      return;
    }
    try {
      final session = await CallService.instance.startCall(peer, video: video);
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CallScreen(session: session),
          ),
        );
      }
    } catch (e) {
      if (mounted) showAppSnack(context, 'Не удалось начать звонок', error: true);
    }
  }

@override
  Widget build(BuildContext context) {
    final peer = _peer;
    final isLoadingPeer = _peerProfile == null && _contact == null;
    final hasPublicKey = peer.publicKey.isNotEmpty;
    final contactCount = HiveService.instance.contactsList.length;
    final showOnline =
        HiveService.instance.settings['show_online_status'] as bool? ?? true;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            if (showOnline) OnlineAvatar(name: peer.title, size: 36, online: _peerProfile?.online),
            if (showOnline) const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(peer.title),
                  if (isLoadingPeer)
                    const Text(
                      'Загрузка профиля…',
                      style: TextStyle(fontSize: 11, color: Colors.orangeAccent),
                    )
                  else if (!hasPublicKey)
                    const Text(
                      'Нет ключа — добавьте в контакты',
                      style: TextStyle(fontSize: 11, color: Colors.redAccent),
                    )
                  else
                    Text(
                      _peerProfile?.online == true ? 'онлайн' : S.chatEncrypted,
                      style: TextStyle(
                        fontSize: 11,
                        color: _peerProfile?.online == true
                            ? const Color(0xFF4CAF50)
                            : AppColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: S.chatCallAudio,
            icon: const Icon(Icons.call_outlined),
            onPressed: () => _startCall(video: false),
          ),
          IconButton(
            tooltip: S.chatCallVideo,
            icon: const Icon(Icons.videocam_outlined),
            onPressed: () => _startCall(video: true),
          ),
          IconButton(
            icon: const Icon(Icons.bug_report),
            tooltip: 'Debug: контактов=$contactCount, peerKey=${_peer.publicKey.isNotEmpty}',
            onPressed: () {
              final info = 'Контактов: $contactCount\n'
                  'peerKey: ${peer.publicKey.isNotEmpty}\n'
                  'contact: ${_contact != null}\n'
                  'peerProfile: ${_peerProfile != null}\n'
                  'chatId: ${widget.chatId}\n'
                  'peerId: $_peerId';
              showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Отладка'),
                  content: SelectableText(info),
                  actions: [
                    TextButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: info));
                        Navigator.pop(ctx);
                      },
                      child: const Text('Скопировать'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Закрыть'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty && !isLoadingPeer
                ? const EmptyState(
                    icon: Icons.lock_outline,
                    title: 'Чат защищён',
                    hint: S.chatEncrypted,
                  )
                : _messages.isEmpty && isLoadingPeer
                    ? const Center(
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.greenAccent),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length,
                        itemBuilder: (context, i) => _MessageBubble(
                          message: _messages[i],
                          onLongPress: () => _showMessageActions(_messages[i]),
                        ),
                      ),
          ),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Прикрепить',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: _attach,
            ),
            IconButton(
              tooltip: S.chatScheduleAt,
              icon: const Icon(Icons.schedule_send_outlined),
              onPressed: _schedule,
            ),
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 5,
                decoration: const InputDecoration(hintText: S.chatInputHint),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Голосовое сообщение',
              icon: Icon(
                VoiceRecorder.instance.isRecording
                    ? Icons.stop_circle_outlined
                    : Icons.mic_none,
              ),
              onPressed: _recordVoice,
            ),
            IconButton.filled(
              onPressed: _send,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback onLongPress;

  const _MessageBubble({required this.message, required this.onLongPress});

  static String _statusLabel(String status) {
    switch (status) {
      case 'delivered':
        return 'Получено';
      case 'read':
        return 'Прочитано';
      default:
        return 'Отправлено';
    }
  }

  @override
  Widget build(BuildContext context) {
    final outbound = message.outbound;
    final text = message.payloadB64;
    return Align(
      alignment: outbound ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: message.deleted ? null : onLongPress,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
          decoration: BoxDecoration(
            color: outbound ? AppColors.accent.withValues(alpha: 0.25) : AppColors.surfaceAlt,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(outbound ? 16 : 4),
              bottomRight: Radius.circular(outbound ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.deleted)
                Text(
                  S.chatMessageDeleted,
                  style: const TextStyle(color: AppColors.textSecondary, fontStyle: FontStyle.italic),
                )
              else ...[
                if (message.attachment != null)
                  AttachmentView(message: message),
                if (message.attachment == null && text.isNotEmpty)
                  Text(text),
                if (message.attachment != null && text.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(text, style: const TextStyle(fontSize: 13)),
                  ),
              ],
              if (message.editedAt != null)
                const Text(
                  S.chatEditMark,
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
              if (message.status == 'scheduled')
                const Text(
                  '⏰',
                  style: TextStyle(fontSize: 12),
                ),
              if (outbound && message.status != 'scheduled')
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _statusLabel(message.status),
                    style: TextStyle(
                      fontSize: 10,
                      color: message.status == 'read'
                          ? AppColors.accent
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Вложение в сообщении: картинка отображается развёрнутой, файл — карточкой.
/// Скачивание ВСЕГДА по явному согласию получателя (тап → «Скачать файл?»).
class AttachmentView extends ConsumerStatefulWidget {
  final ChatMessage message;

  const AttachmentView({super.key, required this.message});

  @override
  ConsumerState<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends ConsumerState<AttachmentView> {
  bool _downloading = false;
  double _progress = 0;

  ChatAttachment get att => widget.message.attachment!;

  String get _fileUrl => ApiClient.instance.photoUrl(att.url);

  @override
  Widget build(BuildContext context) {
    final mime = att.mime;
    if (mime.startsWith('audio/') || att.name.toLowerCase().endsWith('.m4a') ||
        att.name.toLowerCase().endsWith('.mp3') || att.name.toLowerCase().endsWith('.ogg')) {
      return _AudioAttachment(url: _fileUrl, filename: att.name);
    }
    if (mime.startsWith('video/') || att.name.toLowerCase().endsWith('.mp4')) {
      return _VideoCard(url: _fileUrl, name: att.name);
    }
    if (att.isImage) {
      return _ImageAttachment(url: _fileUrl);
    }
    return _FileCard(
      name: att.name,
      size: att.size,
      downloading: _downloading,
      progress: _progress,
      onTap: _downloading ? null : _confirmDownload,
    );
  }

  Future<void> _confirmDownload() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Скачать файл?'),
        content: Text(
          '${att.name}\n(${_fmtSize(att.size)})',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(S.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Скачать')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _downloading = true);
    try {
      final dir = await _downloadsDir();
      final target = File('${dir.path}/${_safeName(att.name)}');
      await ApiClient.instance.downloadFile(
        _fileUrl,
        target.path,
        onProgress: (received, total) {
          if (mounted && total > 0) {
            setState(() => _progress = received / total);
          }
        },
      );
      if (mounted) {
        setState(() => _downloading = false);
        showAppSnack(context, 'Файл сохранён в Загрузках');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _downloading = false);
        showAppSnack(context, 'Не удалось скачать файл', error: true);
      }
    }
  }

  /// Рабочее решение: папка «Загрузки» внутри хранилища приложения
  /// (видно через файловый менеджер: Android/data/<pkg>/files/Downloads).
  /// Позже, при проработке защиты, переведём на публичный MediaStore.
  Future<Directory> _downloadsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/Downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _safeName(String name) =>
      name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
    return '$bytes Б';
  }
}

class _AudioAttachment extends StatefulWidget {
  final String url;
  final String filename;

  const _AudioAttachment({required this.url, required this.filename});

  @override
  State<_AudioAttachment> createState() => _AudioAttachmentState();
}

class _AudioAttachmentState extends State<_AudioAttachment> {
  final _player = AudioPlayer();
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      if (mounted) setState(() => _playing = false);
    } else {
      try {
        await _player.setSourceUrl(widget.url, mimeType: 'audio/mp4');
        await _player.resume();
        if (mounted) setState(() => _playing = true);
      } catch (_) {
        if (mounted) {
          setState(() => _playing = false);
          showAppSnack(context, 'Не удалось воспроизвести', error: true);
        }
      }
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(_playing ? Icons.pause_circle_filled : Icons.play_circle_fill),
            color: AppColors.accent,
            iconSize: 36,
            onPressed: _toggle,
          ),
          Expanded(
            child: SizedBox(
              height: 28,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  LinearProgressIndicator(
                    value: _duration.inMilliseconds == 0
                        ? 0
                        : _position.inMilliseconds / _duration.inMilliseconds,
                  ),
                  Center(
                    child: Text(
                      '${_fmt(_position)} / ${_fmt(_duration)}',
                      style: const TextStyle(fontSize: 10, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageAttachment extends ConsumerWidget {
  final String url;

  const _ImageAttachment({required this.url});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              backgroundColor: Colors.black,
              appBar: AppBar(backgroundColor: Colors.black),
              body: Center(child: ServerImage(url)),
            ),
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ServerImage(
          url,
          width: 220,
          height: 220,
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _VideoCard extends StatelessWidget {
  final String url;
  final String name;

  const _VideoCard({required this.url, required this.name});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => VideoViewScreen(url: url),
          ),
        );
      },
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.textSecondary.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.play_circle_fill, color: AppColors.accent, size: 40),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Видео • нажмите для просмотра',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileCard extends StatelessWidget {
  final String name;
  final int size;
  final bool downloading;
  final double progress;
  final VoidCallback? onTap;

  const _FileCard({
    required this.name,
    required this.size,
    required this.downloading,
    required this.progress,
    this.onTap,
  });

  String get _ext => name.contains('.')
      ? name.split('.').last.toUpperCase()
      : 'FILE';

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.textSecondary.withValues(alpha: 0.3)),
        ),
        child: downloading
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 200,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(value: progress == 0 ? null : progress),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text('Скачивание…', style: TextStyle(fontSize: 12)),
                ],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _ext.length > 4 ? _ext.substring(0, 4) : _ext,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${(size / 1024).toStringAsFixed(0)} КБ • нажмите для скачивания',
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
