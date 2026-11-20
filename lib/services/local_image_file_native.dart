import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:icarus/services/image_file_name.dart';
import 'package:path/path.dart' as path;

const bool deviceHasImageFiles = true;

/// The path of an image's file under [storageDirectory], or null when the
/// file is not on this device.
String? findLocalImageFile({
  required String? storageDirectory,
  required String imageId,
  required String? fileExtension,
}) {
  if (storageDirectory == null) return null;
  final name = imageFileName(imageId, fileExtension);
  if (name == null) return null;
  final filePath = path.join(storageDirectory, 'images', name);
  return File(filePath).existsSync() ? filePath : null;
}

ImageProvider localImageProvider(String filePath) => FileImage(File(filePath));

Future<int> localImageFileLength(String filePath) => File(filePath).length();

Stream<List<int>> readLocalImageFile(String filePath) =>
    File(filePath).openRead();
