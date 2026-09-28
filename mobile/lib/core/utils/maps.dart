/// Безопасное приведение к `Map<String, dynamic>`.
/// Hive и jsonDecode могут вернуть `Map<dynamic, dynamic>` / `_Map<dynamic, dynamic>`,
/// из-за чего прямое `as Map<String, dynamic>` падает в рантайме.
Map<String, dynamic>? asStringMap(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return null;
}
