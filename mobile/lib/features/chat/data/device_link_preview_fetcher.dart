import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../domain/chat_link.dart';

final class DeviceLinkPreviewFetcher {
  const DeviceLinkPreviewFetcher({required http.Client client})
    : _client = client;

  final http.Client _client;

  static const Duration _fetchTimeout = Duration(seconds: 4);
  static const int _maximumHtmlBytes = 2 * 1024 * 1024;
  static const String _userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
      'Safari/605.1.15';

  Future<Map<String, Object?>?> fetch(Uri uri) async {
    if (!_usesDeviceFallback(uri)) {
      return null;
    }

    try {
      return await _fetch(uri).timeout(_fetchTimeout);
    } catch (_) {
      // 미리 보기 실패는 메시지 전송을 막지 않고 서버의 기본 메타데이터에 맡겨요.
      return null;
    }
  }

  bool _usesDeviceFallback(Uri uri) {
    final String host = uri.host.toLowerCase();

    // fmkorea가 서버 스크래퍼를 제한할 때만 일반 브라우저인 기기에서 보완해요.
    return uri.isScheme('https') &&
        (host == 'fmkorea.com' || host.endsWith('.fmkorea.com'));
  }

  Future<Map<String, Object?>?> _fetch(Uri uri) async {
    final http.Request request = http.Request('GET', uri)
      ..headers.addAll(const <String, String>{
        'User-Agent': _userAgent,
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'ko-KR,ko;q=0.9',
      });
    final http.StreamedResponse response = await _client.send(request);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }

    final String contentType = response.headers['content-type'] ?? '';

    if (!contentType.toLowerCase().contains('html') &&
        !contentType.toLowerCase().contains('text')) {
      return null;
    }

    final Uint8List rawHtml = await _readHtmlHead(response.stream);

    if (rawHtml.isEmpty) {
      return null;
    }

    final Document document = html_parser.parse(
      _decodeHtml(rawHtml, contentType),
    );
    final Map<String, String> meta = <String, String>{};

    for (final Element element in document.querySelectorAll('meta')) {
      final String? key =
          element.attributes['property'] ?? element.attributes['name'];
      final String? content = element.attributes['content'];

      if (key != null && content != null) {
        meta[key.toLowerCase()] = content;
      }
    }

    final Uri fetchedUri = response.request?.url ?? uri;
    final String? canonicalReference = _cleanText(
      meta['og:url'],
      maximumLength: 1000,
    );
    final String canonicalUrl =
        _resolveHttpUrl(fetchedUri, canonicalReference) ??
        fetchedUri.toString();
    final String? title = _cleanText(
      meta['og:title'] ??
          meta['twitter:title'] ??
          document.querySelector('title')?.text,
      maximumLength: 180,
    );
    final String? description = _cleanText(
      meta['og:description'] ??
          meta['twitter:description'] ??
          meta['description'],
      maximumLength: 260,
    );
    final String? siteName = _cleanText(
      meta['og:site_name'],
      maximumLength: 120,
    );
    final String? imageReference = _cleanText(
      meta['og:image'] ?? meta['og:image:url'] ?? meta['twitter:image'],
      maximumLength: 1000,
    );
    final String? imageUrl = _resolveHttpUrl(fetchedUri, imageReference);

    if (title == null &&
        description == null &&
        siteName == null &&
        imageUrl == null) {
      return null;
    }

    return <String, Object?>{
      'url': uri.toString(),
      'canonical_url': canonicalUrl,
      'domain': chatDomainForUrl(uri.toString()).toLowerCase(),
      'title': ?title,
      'description': ?description,
      'site_name': ?siteName,
      'image_url': ?imageUrl,
    };
  }

  Future<Uint8List> _readHtmlHead(Stream<List<int>> stream) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    List<int> previousTail = <int>[];

    await for (final List<int> chunk in stream) {
      final int remainingBytes = _maximumHtmlBytes - builder.length;

      if (remainingBytes <= 0) {
        break;
      }

      final List<int> acceptedChunk = chunk.length <= remainingBytes
          ? chunk
          : chunk.sublist(0, remainingBytes);
      builder.add(acceptedChunk);

      final List<int> searchableBytes = <int>[
        ...previousTail,
        ...acceptedChunk,
      ];
      final String searchableText = latin1
          .decode(searchableBytes)
          .toLowerCase();

      if (searchableText.contains('</head')) {
        break;
      }

      final int tailStart = searchableBytes.length > 16
          ? searchableBytes.length - 16
          : 0;
      previousTail = searchableBytes.sublist(tailStart);
    }

    return builder.takeBytes();
  }

  String _decodeHtml(Uint8List bytes, String contentType) {
    final RegExpMatch? charsetMatch = RegExp(
      r'charset\s*=\s*([^;\s]+)',
      caseSensitive: false,
    ).firstMatch(contentType);
    final String? charset = charsetMatch
        ?.group(1)
        ?.replaceAll('"', '')
        .replaceAll("'", '');
    final Encoding encoding = Encoding.getByName(charset) ?? utf8;

    try {
      return encoding.decode(bytes);
    } on FormatException {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  String? _cleanText(String? value, {required int maximumLength}) {
    if (value == null) {
      return null;
    }

    final String normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (normalized.isEmpty) {
      return null;
    }

    if (normalized.length <= maximumLength) {
      return normalized;
    }

    return '${normalized.substring(0, maximumLength - 1).trimRight()}…';
  }

  String? _resolveHttpUrl(Uri baseUri, String? reference) {
    if (reference == null) {
      return null;
    }

    final Uri? referenceUri = Uri.tryParse(reference);

    if (referenceUri == null) {
      return null;
    }

    final Uri resolvedUri = baseUri.resolveUri(referenceUri);

    if (!resolvedUri.isScheme('http') && !resolvedUri.isScheme('https')) {
      return null;
    }

    return resolvedUri.toString();
  }
}
