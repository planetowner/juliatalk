import 'dart:collection';

final class UnreadCountsSnapshot {
  const UnreadCountsSnapshot({
    required this.userId,
    required this.streamId,
    required this.sequence,
    required this.countsBySenderId,
    required this.totalUnreadCount,
  });

  static UnreadCountsSnapshot? tryParse(Object? rawSnapshot) {
    if (rawSnapshot is! Map) {
      return null;
    }

    final Map<dynamic, dynamic> snapshot = Map<dynamic, dynamic>.from(
      rawSnapshot,
    );
    final Object? rawUserId = snapshot['user_id'];
    final Object? rawStreamId = snapshot['stream_id'];
    final Object? rawSequence = snapshot['sequence'];
    final Object? rawCounts = snapshot['counts_by_sender_id'];
    final Object? rawTotal = snapshot['total_unread_count'];

    if (rawUserId is! String ||
        rawUserId.isEmpty ||
        rawStreamId is! String ||
        rawStreamId.isEmpty ||
        rawSequence is! int ||
        rawSequence <= 0 ||
        rawCounts is! Map ||
        rawTotal is! int ||
        rawTotal < 0) {
      return null;
    }

    final Map<String, int> countsBySenderId = <String, int>{};

    for (final MapEntry<dynamic, dynamic> entry in rawCounts.entries) {
      final dynamic senderId = entry.key;
      final dynamic unreadCount = entry.value;

      if (senderId is! String ||
          senderId.isEmpty ||
          unreadCount is! int ||
          unreadCount < 0) {
        return null;
      }

      if (unreadCount > 0) {
        countsBySenderId[senderId] = unreadCount;
      }
    }

    final int calculatedTotal = countsBySenderId.values.fold<int>(
      0,
      (int total, int count) => total + count,
    );
    if (calculatedTotal != rawTotal) {
      return null;
    }

    return UnreadCountsSnapshot(
      userId: rawUserId,
      streamId: rawStreamId,
      sequence: rawSequence,
      countsBySenderId: Map<String, int>.unmodifiable(countsBySenderId),
      totalUnreadCount: rawTotal,
    );
  }

  final String userId;
  final String streamId;
  final int sequence;
  final Map<String, int> countsBySenderId;
  final int totalUnreadCount;
}

final class RecentMessageIdCache {
  RecentMessageIdCache({this.capacity = 512}) : assert(capacity > 0);

  final int capacity;
  final Set<String> _ids = <String>{};
  final ListQueue<String> _insertionOrder = ListQueue<String>();

  bool addIfAbsent(String messageId) {
    if (!_ids.add(messageId)) {
      return false;
    }

    _insertionOrder.addLast(messageId);

    while (_insertionOrder.length > capacity) {
      _ids.remove(_insertionOrder.removeFirst());
    }

    return true;
  }
}
