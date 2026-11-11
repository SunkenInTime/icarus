import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/share/share_link_copy.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  test('disable copy states the boundary without overpromising', () {
    expect(ShareLinkCopy.disableAction(l10n), 'Disable link');
    expect(ShareLinkCopy.disableDescription(l10n),
        contains('No one new can join'));
    expect(ShareLinkCopy.disableDescription(l10n),
        contains('unless you remove them'));
    expect(
        ShareLinkCopy.disableDescription(l10n), contains('or view through it'));
    for (final targetType in ['strategy', 'folder']) {
      for (final opensInBrowser in [true, false]) {
        expect(
          ShareLinkCopy.dialogDescription(
            l10n,
            targetType,
            opensInBrowser: opensInBrowser,
          ),
          contains('until you disable them'),
        );
      }
    }
    // Only a strategy link that opens in a browser promises a view without
    // an account; a desktop link hands off to an app the reader may lack.
    expect(
      ShareLinkCopy.dialogDescription(l10n, 'strategy', opensInBrowser: true),
      contains('no account needed'),
    );
    expect(
      ShareLinkCopy.dialogDescription(l10n, 'strategy', opensInBrowser: false),
      isNot(contains('no account')),
    );
    expect(
      ShareLinkCopy.dialogDescription(l10n, 'folder', opensInBrowser: true),
      isNot(contains('no account')),
    );
  });
}
