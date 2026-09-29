import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/share/share_link_copy.dart';

void main() {
  test('disable copy states the boundary without overpromising', () {
    expect(ShareLinkCopy.disableAction, 'Disable link');
    expect(ShareLinkCopy.disableDescription, contains('prevents new people'));
    expect(ShareLinkCopy.disableDescription, contains('keep their access'));
    expect(
      ShareLinkCopy.disableDescription,
      contains('viewing through it without an account'),
    );
    for (final targetType in ['strategy', 'folder']) {
      for (final opensInBrowser in [true, false]) {
        expect(
          ShareLinkCopy.dialogDescription(
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
      ShareLinkCopy.dialogDescription('strategy', opensInBrowser: true),
      contains('no account needed'),
    );
    expect(
      ShareLinkCopy.dialogDescription('strategy', opensInBrowser: false),
      isNot(contains('no account')),
    );
    expect(
      ShareLinkCopy.dialogDescription('folder', opensInBrowser: true),
      isNot(contains('no account')),
    );
  });
}
