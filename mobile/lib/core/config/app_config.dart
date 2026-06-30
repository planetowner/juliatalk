final class AppConfig {
  const AppConfig({required this.apiBaseUri});

  factory AppConfig.fromEnvironment() {
    const String apiBaseUrl = String.fromEnvironment('API_BASE_URL');

    if (apiBaseUrl.isEmpty) {
      throw StateError(
        'API_BASE_URL is required. '
        'Run Flutter with '
        '--dart-define=API_BASE_URL=http://your-server-address:8000',
      );
    }

    final Uri apiBaseUri = Uri.parse(apiBaseUrl);

    if (!apiBaseUri.hasScheme || apiBaseUri.host.isEmpty) {
      throw StateError('API_BASE_URL must be an absolute HTTP or HTTPS URL.');
    }

    return AppConfig(apiBaseUri: apiBaseUri);
  }

  final Uri apiBaseUri;
}
