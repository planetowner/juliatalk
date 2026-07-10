enum ChatMessageAction { copy, reply, edit, unsend }

const Duration chatMessageUnsendWindow = Duration(minutes: 5);

List<ChatMessageAction> availableChatMessageActions({
  required bool isOutgoing,
  required DateTime createdAt,
  required DateTime now,
  bool isMedia = false,
  bool isCall = false,
}) {
  final bool canUseTextActions = !isMedia && !isCall;

  if (!isOutgoing) {
    return <ChatMessageAction>[
      if (canUseTextActions) ChatMessageAction.copy,
      ChatMessageAction.reply,
    ];
  }

  final Duration elapsedSinceCreation = now.difference(createdAt);

  final bool canUnsend =
      !isCall && elapsedSinceCreation <= chatMessageUnsendWindow;

  return <ChatMessageAction>[
    if (canUseTextActions) ChatMessageAction.copy,
    ChatMessageAction.reply,
    if (canUseTextActions) ChatMessageAction.edit,
    if (canUnsend) ChatMessageAction.unsend,
  ];
}
