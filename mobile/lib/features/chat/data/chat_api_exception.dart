final class ChatApiException implements Exception {
  const ChatApiException(
    this.message, {
    this.retryable = false,
    this.statusCode,
  });

  final String message;
  final bool retryable;
  final int? statusCode;

  @override
  String toString() {
    return message;
  }
}
