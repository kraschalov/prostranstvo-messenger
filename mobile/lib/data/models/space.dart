class Space {
  final int id;
  final String name;
  final String description;
  final int ownerId;
  final bool isolated;
  final bool visible;

  const Space({
    required this.id,
    required this.name,
    required this.description,
    required this.ownerId,
    this.isolated = false,
    this.visible = false,
  });

  factory Space.fromJson(Map<String, dynamic> json) => Space(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        ownerId: (json['owner_id'] as num?)?.toInt() ?? 0,
        isolated: json['isolated'] == 1 || json['isolated'] == true,
        visible: json['visible'] == 1 || json['visible'] == true,
      );
}

class DatingFilter {
  String? gender;
  int? ageMin;
  int? ageMax;
  String? city;
  List<String> tags;

  DatingFilter({
    this.gender,
    this.ageMin,
    this.ageMax,
    this.city,
    this.tags = const [],
  });

  Map<String, dynamic> toJson() => {
        'gender': gender,
        'age_min': ageMin,
        'age_max': ageMax,
        'city': city,
        'tags': tags,
      };
}
