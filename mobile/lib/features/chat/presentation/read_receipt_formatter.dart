import 'chat_date_formatter.dart';

String formatReadReceipt({required DateTime readAt, required DateTime now}) {
  final DateTime localReadAt = readAt.toLocal();
  final DateTime localNow = now.toLocal();

  Duration elapsed = localNow.difference(localReadAt);

  if (elapsed.isNegative) {
    elapsed = Duration.zero;
  }

  if (elapsed < const Duration(minutes: 1)) {
    return 'Seen just now';
  }

  if (elapsed < const Duration(hours: 1)) {
    return 'Seen ${elapsed.inMinutes}m ago';
  }

  if (elapsed < const Duration(days: 1)) {
    return 'Seen ${elapsed.inHours}h ago';
  }

  if (elapsed < const Duration(days: 2)) {
    return 'Seen yesterday';
  }

  if (elapsed < const Duration(days: 7)) {
    return 'Seen ${chatWeekdayName(localReadAt.weekday)}';
  }

  if (elapsed < const Duration(days: 14)) {
    return 'Seen last week';
  }

  return 'Seen';
}
