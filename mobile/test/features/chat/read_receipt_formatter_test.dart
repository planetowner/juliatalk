import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/presentation/read_receipt_formatter.dart';

void main() {
  final DateTime now = DateTime(2026, 6, 30, 12);

  test('shows just now for less than one minute', () {
    expect(
      formatReadReceipt(
        readAt: now.subtract(const Duration(seconds: 30)),
        now: now,
      ),
      'Seen just now',
    );
  });

  test('shows minutes for less than one hour', () {
    expect(
      formatReadReceipt(
        readAt: now.subtract(const Duration(minutes: 27)),
        now: now,
      ),
      'Seen 27m ago',
    );
  });

  test('shows hours for less than one day', () {
    expect(
      formatReadReceipt(
        readAt: now.subtract(const Duration(hours: 8)),
        now: now,
      ),
      'Seen 8h ago',
    );
  });

  test('shows yesterday for one to two days', () {
    expect(
      formatReadReceipt(
        readAt: now.subtract(const Duration(hours: 30)),
        now: now,
      ),
      'Seen yesterday',
    );
  });

  test('shows the weekday for two to six days', () {
    expect(
      formatReadReceipt(readAt: DateTime(2026, 6, 26, 12), now: now),
      'Seen Friday',
    );
  });

  test('shows last week for seven to thirteen days', () {
    expect(
      formatReadReceipt(
        readAt: now.subtract(const Duration(days: 9)),
        now: now,
      ),
      'Seen last week',
    );
  });

  test('shows only Seen for older receipts', () {
    expect(
      formatReadReceipt(
        readAt: now.subtract(const Duration(days: 20)),
        now: now,
      ),
      'Seen',
    );
  });
}
