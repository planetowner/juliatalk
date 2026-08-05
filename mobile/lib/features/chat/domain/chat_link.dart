final RegExp chatUrlPattern = RegExp(
  r'''(?:(?:https?):\/\/|www\.)[^\s<>'"]+''',
  caseSensitive: false,
);

const String chatTrailingUrlPunctuation = '.,!?;:)]}…';

String? firstChatUrlInText(String content) {
  final RegExpMatch? match = chatUrlPattern.firstMatch(content);
  if (match == null) {
    return null;
  }

  String url = match.group(0)!.trimRight();
  while (url.isNotEmpty &&
      chatTrailingUrlPunctuation.contains(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }

  return url.toLowerCase().startsWith('www.') ? 'https://$url' : url;
}

String chatDomainForUrl(String url) {
  String domain = Uri.tryParse(url)?.host ?? '';
  if (domain.isEmpty) {
    return url;
  }

  if (domain.startsWith('www.')) {
    domain = domain.substring(4);
  }

  return domain;
}
