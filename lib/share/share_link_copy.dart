abstract final class ShareLinkCopy {
  /// A strategy link opens read-only for anyone, account or not; a folder
  /// link needs an account.
  static String dialogDescription(String targetType) => targetType == 'strategy'
      ? 'Anyone with a link can view this strategy, no account needed. '
          'Signing in joins it with the access you choose. Links stay active '
          'until you disable them.'
      : 'Links stay active until you disable them. Anyone who opens one '
          'joins this item with the access you choose.';

  static const disableTitle = 'Disable this link?';
  static const disableDescription =
      'Disabling this link prevents new people from joining and stops anyone '
      'viewing through it without an account. People who already joined keep '
      'their access.';
  static const disableAction = 'Disable link';
  static const disableFailure = 'Failed to disable share link.';

  static const disabledStatus = 'DISABLED';
  static const disabledTooltip = 'Link disabled';
  static const disableTooltip = 'Disable link';
}
