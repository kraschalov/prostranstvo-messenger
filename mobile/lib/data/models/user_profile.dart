class UserProfile {
  final int id;
  final String username;
  final String handle;
  final String displayName;
  final String gender;
  final int age;
  final String city;
  final String goal;
  final List<String> interests;
  final String bio;
  final String photoPath;
  final String coverPath;
  final String role;
  final String publicKey;
  final String server;
  final bool online;
  final bool datingSwitch;
  final bool federatedSearch;
  final bool crossServerMessages;

  const UserProfile({
    required this.id,
    required this.username,
    required this.handle,
    required this.displayName,
    required this.gender,
    required this.age,
    required this.city,
    required this.goal,
    required this.interests,
    required this.bio,
    required this.photoPath,
    required this.coverPath,
    required this.role,
    required this.publicKey,
    required this.server,
    required this.online,
    this.datingSwitch = false,
    this.federatedSearch = true,
    this.crossServerMessages = true,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        id: (json['id'] as num?)?.toInt() ?? 0,
        username: json['username'] as String? ?? '',
        handle: json['handle'] as String? ?? '',
        displayName: json['display_name'] as String? ?? '',
        gender: json['gender'] as String? ?? 'unknown',
        age: (json['age'] as num?)?.toInt() ?? 0,
        city: json['city'] as String? ?? '',
        goal: json['goal'] as String? ?? '',
        interests: (json['interests'] as List?)?.cast<String>() ?? const [],
        bio: json['bio'] as String? ?? '',
        photoPath: json['photo_path'] as String? ?? '',
        coverPath: json['cover_path'] as String? ?? '',
        role: json['role'] as String? ?? 'STANDARD_USER',
        publicKey: json['public_key'] as String? ?? '',
        server: json['server'] as String? ?? '',
        online: json['online'] as bool? ?? false,
        datingSwitch: json['dating_switch'] as bool? ?? false,
        federatedSearch: json['federated_search'] as bool? ?? true,
        crossServerMessages: json['cross_server_messages'] as bool? ?? true,
      );

  String get title => displayName.isNotEmpty ? displayName : username;
  bool get isFamilyOrAdmin =>
      role == 'FAMILY_MEMBER' || role == 'SUPER_ADMIN';
  bool get isAdmin => role == 'SUPER_ADMIN';
}
