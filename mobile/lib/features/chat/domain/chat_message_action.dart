enum ChatMessageAction { copy, reply, edit, unsend }

const Duration chatMessageUnsendWindow = Duration(minutes: 5);

List<ChatMessageAction> availableChatMessageActions({
  required bool isOutgoing,
  required DateTime createdAt,
  required DateTime now,
  bool isMedia = false,
}) {
  if (!isOutgoing) {
    return <ChatMessageAction>[
      if (!isMedia) ChatMessageAction.copy,
      ChatMessageAction.reply,
    ];
  }

  final Duration elapsedSinceCreation = now.difference(createdAt);

  final bool canUnsend =
      !elapsedSinceCreation.isNegative &&
      elapsedSinceCreation <= chatMessageUnsendWindow;

  return <ChatMessageAction>[
    if (!isMedia) ChatMessageAction.copy,
    ChatMessageAction.reply,
    if (!isMedia) ChatMessageAction.edit,
    if (canUnsend) ChatMessageAction.unsend,
  ];
}
