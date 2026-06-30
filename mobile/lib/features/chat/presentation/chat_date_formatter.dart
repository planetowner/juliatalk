String formatChatDate(DateTime date) {
  final DateTime localDate = date.toLocal();

  return '${_weekdayName(localDate.weekday)}, '
      '${_monthName(localDate.month)} '
      '${localDate.day}, '
      '${localDate.year}';
}

String _weekdayName(int weekday) {
  return switch (weekday) {
    DateTime.monday => 'Monday',
    DateTime.tuesday => 'Tuesday',
    DateTime.wednesday => 'Wednesday',
    DateTime.thursday => 'Thursday',
    DateTime.friday => 'Friday',
    DateTime.saturday => 'Saturday',
    DateTime.sunday => 'Sunday',
    _ => throw ArgumentError.value(
      weekday,
      'weekday',
      'Weekday must be between 1 and 7.',
    ),
  };
}

String _monthName(int month) {
  return switch (month) {
    DateTime.january => 'January',
    DateTime.february => 'February',
    DateTime.march => 'March',
    DateTime.april => 'April',
    DateTime.may => 'May',
    DateTime.june => 'June',
    DateTime.july => 'July',
    DateTime.august => 'August',
    DateTime.september => 'September',
    DateTime.october => 'October',
    DateTime.november => 'November',
    DateTime.december => 'December',
    _ => throw ArgumentError.value(
      month,
      'month',
      'Month must be between 1 and 12.',
    ),
  };
}
