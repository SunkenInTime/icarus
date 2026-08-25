import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/share/share_link_copy.dart';

void main() {
  test('disable copy states the boundary without overpromising', () {
    expect(ShareLinkCopy.disableAction, 'Disable link');
    expect(ShareLinkCopy.disableDescription, contains('prevents new people'));
    expect(ShareLinkCopy.disableDescription, contains('keep their access'));
    expect(ShareLinkCopy.dialogDescription, contains('until you disable them'));
  });
}
