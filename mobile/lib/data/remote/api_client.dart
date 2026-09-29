import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:mesenger/data/local/secure/secure_store.dart';
import 'package:mesenger/data/models/server_identity.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  final bool banned;

  const ApiException(this.status, this.message, {this.banned = false});

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient._();

  static final ApiClient instance = ApiClient._();
  static const int _maxRetries = 3;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 60),
    sendTimeout: const Duration(seconds: 30),
    headers: {'Content-Type': 'application/json'},
  ));

  String _baseUrl = '';
  String? _token;
  String _boundDomain = '';
  String _publicUrl = '';

  /// Базовый URL текущего сервера (например http://192.168.10.216:5050).
  /// Нужен для построения полных URL загруженных файлов (фото профиля).
  String get baseUrl => _baseUrl;

  /// Полный URL загруженного файла из относительного пути (например
  /// /uploads/xxx.jpg): baseUrl сервера + путь. Используется для отображения
  /// аватаров/обложек в любом экране.
  String photoUrl(String path) {
    if (path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final base = baseUrl;
    if (base.isEmpty) return path;
    return '$base${path.startsWith('/') ? path : '/$path'}';
  }

  /// Скачивает изображение по относительному пути (например /uploads/x.jpg)
  /// через dio в байты. Это надёжнее Image.network: dio использует тот же
  /// стек, что и все API-запросы, и работает на любом Android, тогда как
  /// Image.network (dart:io) на Android 9+/HyperOS может блокировать http.
  Future<Uint8List> fetchImageBytes(String path) async {
    try {
      final res = await _dio.get<List<int>>(
        photoUrl(path),
        options: Options(
          headers: _headers,
          responseType: ResponseType.bytes,
        ),
      );
      return Uint8List.fromList(res.data ?? const []);
    } on DioException catch (e) {
      _handleError(e);
      throw ApiException(0, 'Ошибка загрузки изображения');
    }
  }

  void bind(ServerIdentity server) {
    _baseUrl = server.baseUrl;
    _token = server.token;
    _boundDomain = server.domain;
    _publicUrl = server.publicUrl;
    // Подтягиваем конфиг сервера (TURN, манифест обновлений, федерация).
    // Не ждём: кэш обновится фоново, геттеры отдают последнее известное.
    unawaited(refreshServerInfo());
  }

  /// Кэш /api/server_info. Пусто до первого успешного запроса.
  Map<String, dynamic>? _serverInfo;

  /// Обновить кэш конфига сервера. Ошибки гасим — клиент живёт на кэше/дефолтах.
  Future<void> refreshServerInfo() async {
    if (_baseUrl.isEmpty) return;
    try {
      final res = await _get('/api/server_info');
      _serverInfo = res;
      final pub = res['public_base_url']?.toString() ?? '';
      if (pub.isNotEmpty && pub != _publicUrl) {
        _publicUrl = pub;
        // Персистим, чтобы fallback жил после перезапуска.
        try {
          final servers = await SecureStore.instance.loadServers();
          var changed = false;
          final updated = servers.map((sv) {
            if (sv.domain == _boundDomain && sv.publicUrl != pub) {
              changed = true;
              return ServerIdentity(
                domain: sv.domain,
                name: sv.name,
                scheme: sv.scheme,
                port: sv.port,
                active: sv.active,
                token: sv.token,
                publicUrl: pub,
              );
            }
            return sv;
          }).toList();
          if (changed) await SecureStore.instance.saveServers(updated);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Второй адрес сервера (публичный) для фолбэка загрузок.
  String get _fallbackBase =>
      (_publicUrl.isNotEmpty && _publicUrl != _baseUrl) ? _publicUrl : '';

  Map<String, dynamic> get _turn =>
      (_serverInfo?['turn'] as Map?)?.cast<String, dynamic>() ?? const {};

  bool get turnEnabled => _turn['enabled'] as bool? ?? true;
  String get turnHost => _turn['host']?.toString() ?? '';
  int get turnPort => (_turn['port'] as num?)?.toInt() ?? 3478;
  String get turnUser => _turn['user']?.toString() ?? '';
  String get turnPass => _turn['pass']?.toString() ?? '';

  /// URL манифеста обновлений: публичный (GitHub Releases) либо пусто —
  /// тогда локальный /api/diag/update своего сервера.
  String get updateManifestUrl =>
      _serverInfo?['update_manifest_url']?.toString() ?? '';

  /// Визитка сервера из /api/server_info (имя/город/страна для карточки).
  String get serverName => _serverInfo?['name']?.toString() ?? '';
  String get serverCity => _serverInfo?['city']?.toString() ?? '';
  String get serverCountry => _serverInfo?['country']?.toString() ?? '';
  String get serverFederation =>
      _serverInfo?['federation_mode']?.toString() ?? '';

  Map<String, String> get _headers => {
        if (_token != null && _token!.isNotEmpty) 'Authorization': 'Bearer $_token',
        'X-Device-Fingerprint': SecureStore.instance.deviceId,
      };

  dynamic _handleError(DioException e) {
    final status = e.response?.statusCode ?? 0;
    final data = e.response?.data;
    debugPrint('DioError: type=${e.type} status=$status msg=${e.message} '
        'uri=${e.requestOptions.uri}');
    var detail = 'Нет соединения с сервером';
    if (data is Map) {
      detail = data['detail']?.toString() ?? detail;
    } else if (data is List) {
      // FastAPI validation errors: [{loc:[...], msg, type}]
      try {
        detail = data.map((d) {
          final m = d is Map ? d : const <String, dynamic>{};
          return '${m['loc']}: ${m['msg']}';
        }).join('; ');
      } catch (_) {}
    } else if (status == 0) {
      detail = 'Нет соединения с сервером';
    }
    debugPrint('DioError detail: $detail');
    if (status == 403 && detail.toLowerCase().contains('заблокировано')) {
      throw ApiException(status, detail, banned: true);
    }
    throw ApiException(status, detail);
  }

  /// Повтор запроса при сетевых ошибках и 5xx: внешние подключения через
  /// NAT/роутер иногда рвут простаивающее соединение — повтор решает это.
  Future<Map<String, dynamic>> _send(
    Future<Response> Function() request,
    int attempt,
  ) async {
    // Ленивая догрузка идентификатора устройства: если SecureStore.init()
    // не отработал при старте, запросы уходили бы без device_fingerprint.
    if (SecureStore.instance.deviceId.isEmpty) {
      try {
        await SecureStore.instance.init();
      } catch (_) {}
    }
    try {
      final r = await request();
      return Map<String, dynamic>.from(r.data as Map);
    } on DioException catch (e) {
      final status = e.response?.statusCode ?? 0;
      if ((status == 0 || status >= 500) && attempt < _maxRetries) {
        await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
        return _send(request, attempt + 1);
      }
      _handleError(e);
      throw ApiException(0, 'Ошибка запроса');
    }
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) {
    return _send(
      () => _dio.post('$_baseUrl$path', data: jsonEncode(body), options: Options(headers: _headers)),
      0,
    );
  }

  Future<Map<String, dynamic>> _get(String path, [Map<String, dynamic>? query]) {
    return _send(
      () => _dio.get('$_baseUrl$path', queryParameters: query, options: Options(headers: _headers)),
      0,
    );
  }

  Future<Map<String, dynamic>> _put(String path, Map<String, dynamic> body) {
    return _send(
      () => _dio.put('$_baseUrl$path', data: jsonEncode(body), options: Options(headers: _headers)),
      0,
    );
  }

  Future<Map<String, dynamic>> _delete(String path) {
    return _send(
      () => _dio.delete('$_baseUrl$path', options: Options(headers: _headers)),
      0,
    );
  }

  // ---- Auth ----
  Future<Map<String, dynamic>> validateInvite(String code) =>
      _post('/api/auth/invite/validate', {'code': code, 'device_fingerprint': SecureStore.instance.deviceId});

  Future<Map<String, dynamic>> login() =>
      _post('/api/auth/login', {'device_fingerprint': SecureStore.instance.deviceId});

  Future<Map<String, dynamic>> recover(String recoveryCode) =>
      _post('/api/auth/recover', {
        'code': recoveryCode,
        'device_fingerprint': SecureStore.instance.deviceId,
      });

  // ---- Профиль ----
  Future<Map<String, dynamic>> fetchMe() => _get('/api/profile/me');

  Future<Map<String, dynamic>> fetchProfileById(int userId) =>
      _get('/api/profile/$userId');

  Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> fields) =>
      _put('/api/profile/me', fields);

  // ---- Загрузка изображений профиля ----
  Future<Map<String, dynamic>> uploadAvatar(Uint8List bytes) =>
      _uploadBytes('/api/upload/avatar', 'file', bytes);

  Future<Map<String, dynamic>> uploadCover(Uint8List bytes) =>
      _uploadBytes('/api/upload/cover', 'file', bytes);

  /// Загрузка вложения для сообщения чата. Лимит 50 МБ: большее
  /// роняет приложение по памяти на слабых устройствах (проверено
  /// крашем на 111МБ). Для больших файлов — только через обновления.
  static const int maxChatFileBytes = 50 * 1024 * 1024;

  Future<Map<String, dynamic>> uploadChatFile({
    required String path,
    required String filename,
  }) async {
    try {
      final size = await File(path).length();
      if (size > maxChatFileBytes) {
        throw ApiException(
            0, 'Файл слишком большой (максимум 50 МБ для чата)');
      }
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(
          path,
          filename: filename,
        ),
      });
      final res = await _dio.post<Map<String, dynamic>>(
        '$_baseUrl/api/upload/chat',
        data: form,
        options: Options(headers: _headers),
      );
      return res.data ?? const {};
    } on DioException catch (e) {
      _handleError(e);
      throw ApiException(0, 'Ошибка загрузки файла');
    }
  }

  Future<Map<String, dynamic>> _uploadBytes(
    String path,
    String field,
    Uint8List bytes,
  ) async {
    try {
      // Отправляем байты, а не MultipartFile.fromFile: на Android 16
      // image_picker может вернуть content:// URI или путь, который
      // fromFile не может прочитать. Байты читает сам XFile.readAsBytes —
      // работает на любом устройстве.
      final form = FormData.fromMap({
        field: MultipartFile.fromBytes(
          bytes,
          filename: 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg',
          contentType: DioMediaType('image', 'jpeg'),
        ),
      });
      // НЕ задаём Content-Type вручную: dio сам поставит
      // multipart/form-data с boundary, иначе сервер не распарсит тело.
      final res = await _dio.post<Map<String, dynamic>>(
        '$_baseUrl$path',
        data: form,
        options: Options(headers: _headers),
      );
      return res.data ?? const {};
    } on DioException catch (e) {
      _handleError(e);
      // _handleError всегда бросает ApiException.
      throw ApiException(0, 'Ошибка загрузки файла');
    }
  }

  // ---- Поиск ----
  Future<Map<String, dynamic>> searchByUsername(String q) =>
      _get('/api/search/by_username', {'q': q});

  Future<Map<String, dynamic>> datingSearch(Map<String, dynamic> filters) =>
      _post('/api/search/dating', filters);

  // ---- Диагностика / обновление ----
  Future<Map<String, dynamic>> sendDiagLogs({
    required String device,
    required String version,
    required String logs,
    String comment = '',
  }) =>
      _post('/api/diag/logs', {
        'device': device,
        'version': version,
        'logs': logs,
        'comment': comment,
      });

  Future<Map<String, dynamic>> checkUpdate() async {
    final manifest = updateManifestUrl;
    if (manifest.isNotEmpty) {
      // Публичный манифест (GitHub Releases): тянем напрямую без auth.
      try {
        final res = await _dio.get<Map<String, dynamic>>(manifest);
        return res.data ?? const {};
      } catch (_) {
        return const {};
      }
    }
    try {
      return await _get('/api/diag/update');
    } catch (_) {
      // Мобильная сеть + LAN-адрес: пробуем публичный URL сервера.
      final fb = _fallbackBase;
      if (fb.isEmpty) rethrow;
      final res = await _dio.get<Map<String, dynamic>>(
        '$fb/api/diag/update',
        options: Options(headers: _headers),
      );
      return res.data ?? const {};
    }
  }

  /// Скачивает файл (например APK) по URL в локальный файл [destPath].
  /// Возвращает размер скачанного файла в байтах.
  /// Скачивание с докачкой (resume): мобильные сети рвут длинные
  /// соединения — качаем кусками через Range, пока не соберём целиком.
  /// При недоступности baseUrl пробуем публичный URL сервера.
  Future<int> downloadFile(
    String url,
    String destPath, {
    void Function(int received, int total)? onProgress,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    String effectiveUrl = url;
    final fb = _fallbackBase;
    final f = File(destPath);
    int total = 0;
    try {
      try {
        final h = await _dio.head(
          effectiveUrl,
          options: Options(headers: _headers, receiveTimeout: timeout),
        );
        total = int.tryParse(h.headers.value('content-length') ?? '') ?? 0;
      } catch (_) {
        if (fb.isNotEmpty && url.startsWith(_baseUrl)) {
          effectiveUrl = fb + url.substring(_baseUrl.length);
          final h = await _dio.head(
            effectiveUrl,
            options: Options(headers: _headers, receiveTimeout: timeout),
          );
          total = int.tryParse(h.headers.value('content-length') ?? '') ?? 0;
        }
      }
      for (var attempt = 1; attempt <= 8; attempt++) {
        final done = await f.exists() ? await f.length() : 0;
        if (total > 0 && done >= total) break;
        try {
          final res = await _dio.get<ResponseBody>(
            effectiveUrl,
            options: Options(
              headers: {
                ..._headers,
                if (done > 0) 'Range': 'bytes=$done-',
              },
              receiveTimeout: timeout,
              responseType: ResponseType.stream,
            ),
          );
          final partial = res.statusCode == 206;
          final sink = f.openWrite(
              mode: (partial && done > 0)
                  ? FileMode.append
                  : FileMode.write);
          var received = partial ? done : 0;
          await for (final chunk in res.data!.stream) {
            sink.add(chunk);
            received += (chunk as List<int>).length;
            onProgress?.call(received, total);
          }
          await sink.flush();
          await sink.close();
          if (total == 0) break;
        } catch (_) {
          await Future.delayed(const Duration(seconds: 2));
        }
      }
      try {
        return await f.length();
      } catch (_) {
        throw ApiException(0, 'Файл не скачался');
      }
    } on DioException catch (e) {
      _handleError(e);
      throw ApiException(0, 'Ошибка скачивания файла');
    }
  }

  // ---- Пространства ----
  Future<Map<String, dynamic>> listSpaces() => _get('/api/spaces');

  /// Только свои (владелец/участник). Для блока «Мои пространства».
  Future<Map<String, dynamic>> listMySpaces() => _get('/api/spaces/mine');

  /// Открытые (visible=1) для всех. Для блока «Открытые пространства».
  Future<Map<String, dynamic>> listOpenSpaces() => _get('/api/spaces/open');

  Future<Map<String, dynamic>> createSpace(String name, String description) =>
      _post('/api/spaces', {'name': name, 'description': description});

  Future<Map<String, dynamic>> updateSpace(
    int spaceId, {
    String? name,
    String? description,
  }) =>
      _put('/api/spaces/$spaceId', {
        if (name != null) 'name': name,
        if (description != null) 'description': description,
      });

  Future<Map<String, dynamic>> listSpaceMembers(int spaceId) =>
      _get('/api/spaces/$spaceId/members');

  Future<Map<String, dynamic>> addSpaceMember(int spaceId, String username) =>
      _post('/api/spaces/$spaceId/members', {'username': username});

  Future<Map<String, dynamic>> removeSpaceMember(int spaceId, int userId) =>
      _delete('/api/spaces/$spaceId/members/$userId');

  Future<Map<String, dynamic>> createInvite(int spaceId, String role) =>
      _post('/api/spaces/$spaceId/invites', {'role': role});

  /// Люди из всех пространств с включённой видимостью («Общее»).
  Future<Map<String, dynamic>> getCommonSpace() =>
      _get('/api/spaces/common');

  /// Настройки пространства: isolated — изоляция (создатель),
  /// visible — видимость пользователя в «Общем».
  Future<Map<String, dynamic>> setSpaceSettings(
    int spaceId, {
    bool? isolated,
    bool? visible,
  }) =>
      _put('/api/spaces/$spaceId/settings', {
        if (isolated != null) 'isolated': isolated,
        if (visible != null) 'visible': visible,
      });

  // ---- Апелляции ----
  Future<Map<String, dynamic>> submitAppeal(String message) => _post('/api/appeals', {
        'device_fingerprint': SecureStore.instance.deviceId,
        'message': message,
      });

  // ---- Администрирование (только владелец сервера) ----
  Future<Map<String, dynamic>> adminDashboard() => _get('/api/admin/dashboard');

  Future<Map<String, dynamic>> adminPeers() => _get('/api/admin/federation/peers');

  Future<Map<String, dynamic>> linkFederation(String domain) =>
      _post('/api/admin/federation/link', {'domain': domain});

  Future<Map<String, dynamic>> unlinkFederation(String domain) =>
      _post('/api/admin/federation/unlink', {'domain': domain});

  Future<Map<String, dynamic>> federationMode() =>
      _get('/api/admin/federation/mode');

  Future<Map<String, dynamic>> setFederationMode(String mode) =>
      _post('/api/admin/federation/mode', {'mode': mode});

  Future<Map<String, dynamic>> serverProfile() =>
      _get('/api/admin/server/profile');

  Future<Map<String, dynamic>> setServerProfile(
          {String? name, String? city, String? country}) =>
      _post('/api/admin/server/profile', {
        if (name != null) 'name': name,
        if (city != null) 'city': city,
        if (country != null) 'country': country,
      });

  Future<Map<String, dynamic>> updatesStatus() =>
      _get('/api/admin/updates/status');

  Future<Map<String, dynamic>> updatesPull() =>
      _post('/api/admin/updates/pull', {});

  /// Каталог серверов со своего сервера (не ходим на GitHub с телефона).
  Future<Map<String, dynamic>> serversDirectory() =>
      _get('/api/servers/directory');

  // ---- Темы (групповые комнаты) ----
  Future<Map<String, dynamic>> topicsMine() => _get('/api/topics');

  Future<Map<String, dynamic>> topicsOpen() => _get('/api/topics/open');

  Future<Map<String, dynamic>> createTopic(Map<String, dynamic> body) =>
      _post('/api/topics', body);

  Future<Map<String, dynamic>> getTopic(int id) => _get('/api/topics/$id');

  Future<Map<String, dynamic>> updateTopic(int id, Map<String, dynamic> body) =>
      _put('/api/topics/$id', body);

  Future<Map<String, dynamic>> topicMembers(int id) =>
      _get('/api/topics/$id/members');

  Future<Map<String, dynamic>> inviteTopicMember(int id, String username) =>
      _post('/api/topics/$id/members', {'username': username});

  Future<Map<String, dynamic>> setTopicRights(
          int id, int uid, Map<String, dynamic> body) =>
      _post('/api/topics/$id/members/$uid', body);

  Future<Map<String, dynamic>> kickTopicMember(int id, int uid) =>
      _delete('/api/topics/$id/members/$uid');

  Future<Map<String, dynamic>> leaveTopic(int id) =>
      _post('/api/topics/$id/leave', {});

  Future<Map<String, dynamic>> joinTopic(int id) =>
      _post('/api/topics/$id/join', {});

  // ---- HTTP-фолбэк реального времени (когда режут WebSocket) ----
  Future<Map<String, dynamic>> syncPull() => _post('/api/sync/pull', {});

  Future<Map<String, dynamic>> syncSend(Map<String, dynamic> event) =>
      _post('/api/sync/send', {'event': event});

  Future<Map<String, dynamic>> adminBlacklist() => _get('/api/admin/blacklist');

  Future<Map<String, dynamic>> adminAppeals() =>
      _get('/api/admin/appeals', {'status': 'pending'});

  Future<Map<String, dynamic>> banDevice(String fingerprint, String reason) =>
      _post('/api/admin/ban', {'device_fingerprint': fingerprint, 'reason': reason});
}
