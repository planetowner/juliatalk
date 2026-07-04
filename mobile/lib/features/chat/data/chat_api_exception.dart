final class ChatApiException implements Exception {
  const ChatApiException(this.message);

  final String message;

  @override
  String toString() {
    return message;
  }
}
