final class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.preferredLanguage,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      username: json['username'] as String,
      displayName: json['display_name'] as String,
      preferredLanguage: json['preferred_language'] as String,
    );
  }

  final String id;
  final String username;
  final String displayName;
  final String preferredLanguage;
}
