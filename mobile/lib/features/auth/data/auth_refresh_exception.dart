final class AuthRefreshException implements Exception {
  const AuthRefreshException(this.message, {required this.statusCode});

  final String message;
  final int statusCode;

  @override
  String toString() => message;
}
