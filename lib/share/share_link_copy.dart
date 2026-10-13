abstract final class ShareLinkCopy {
  /// A strategy link opens read-only for anyone, account or not, where the
  /// link opens in a browser: links made in the web app point at it. Links
  /// made in the desktop app hand off to the app, which a recipient may not
  /// have, and a folder link needs an account; neither promises a view.
  static String dialogDescription(
    String targetType, {
    required bool opensInBrowser,
  }) =>
      targetType == 'strategy' && opensInBrowser
          ? 'Anyone with a link can view this strategy, no account needed. '
              'People who add it to their library show up here, and links '
              'stay active until you disable them.'
          : 'People who join through a link show up here, and links stay '
              'active until you disable them.';

  /// Shown under the link kind while "Can edit" is picked.
  static const editLinkWarning =
      'Anyone who gets this link can change it, including people it is '
      'forwarded to. Send it only to your team.';

  static const disableTitle = 'Disable this link?';
  static const disableDescription =
      'No one new can join or view through it. People who already joined '
      'keep their access unless you remove them.';
  static String removeJoinedLabel(int count, {bool more = false}) =>
      count == 1 && !more
          ? 'Also remove the person who joined through it'
          : 'Also remove the $count${more ? '+' : ''} people who joined '
              'through it';
  static const disableAction = 'Disable link';
  static const disableFailure = 'Failed to disable share link.';

  static const disabledStatus = 'Disabled';
  static const disabledTooltip = 'Link disabled';
  static const disableTooltip = 'Disable link';

  static String removeMemberTitle(String name) => 'Remove $name?';
  static const removeMemberDescription =
      'They lose access right away, and it leaves their Shared tab. If they '
      'still have an active link, they can join again until you disable it.';
  static const removeMemberAction = 'Remove';
  static const removeMemberFailure = "Couldn't remove them. Try again.";
  static const roleChangeFailure = "Couldn't change their access. Try again.";
}
