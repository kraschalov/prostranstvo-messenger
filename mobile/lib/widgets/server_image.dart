import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mesenger/data/remote/api_client.dart';

/// Картинка с сервера, загружаемая через dio (ResponseType.bytes) и
/// показываемая через Image.memory.
///
/// ЗАЧЕМ: Flutter `Image.network` использует собственный dart:io HttpClient,
/// который на Android 9+/HyperOS может не грузить http-картинки (блокирует
/// cleartext на уровне платформы). dio работает на всех устройствах (им же
/// ходят все API-запросы), поэтому картинки грузим тем же путём — гарантия,
/// что фото отобразится там же, где работает само приложение.
class ServerImage extends StatefulWidget {
  final String path;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? errorBuilder;

  const ServerImage(
    this.path, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.errorBuilder,
  });

  @override
  State<ServerImage> createState() => _ServerImageState();
}

class _ServerImageState extends State<ServerImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ServerImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _bytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final bytes = await ApiClient.instance.fetchImageBytes(widget.path);
      if (!mounted) return;
      setState(() => _bytes = bytes);
    } catch (_) {
      if (mounted) setState(() => _bytes = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null || bytes.isEmpty) {
      return widget.errorBuilder ?? const SizedBox.shrink();
    }
    return Image.memory(
      bytes,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      errorBuilder: (_, __, ___) =>
          widget.errorBuilder ?? const SizedBox.shrink(),
    );
  }
}
