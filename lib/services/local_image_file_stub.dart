import 'package:flutter/painting.dart';

/// Whether this platform keeps strategy images as files on the device.
const bool deviceHasImageFiles = false;

/// The path of an image's file under [storageDirectory], or null when the
/// file is not on this device. There are no image files here.
String? findLocalImageFile({
  required String? storageDirectory,
  required String imageId,
  required String? fileExtension,
}) =>
    null;

ImageProvider localImageProvider(String filePath) =>
    throw UnsupportedError('No image files on this platform: $filePath');
