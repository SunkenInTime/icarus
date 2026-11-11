import 'package:icarus/l10n/l10n.dart';

abstract final class ShareLinkCopy {
  /// A strategy link opens read-only for anyone, account or not, where the
  /// link opens in a browser: links made in the web app point at it. Links
  /// made in the desktop app hand off to the app, which a recipient may not
  /// have, and a folder link needs an account; neither promises a view.
  static String dialogDescription(
    AppLocalizations l10n,
    String targetType, {
    required bool opensInBrowser,
  }) =>
      targetType == 'strategy' && opensInBrowser
          ? l10n.shareLinkCopyDescriptionBrowserStrategy
          : l10n.shareLinkCopyDescription;

  /// Shown under the link kind while "Can edit" is picked.
  static String editLinkWarning(AppLocalizations l10n) =>
      l10n.shareLinkCopyEditLinkWarning;

  static String disableTitle(AppLocalizations l10n) =>
      l10n.shareLinkCopyDisableTitle;
  static String disableDescription(AppLocalizations l10n) =>
      l10n.shareLinkCopyDisableDescription;
  static String removeJoinedLabel(
    AppLocalizations l10n,
    int count, {
    bool more = false,
  }) =>
      count == 1 && !more
          ? l10n.shareLinkCopyRemoveJoinedOne
          : more
              ? l10n.shareLinkCopyRemoveJoinedAtLeast(count)
              : l10n.shareLinkCopyRemoveJoinedMany(count);
  static String disableAction(AppLocalizations l10n) =>
      l10n.shareLinkCopyDisableAction;
  static String disableFailure(AppLocalizations l10n) =>
      l10n.shareLinkCopyDisableFailure;

  static String disabledStatus(AppLocalizations l10n) =>
      l10n.shareLinkCopyDisabledStatus;
  static String disabledTooltip(AppLocalizations l10n) =>
      l10n.shareLinkCopyDisabledTooltip;
  static String disableTooltip(AppLocalizations l10n) =>
      l10n.shareLinkCopyDisableTooltip;

  static String removeMemberTitle(AppLocalizations l10n, String name) =>
      l10n.shareLinkCopyRemoveMemberTitle(name);
  static String removeMemberDescription(AppLocalizations l10n) =>
      l10n.shareLinkCopyRemoveMemberDescription;
  static String removeMemberAction(AppLocalizations l10n) =>
      l10n.shareLinkCopyRemoveMemberAction;
  static String removeMemberFailure(AppLocalizations l10n) =>
      l10n.shareLinkCopyRemoveMemberFailure;
  static String roleChangeFailure(AppLocalizations l10n) =>
      l10n.shareLinkCopyRoleChangeFailure;
}
