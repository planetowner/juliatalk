import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/chat_message.dart';
import 'chat_api.dart';

typedef ChatCacheDirectoryLoader = Future<Directory> Function();

final class ChatCachedConversation {
  ChatCachedConversation({
    required List<ChatMessage> messages,
    required this.hasMoreOlder,
    this.hasMoreNewer = false,
  }) : messages = List<ChatMessage>.unmodifiable(messages);

  final List<ChatMessage> messages;
  final bool hasMoreOlder;
  final bool hasMoreNewer;
}

final class ChatMessageCache {
  ChatMessageCache({
    required ChatApi chatApi,
    required String currentUserId,
    ChatCacheDirectoryLoader? directoryLoader,
    bool persistenceEnabled = true,
  }) : _chatApi = chatApi,
       _currentUserId = currentUserId,
       _directoryLoader = directoryLoader ?? getApplicationSupportDirectory,
       _persistenceEnabled = persistenceEnabled;

  static const int _formatVersion = 2;

  final ChatApi _chatApi;
  final String _currentUserId;
  final ChatCacheDirectoryLoader _directoryLoader;
  final bool _persistenceEnabled;
  final Map<String, _ChatMessageCacheEntry> _entries =
      <String, _ChatMessageCacheEntry>{};
  final Map<String, Future<_ChatMessageCacheEntry>> _entryLoads =
      <String, Future<_ChatMessageCacheEntry>>{};

  Future<ChatCachedConversation> readConversation(String otherUserId) async {
    final _ChatMessageCacheEntry entry = await _loadEntry(otherUserId);
    final _ChatMessageCacheSegment? segment = _latestSegment(entry);

    if (segment == null) {
      return ChatCachedConversation(
        messages: const <ChatMessage>[],
        hasMoreOlder: false,
      );
    }

    return _segmentSnapshot(entry, segment);
  }

  Future<ChatCachedConversation?> readConversationAround({
    required String otherUserId,
    required String messageId,
    required int olderLimit,
    required int newerLimit,
  }) async {
    final _ChatMessageCacheEntry entry = await _loadEntry(otherUserId);
    final _ChatMessageCacheSegment? segment = _segmentContaining(
      entry,
      messageId,
    );

    if (segment == null) {
      return null;
    }

    final int targetIndex = segment.messageIds.indexOf(messageId);
    final int startIndex = targetIndex > olderLimit
        ? targetIndex - olderLimit
        : 0;
    final int unclampedEndIndex = targetIndex + newerLimit + 1;
    final int endIndex = unclampedEndIndex < segment.messageIds.length
        ? unclampedEndIndex
        : segment.messageIds.length;

    return ChatCachedConversation(
      messages: _messagesForIds(
        entry,
        segment.messageIds.sublist(startIndex, endIndex),
      ),
      hasMoreOlder: startIndex > 0 || segment.hasMoreOlder,
      hasMoreNewer:
          endIndex < segment.messageIds.length || segment.hasMoreNewer,
    );
  }

  Future<ChatCachedConversation?> readMessagesBefore({
    required String otherUserId,
    required String beforeMessageId,
    required int limit,
  }) async {
    final _ChatMessageCacheEntry entry = await _loadEntry(otherUserId);
    final _ChatMessageCacheSegment? segment = _segmentContaining(
      entry,
      beforeMessageId,
    );

    if (segment == null) {
      return null;
    }

    final int beforeIndex = segment.messageIds.indexOf(beforeMessageId);

    if (beforeIndex <= 0) {
      return null;
    }

    final int startIndex = beforeIndex > limit ? beforeIndex - limit : 0;
    return ChatCachedConversation(
      messages: _messagesForIds(
        entry,
        segment.messageIds.sublist(startIndex, beforeIndex),
      ),
      hasMoreOlder: startIndex > 0 || segment.hasMoreOlder,
      hasMoreNewer: true,
    );
  }

  Future<ChatCachedConversation?> readMessagesAfter({
    required String otherUserId,
    required String afterMessageId,
    required int limit,
  }) async {
    final _ChatMessageCacheEntry entry = await _loadEntry(otherUserId);
    final _ChatMessageCacheSegment? segment = _segmentContaining(
      entry,
      afterMessageId,
    );

    if (segment == null) {
      return null;
    }

    final int afterIndex = segment.messageIds.indexOf(afterMessageId);
    final int startIndex = afterIndex + 1;

    if (startIndex >= segment.messageIds.length) {
      return null;
    }

    final int unclampedEndIndex = startIndex + limit;
    final int endIndex = unclampedEndIndex < segment.messageIds.length
        ? unclampedEndIndex
        : segment.messageIds.length;

    return ChatCachedConversation(
      messages: _messagesForIds(
        entry,
        segment.messageIds.sublist(startIndex, endIndex),
      ),
      hasMoreOlder: true,
      hasMoreNewer:
          endIndex < segment.messageIds.length || segment.hasMoreNewer,
    );
  }

  Future<void> mergeLatestConversation({
    required String otherUserId,
    required Iterable<ChatMessage> messages,
    required bool hasMoreOlder,
  }) {
    return _mergeWindow(
      otherUserId: otherUserId,
      messages: messages,
      hasMoreOlder: hasMoreOlder,
      hasMoreNewer: false,
    );
  }

  Future<void> mergeConversationContext({
    required String otherUserId,
    required Iterable<ChatMessage> messages,
    required bool hasMoreOlder,
    required bool hasMoreNewer,
  }) {
    return _mergeWindow(
      otherUserId: otherUserId,
      messages: messages,
      hasMoreOlder: hasMoreOlder,
      hasMoreNewer: hasMoreNewer,
    );
  }

  Future<void> mergeOlderPage({
    required String otherUserId,
    required String beforeMessageId,
    required Iterable<ChatMessage> messages,
    required bool hasMoreOlder,
  }) {
    return _mergeWindow(
      otherUserId: otherUserId,
      messages: messages,
      hasMoreOlder: hasMoreOlder,
      hasMoreNewer: true,
      connectsToMessageId: beforeMessageId,
    );
  }

  Future<void> mergeNewerPage({
    required String otherUserId,
    required String afterMessageId,
    required Iterable<ChatMessage> messages,
    required bool hasMoreNewer,
  }) {
    return _mergeWindow(
      otherUserId: otherUserId,
      messages: messages,
      hasMoreOlder: true,
      hasMoreNewer: hasMoreNewer,
      connectsToMessageId: afterMessageId,
    );
  }

  Future<void> updateOlderBoundary({
    required String otherUserId,
    required String boundaryMessageId,
    required bool hasMoreOlder,
  }) async {
    final _ChatMessageCacheEntry entry = await _loadEntry(otherUserId);
    final _ChatMessageCacheSegment? segment = _segmentContaining(
      entry,
      boundaryMessageId,
    );

    if (segment == null || segment.messageIds.first != boundaryMessageId) {
      return;
    }

    segment.hasMoreOlder = hasMoreOlder;
    await _scheduleWrite(otherUserId, entry);
  }

  Future<void> updateNewerBoundary({
    required String otherUserId,
    required String boundaryMessageId,
    required bool hasMoreNewer,
  }) async {
    final _ChatMessageCacheEntry entry = await _loadEntry(otherUserId);
    final _ChatMessageCacheSegment? segment = _segmentContaining(
      entry,
      boundaryMessageId,
    );

    if (segment == null || segment.messageIds.last != boundaryMessageId) {
      return;
    }

    segment.hasMoreNewer = hasMoreNewer;
    await _scheduleWrite(otherUserId, entry);
  }

  Future<void> removeMessage({
    required String otherUserId,
    required String messageId,
  }) async {
    final _ChatMessageCacheEntry entry = await _loadEntry(otherUserId);

    if (entry.messagesById.remove(messageId) == null) {
      return;
    }

    for (final _ChatMessageCacheSegment segment in entry.segments) {
      segment.messageIds.remove(messageId);
    }
    entry.segments.removeWhere(
      (_ChatMessageCacheSegment segment) => segment.messageIds.isEmpty,
    );
    await _scheduleWrite(otherUserId, entry);
  }

  Future<void> _mergeWindow({
    required String otherUserId,
    required Iterable<ChatMessage> messages,
    required bool hasMoreOlder,
    required bool hasMoreNewer,
    String? connectsToMessageId,
  }) async {
    final List<ChatMessage> incomingMessages =
        messages.where(_isPersistableServerMessage).toList(growable: false)
          ..sort(_compareMessages);

    if (incomingMessages.isEmpty) {
      return;
    }

    final _ChatMessageCacheEntry entry = await _loadEntry(otherUserId);

    for (final ChatMessage message in incomingMessages) {
      entry.messagesById[message.id] = message;
    }

    final Set<String> incomingIds = incomingMessages
        .map((ChatMessage message) => message.id)
        .toSet();
    final List<_ChatMessageCacheSegment> connectedSegments = entry.segments
        .where(
          (_ChatMessageCacheSegment segment) =>
              segment.messageIds.any(incomingIds.contains) ||
              (connectsToMessageId != null &&
                  segment.messageIds.contains(connectsToMessageId)),
        )
        .toList(growable: false);
    final Set<String> combinedIds = <String>{...incomingIds};

    for (final _ChatMessageCacheSegment segment in connectedSegments) {
      combinedIds.addAll(segment.messageIds);
    }

    final List<String> sortedCombinedIds = combinedIds.toList(growable: false)
      ..sort(
        (String firstId, String secondId) => _compareMessages(
          entry.messagesById[firstId]!,
          entry.messagesById[secondId]!,
        ),
      );
    final String combinedOldestId = sortedCombinedIds.first;
    final String combinedNewestId = sortedCombinedIds.last;
    final bool incomingOwnsOldestBoundary =
        incomingMessages.first.id == combinedOldestId;
    final bool incomingOwnsNewestBoundary =
        incomingMessages.last.id == combinedNewestId;
    bool combinedHasMoreOlder = incomingOwnsOldestBoundary
        ? hasMoreOlder
        : true;
    bool combinedHasMoreNewer = incomingOwnsNewestBoundary
        ? hasMoreNewer
        : true;

    for (final _ChatMessageCacheSegment segment in connectedSegments) {
      if (!incomingOwnsOldestBoundary &&
          segment.messageIds.first == combinedOldestId) {
        combinedHasMoreOlder = segment.hasMoreOlder;
      }

      if (!incomingOwnsNewestBoundary &&
          segment.messageIds.last == combinedNewestId) {
        combinedHasMoreNewer = segment.hasMoreNewer;
      }
    }

    entry.segments.removeWhere(connectedSegments.contains);
    entry.segments.add(
      _ChatMessageCacheSegment(
        messageIds: sortedCombinedIds,
        hasMoreOlder: combinedHasMoreOlder,
        hasMoreNewer: combinedHasMoreNewer,
      ),
    );
    _sortSegments(entry);
    await _scheduleWrite(otherUserId, entry);
  }

  Future<_ChatMessageCacheEntry> _loadEntry(String otherUserId) {
    final _ChatMessageCacheEntry? cachedEntry = _entries[otherUserId];

    if (cachedEntry != null) {
      return Future<_ChatMessageCacheEntry>.value(cachedEntry);
    }

    if (!_persistenceEnabled) {
      final _ChatMessageCacheEntry entry = _ChatMessageCacheEntry();
      _entries[otherUserId] = entry;
      return Future<_ChatMessageCacheEntry>.value(entry);
    }

    return _entryLoads.putIfAbsent(otherUserId, () async {
      final _ChatMessageCacheEntry entry = await _readEntryFile(otherUserId);
      _entries[otherUserId] = entry;
      _entryLoads.remove(otherUserId);
      return entry;
    });
  }

  Future<_ChatMessageCacheEntry> _readEntryFile(String otherUserId) async {
    try {
      final File file = await _cacheFile(otherUserId);

      if (!await file.exists()) {
        return _ChatMessageCacheEntry();
      }

      final Object? decoded = jsonDecode(await file.readAsString());

      if (decoded is! Map<String, dynamic> ||
          decoded['messages'] is! List<dynamic>) {
        return _ChatMessageCacheEntry();
      }

      final Map<String, ChatMessage> messagesById = <String, ChatMessage>{};

      for (final Object? item in decoded['messages'] as List<dynamic>) {
        if (item is! Map<String, dynamic>) {
          continue;
        }

        try {
          final ChatMessage message = _chatApi.messageFromJson(item);

          if (_isPersistableServerMessage(message)) {
            messagesById[message.id] = message;
          }
        } catch (_) {
          // Ignore one stale record without discarding other cached ranges.
        }
      }

      final List<_ChatMessageCacheSegment> segments =
          <_ChatMessageCacheSegment>[];
      final Object? encodedSegments = decoded['segments'];

      if (decoded['version'] == _formatVersion &&
          encodedSegments is List<dynamic>) {
        for (final Object? item in encodedSegments) {
          if (item is! Map<String, dynamic> ||
              item['message_ids'] is! List<dynamic>) {
            continue;
          }

          final List<String> messageIds =
              (item['message_ids'] as List<dynamic>)
                  .whereType<String>()
                  .where(messagesById.containsKey)
                  .toSet()
                  .toList(growable: false)
                ..sort(
                  (String firstId, String secondId) => _compareMessages(
                    messagesById[firstId]!,
                    messagesById[secondId]!,
                  ),
                );

          if (messageIds.isEmpty) {
            continue;
          }

          segments.add(
            _ChatMessageCacheSegment(
              messageIds: messageIds,
              hasMoreOlder: item['has_more_older'] == true,
              hasMoreNewer: item['has_more_newer'] == true,
            ),
          );
        }
      } else if (messagesById.isNotEmpty) {
        final List<String> migratedMessageIds =
            messagesById.keys.toList(growable: false)..sort(
              (String firstId, String secondId) => _compareMessages(
                messagesById[firstId]!,
                messagesById[secondId]!,
              ),
            );
        segments.add(
          _ChatMessageCacheSegment(
            messageIds: migratedMessageIds,
            hasMoreOlder: decoded['has_more_older'] == true,
            hasMoreNewer: false,
          ),
        );
      }

      final _ChatMessageCacheEntry entry = _ChatMessageCacheEntry(
        messagesById: messagesById,
        segments: segments,
      );
      _coalesceOverlappingSegments(entry);
      _discardUnreferencedMessages(entry);
      return entry;
    } catch (_) {
      // Persistent storage is an optimization and must never block chat.
      return _ChatMessageCacheEntry();
    }
  }

  void _coalesceOverlappingSegments(_ChatMessageCacheEntry entry) {
    bool mergedSegment = true;

    while (mergedSegment) {
      mergedSegment = false;

      for (
        int firstIndex = 0;
        firstIndex < entry.segments.length;
        firstIndex++
      ) {
        final _ChatMessageCacheSegment first = entry.segments[firstIndex];
        final Set<String> firstIds = first.messageIds.toSet();

        for (
          int secondIndex = firstIndex + 1;
          secondIndex < entry.segments.length;
          secondIndex++
        ) {
          final _ChatMessageCacheSegment second = entry.segments[secondIndex];

          if (!second.messageIds.any(firstIds.contains)) {
            continue;
          }

          final Set<String> combinedIds = <String>{
            ...first.messageIds,
            ...second.messageIds,
          };
          final List<String> sortedIds = combinedIds.toList(growable: false)
            ..sort(
              (String firstId, String secondId) => _compareMessages(
                entry.messagesById[firstId]!,
                entry.messagesById[secondId]!,
              ),
            );
          final String oldestId = sortedIds.first;
          final String newestId = sortedIds.last;
          final bool hasMoreOlder = first.messageIds.first == oldestId
              ? first.hasMoreOlder
              : second.hasMoreOlder;
          final bool hasMoreNewer = first.messageIds.last == newestId
              ? first.hasMoreNewer
              : second.hasMoreNewer;
          entry.segments[firstIndex] = _ChatMessageCacheSegment(
            messageIds: sortedIds,
            hasMoreOlder: hasMoreOlder,
            hasMoreNewer: hasMoreNewer,
          );
          entry.segments.removeAt(secondIndex);
          mergedSegment = true;
          break;
        }

        if (mergedSegment) {
          break;
        }
      }
    }

    _sortSegments(entry);
  }

  void _discardUnreferencedMessages(_ChatMessageCacheEntry entry) {
    final Set<String> referencedIds = entry.segments
        .expand((_ChatMessageCacheSegment segment) => segment.messageIds)
        .toSet();
    entry.messagesById.removeWhere(
      (String messageId, ChatMessage _) => !referencedIds.contains(messageId),
    );
  }

  _ChatMessageCacheSegment? _latestSegment(_ChatMessageCacheEntry entry) {
    final List<_ChatMessageCacheSegment> newestEdgeSegments = entry.segments
        .where((_ChatMessageCacheSegment segment) => !segment.hasMoreNewer)
        .toList(growable: false);

    if (newestEdgeSegments.isEmpty) {
      return null;
    }

    return newestEdgeSegments.reduce(
      (_ChatMessageCacheSegment first, _ChatMessageCacheSegment second) =>
          _compareMessages(
                entry.messagesById[first.messageIds.last]!,
                entry.messagesById[second.messageIds.last]!,
              ) >=
              0
          ? first
          : second,
    );
  }

  _ChatMessageCacheSegment? _segmentContaining(
    _ChatMessageCacheEntry entry,
    String messageId,
  ) {
    for (final _ChatMessageCacheSegment segment in entry.segments) {
      if (segment.messageIds.contains(messageId)) {
        return segment;
      }
    }

    return null;
  }

  ChatCachedConversation _segmentSnapshot(
    _ChatMessageCacheEntry entry,
    _ChatMessageCacheSegment segment,
  ) {
    return ChatCachedConversation(
      messages: _messagesForIds(entry, segment.messageIds),
      hasMoreOlder: segment.hasMoreOlder,
      hasMoreNewer: segment.hasMoreNewer,
    );
  }

  List<ChatMessage> _messagesForIds(
    _ChatMessageCacheEntry entry,
    Iterable<String> messageIds,
  ) {
    return List<ChatMessage>.unmodifiable(
      messageIds.map((String messageId) => entry.messagesById[messageId]!),
    );
  }

  void _sortSegments(_ChatMessageCacheEntry entry) {
    entry.segments.sort(
      (_ChatMessageCacheSegment first, _ChatMessageCacheSegment second) =>
          _compareMessages(
            entry.messagesById[first.messageIds.first]!,
            entry.messagesById[second.messageIds.first]!,
          ),
    );
  }

  Future<void> _scheduleWrite(
    String otherUserId,
    _ChatMessageCacheEntry entry,
  ) {
    if (!_persistenceEnabled) {
      _discardUnreferencedMessages(entry);
      return Future<void>.value();
    }

    entry.writeRevision += 1;
    return entry.writeFuture ??= _drainWrites(otherUserId, entry);
  }

  Future<void> _drainWrites(
    String otherUserId,
    _ChatMessageCacheEntry entry,
  ) async {
    try {
      while (true) {
        final int writingRevision = entry.writeRevision;
        _discardUnreferencedMessages(entry);
        final List<ChatMessage> sortedMessages =
            entry.messagesById.values.toList(growable: false)
              ..sort(_compareMessages);
        final String encoded = jsonEncode(<String, Object?>{
          'version': _formatVersion,
          'messages': sortedMessages
              .map(_chatApi.messageToCacheJson)
              .toList(growable: false),
          'segments': entry.segments
              .map(
                (_ChatMessageCacheSegment segment) => <String, Object?>{
                  'message_ids': segment.messageIds,
                  'has_more_older': segment.hasMoreOlder,
                  'has_more_newer': segment.hasMoreNewer,
                },
              )
              .toList(growable: false),
        });
        final File file = await _cacheFile(otherUserId);
        await file.parent.create(recursive: true);
        await file.writeAsString(encoded, flush: true);

        if (writingRevision == entry.writeRevision) {
          break;
        }
      }
    } catch (_) {
      // Keep the in-memory ranges usable when persistent storage is unavailable.
    } finally {
      entry.writeFuture = null;
    }
  }

  Future<File> _cacheFile(String otherUserId) async {
    final Directory supportDirectory = await _directoryLoader();
    final String currentUserKey = _safeFileName(_currentUserId);
    final String otherUserKey = _safeFileName(otherUserId);
    return File(
      '${supportDirectory.path}/juliatalk/message-cache/'
      '$currentUserKey/$otherUserKey.json',
    );
  }

  String _safeFileName(String value) {
    return value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }

  bool _isPersistableServerMessage(ChatMessage message) {
    return _looksLikeUuid(message.id) &&
        _looksLikeUuid(message.senderId) &&
        _looksLikeUuid(message.recipientId);
  }

  bool _looksLikeUuid(String value) {
    return RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-'
      r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(value);
  }

  int _compareMessages(ChatMessage first, ChatMessage second) {
    final int createdAtComparison = first.createdAt.compareTo(second.createdAt);

    if (createdAtComparison != 0) {
      return createdAtComparison;
    }

    return first.id.compareTo(second.id);
  }
}

final class _ChatMessageCacheEntry {
  _ChatMessageCacheEntry({
    Map<String, ChatMessage>? messagesById,
    List<_ChatMessageCacheSegment>? segments,
  }) : messagesById = messagesById ?? <String, ChatMessage>{},
       segments = segments ?? <_ChatMessageCacheSegment>[];

  final Map<String, ChatMessage> messagesById;
  final List<_ChatMessageCacheSegment> segments;
  int writeRevision = 0;
  Future<void>? writeFuture;
}

final class _ChatMessageCacheSegment {
  _ChatMessageCacheSegment({
    required List<String> messageIds,
    required this.hasMoreOlder,
    required this.hasMoreNewer,
  }) : messageIds = List<String>.of(messageIds);

  final List<String> messageIds;
  bool hasMoreOlder;
  bool hasMoreNewer;
}
