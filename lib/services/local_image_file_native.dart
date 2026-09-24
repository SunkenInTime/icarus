import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:path/path.dart' as path;

/// Whether this platform keeps strategy images as files on the device.
const bool deviceHasImageFiles = true;

/// The path of an image's file under [storageDirectory], or null when the
/// file is not on this device.
String? findLocalImageFile({
  required String? storageDirectory,
  required String imageId,
  required String? fileExtension,
}) {
  if (storageDirectory == null || fileExtension == null) return null;
  final filePath =
      path.join(storageDirectory, 'images', '$imageId$fileExtension');
  return File(filePath).existsSync() ? filePath : null;
}

ImageProvider localImageProvider(String filePath) => FileImage(File(filePath));
