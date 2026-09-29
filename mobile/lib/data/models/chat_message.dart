class ChatAttachment {
  final String fileId;
  final String name;
  final int size;
  final String mime;
  final String url;

  const ChatAttachment({
    required this.fileId,
    required this.name,
    required this.size,
    required this.mime,
    required this.url,
  });

  bool get isImage =>
      mime.startsWith('image/') || name.toLowerCase().endsWith('.jpg') ||
      name.toLowerCase().endsWith('.jpeg') || name.toLowerCase().endsWith('.png') ||
      name.toLowerCase().endsWith('.webp') || name.toLowerCase().endsWith('.gif');

  Map<String, dynamic> toJson() => {
        'file_id': fileId,
        'name': name,
        'size': size,
        'mime': mime,
        'url': url,
      };

  factory ChatAttachment.fromJson(Map<String, dynamic> json) => ChatAttachment(
        fileId: json['file_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        mime: json['mime'] as String? ?? 'application/octet-stream',
        url: json['url'] as String? ?? '',
      );
}

class ChatMessage {
  final String id;
  final String chatId;
  final String? peerHandle;
  final String payloadB64;
  final int createdAt;
  final bool outbound;
  final String status;
  final String? editedAt;
  final bool deleted;
  final bool unread;
  final ChatAttachment? attachment;

  const ChatMessage({
    required this.id,
    required this.chatId,
    this.peerHandle,
    required this.payloadB64,
    required this.createdAt,
    required this.outbound,
    this.status = 'sent',
    this.editedAt,
    this.deleted = false,
    this.unread = false,
    this.attachment,
  });

  ChatMessage copyWith({bool? unread, String? status}) => ChatMessage(
        id: id,
        chatId: chatId,
        peerHandle: peerHandle,
        payloadB64: payloadB64,
        createdAt: createdAt,
        outbound: outbound,
        status: status ?? this.status,
        editedAt: editedAt,
        deleted: deleted,
        unread: unread ?? this.unread,
        attachment: attachment,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'chatId': chatId,
        'peerHandle': peerHandle,
        'payloadB64': payloadB64,
        'createdAt': createdAt,
        'outbound': outbound,
        'status': status,
        'editedAt': editedAt,
        'deleted': deleted,
        'unread': unread,
        if (attachment != null) 'attachment': attachment!.toJson(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        chatId: json['chatId'] as String,
        peerHandle: json['peerHandle'] as String?,
        payloadB64: json['payloadB64'] as String? ?? '',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        outbound: json['outbound'] as bool? ?? false,
        status: json['status'] as String? ?? 'sent',
        editedAt: json['editedAt'] as String?,
        deleted: json['deleted'] as bool? ?? false,
        unread: json['unread'] as bool? ?? false,
        attachment: json['attachment'] is Map
            ? ChatAttachment.fromJson(
                Map<String, dynamic>.from(json['attachment'] as Map))
            : null,
      );
}
