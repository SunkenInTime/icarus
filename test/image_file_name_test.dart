import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/services/image_file_name.dart';

// Image ids and extensions arrive in imported files and from the cloud, and
// become file names on disk. Only names that stay inside their folder and
// end in an image type are ever used.

void main() {
  const uuid = '6d0f1c1e-3a43-4a8e-9a55-2f4b8c7d9e10';

  test('every id the app makes is a safe name', () {
    for (final id in [
      uuid,
      '$uuid~cp1~0b5f8d3a-1c2e-4f6a-8b9c-0d1e2f3a4b5c',
      'image_1',
      'a..b',
    ]) {
      expect(isSafeFileNameId(id), isTrue, reason: id);
    }
  });

  test('names that leave the folder or that Windows rewrites are refused', () {
    for (final id in [
      '',
      '.',
      '..',
      'a/b',
      r'a\b',
      'C:x',
      'a?b',
      'x.',
      'x ',
      'x' * 201,
    ]) {
      expect(isSafeFileNameId(id), isFalse, reason: id);
    }
  });

  test('only image extensions make a file name, in any case', () {
    expect(imageFileName(uuid, '.png'), '$uuid.png');
    expect(imageFileName(uuid, '.PNG'), '$uuid.PNG');
    expect(imageFileName(uuid, '.jpeg'), '$uuid.jpeg');
    expect(imageFileName(uuid, null), isNull);
    expect(imageFileName(uuid, ''), isNull);
    expect(imageFileName(uuid, '.txt'), isNull);
    expect(imageFileName('a/b', '.png'), isNull);
  });

  test('the path builder refuses a name it may not use', () {
    expect(
      PlacedImageProvider.buildImageFilePath('images', uuid, '.png'),
      endsWith('$uuid.png'),
    );
    expect(
      () => PlacedImageProvider.buildImageFilePath('images', 'a/b', '.png'),
      throwsA(isA<UnsafeImageFileNameException>()),
    );
    expect(
      () => PlacedImageProvider.buildImageFilePath('images', uuid, '.txt'),
      throwsA(isA<UnsafeImageFileNameException>()),
    );
  });
}
