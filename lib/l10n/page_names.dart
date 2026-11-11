import 'package:icarus/l10n/generated/app_localizations.dart';

final _autoName = RegExp(r'^Page (\d{1,9})$');

/// A page's name as drawn. A page nobody named is saved as "Page 3" whatever
/// the language, so each person reads it in their own. [name] stays what is
/// saved, sent and compared.
String shownPageName(
  AppLocalizations l10n, {
  required String name,
  required bool isAutoNamed,
}) {
  final number = isAutoNamed ? _autoName.firstMatch(name)?.group(1) : null;
  return number == null ? name : l10n.pagesBarAutoName(int.parse(number));
}
