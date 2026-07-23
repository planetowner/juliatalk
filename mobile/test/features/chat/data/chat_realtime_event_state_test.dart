import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/data/chat_realtime_event_state.dart';

void main() {
  group('UnreadCountsSnapshot', () {
    test('parses a complete authoritative snapshot', () {
      final UnreadCountsSnapshot? snapshot = UnreadCountsSnapshot.tryParse(
        <String, dynamic>{
          'user_id': 'current-user',
          'stream_id': 'server-stream',
          'sequence': 12,
          'counts_by_sender_id': <String, int>{'lia': 2, 'yun': 3},
          'total_unread_count': 5,
        },
      );

      expect(snapshot, isNotNull);
      expect(snapshot!.userId, 'current-user');
      expect(snapshot.streamId, 'server-stream');
      expect(snapshot.sequence, 12);
      expect(snapshot.countsBySenderId, <String, int>{'lia': 2, 'yun': 3});
      expect(snapshot.totalUnreadCount, 5);
    });

    test('rejects a snapshot whose total does not match its sender counts', () {
      final UnreadCountsSnapshot? snapshot = UnreadCountsSnapshot.tryParse(
        <String, dynamic>{
          'user_id': 'current-user',
          'stream_id': 'server-stream',
          'sequence': 12,
          'counts_by_sender_id': <String, int>{'lia': 2},
          'total_unread_count': 3,
        },
      );

      expect(snapshot, isNull);
    });

    test('rejects malformed map keys without throwing', () {
      expect(
        () => UnreadCountsSnapshot.tryParse(<Object, Object>{1: 'invalid-key'}),
        returnsNormally,
      );
      expect(
        UnreadCountsSnapshot.tryParse(<Object, Object>{1: 'invalid-key'}),
        isNull,
      );
    });
  });

  group('RecentMessageIdCache', () {
    test('rejects duplicate IDs while they remain in the bounded cache', () {
      final RecentMessageIdCache cache = RecentMessageIdCache(capacity: 2);

      expect(cache.addIfAbsent('message-1'), isTrue);
      expect(cache.addIfAbsent('message-1'), isFalse);
      expect(cache.addIfAbsent('message-2'), isTrue);
      expect(cache.addIfAbsent('message-3'), isTrue);
      expect(cache.addIfAbsent('message-1'), isTrue);
    });
  });
}
