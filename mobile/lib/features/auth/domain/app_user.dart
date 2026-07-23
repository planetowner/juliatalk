final class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    required this.displayName,
    this.profileImageUrl,
    required this.preferredLanguage,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      username: json['username'] as String,
      displayName: json['display_name'] as String,
      profileImageUrl: json['profile_image_url'] as String?,
      preferredLanguage: json['preferred_language'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'username': username,
      'display_name': displayName,
      'profile_image_url': profileImageUrl,
      'preferred_language': preferredLanguage,
    };
  }

  final String id;
  final String username;
  final String displayName;
  final String? profileImageUrl;
  final String preferredLanguage;
}
