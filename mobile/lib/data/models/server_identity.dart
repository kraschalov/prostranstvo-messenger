class ServerIdentity {
  final String domain;
  final String name;
  final String scheme;
  final int? port;
  final bool active;
  final String? token;
  final String publicUrl;

  const ServerIdentity({
    required this.domain,
    required this.name,
    this.scheme = 'https',
    this.port,
    this.active = true,
    this.token,
    this.publicUrl = '',
  });

  String get baseUrl =>
      port == null ? '$scheme://$domain' : '$scheme://$domain:$port';

  String get wsUrl {
    final wsScheme = scheme == 'https' ? 'wss' : 'ws';
    return port == null ? '$wsScheme://$domain' : '$wsScheme://$domain:$port';
  }

  Map<String, dynamic> toJson() => {
        'domain': domain,
        'name': name,
        'scheme': scheme,
        'port': port,
        'active': active,
        'token': token,
        'publicUrl': publicUrl,
      };

  factory ServerIdentity.fromJson(Map<String, dynamic> json) => ServerIdentity(
        domain: json['domain'] as String,
        name: json['name'] as String? ?? '',
        scheme: json['scheme'] as String? ?? 'https',
        port: json['port'] as int?,
        active: json['active'] as bool? ?? true,
        token: json['token'] as String?,
        publicUrl: json['publicUrl'] as String? ?? '',
      );
}
