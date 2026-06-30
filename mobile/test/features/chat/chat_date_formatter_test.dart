import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/presentation/chat_date_formatter.dart';

void main() {
  test('formats the date in English weekday month day year order', () {
    expect(formatChatDate(DateTime(2026, 6, 30)), 'Tuesday, June 30, 2026');
  });

  test('formats a single-digit day without a leading zero', () {
    expect(formatChatDate(DateTime(2026, 7, 4)), 'Saturday, July 4, 2026');
  });
}
