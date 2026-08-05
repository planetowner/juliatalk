const List<String> _shortWeekdayNames = <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

const List<String> _weekdayNames = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const List<String> _monthNames = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String formatChatDate(DateTime date) {
  final DateTime localDate = date.toLocal();

  return '${chatWeekdayName(localDate.weekday)}, '
      '${chatMonthName(localDate.month)} '
      '${localDate.day}, '
      '${localDate.year}';
}

String formatChatScrollDate(DateTime date) {
  final DateTime localDate = date.toLocal();

  return '${_shortWeekdayNames[localDate.weekday - 1]}, '
      '${localDate.month}/${localDate.day}';
}

String chatWeekdayName(int weekday) => _weekdayNames[weekday - 1];

String chatMonthName(int month) => _monthNames[month - 1];
