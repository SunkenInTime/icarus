import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:ui';
import 'package:cross_file/cross_file.dart' show XFile;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'dart:ui' as ui;
import 'dart:async' show Completer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

final placedImageProvider =
    NotifierProvider<PlacedImageProvider, ImageState>(PlacedImageProvider.new);

class ImageState {
  ImageState({
    required this.images,
  });

  final List<PlacedImage> images;

  ImageState copyWith({
    List<PlacedImage>? images,
  }) {
    return ImageState(
      images: images ?? this.images,
    );
  }
}

class PlacedImageProvider extends Notifier<ImageState> {
  List<PlacedImage> poppedImages = [];

  @override
  ImageState build() {
    log('ImageState provider build() called');
    return ImageState(
      images: [],
    );
  }

  Future<void> deleteUnusedImages(
      String strategyID, List<String> localImages) async {
    List<String> fileIDs = localImages;

    if (kIsWeb) return;
    // Get the system's application support directory.
    final directory = await getApplicationSupportDirectory();

    // Create a custom directory inside the application support directory.
    final customDirectory = Directory(path.join(directory.path, strategyID));

    // Create the directory if it doesn't exist.
    if (!await customDirectory.exists()) return;

    // Construct the full path for the images subdirectory.
    final filePath = path.join(customDirectory.path, 'images');

    // Create the images directory if it doesn't exist.
    final imagesDirectory = Directory(filePath);
    if (!await imagesDirectory.exists()) {
      await imagesDirectory.create(recursive: true);
      return; // If directory was just created, no files to check.
    }

    // List all files in the directory (non-recursively).
    List<FileSystemEntity> files = imagesDirectory.listSync();

    // Check each file: if its name (without extension) is not in fileIDs then delete.
    for (FileSystemEntity entity in files) {
      if (entity is File) {
        // Get the file name without extension.
        String fileName = path.basenameWithoutExtension(entity.path);
        if (!fileIDs.contains(fileName)) {
          try {
            log('Deleting unused image file: ${entity.path}');
            await entity.delete();
          } catch (e) {
            log(e.toString());
          }
        }
      }
    }
  }

  Future<double> getImageAspectRatio(Uint8List imageData) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(
      imageData,
      (ui.Image img) {
        completer.complete(img);
      },
    );
    final ui.Image image = await completer.future;
    return image.width / image.height;
  }

  Future<void> addImage(XFile imageFile) async {
    final imageID = const Uuid().v4();
    final String fileExtension = path.extension(imageFile.path);
    final Uint8List imageBytes = await imageFile.readAsBytes();

    await ref
        .read(placedImageProvider.notifier)
        .saveSecureImage(imageBytes, imageID, fileExtension);

    final placedImage = PlacedImage(
      fileExtension: fileExtension,
      position: const Offset(500, 500),
      id: imageID,
      aspectRatio: await getImageAspectRatio(imageBytes),
      scale: 200,
    );

    final action = UserAction(
      type: ActionType.addition,
      id: placedImage.id,
      group: ActionGroup.image,
    );

    ref.read(actionProvider.notifier).addAction(action);

    state = state.copyWith(images: [...state.images, placedImage]);

    log(state.images.length.toString());
    log(poppedImages.length.toString());
  }

  void removeImage(String id) {
    final newImages = [...state.images];
    final index = PlacedWidget.getIndexByID(id, newImages);

    if (index < 0) return;
    final image = newImages.removeAt(index);
    poppedImages.add(image);

    state = state.copyWith(images: newImages);
  }

  void updatePosition(Offset position, String id) {
    final newImages = [...state.images];
    final index = PlacedWidget.getIndexByID(id, newImages);

    if (index < 0) return;
    newImages[index].updatePosition(position);

    final temp = newImages.removeAt(index);

    final action = UserAction(
      type: ActionType.edit,
      id: id,
      group: ActionGroup.image,
    );
    ref.read(actionProvider.notifier).addAction(action);

    state = state.copyWith(images: [...newImages, temp]);
  }

  void undoAction(UserAction action) {
    log("Attempting to undo image action");

    switch (action.type) {
      case ActionType.addition:
        removeImage(action.id);
      case ActionType.deletion:
        if (poppedImages.isEmpty) {
          log("Popped images is empty");
          return;
        }
        final newImages = [...state.images];
        newImages.add(poppedImages.removeLast());
        state = state.copyWith(images: newImages);
      case ActionType.edit:
        undoPosition(action.id);
    }
  }

  void undoPosition(String id) {
    final newImages = [...state.images];
    final index = PlacedWidget.getIndexByID(id, newImages);

    if (index < 0) return;
    newImages[index].undoAction();

    state = state.copyWith(images: newImages);
  }

  void redoAction(UserAction action) {
    final newImages = [...state.images];

    try {
      switch (action.type) {
        case ActionType.addition:
          final index = PlacedWidget.getIndexByID(action.id, poppedImages);
          newImages.add(poppedImages.removeAt(index));

        case ActionType.deletion:
          final index = PlacedWidget.getIndexByID(action.id, poppedImages);
          poppedImages.add(newImages.removeAt(index));

        case ActionType.edit:
          final index = PlacedWidget.getIndexByID(action.id, newImages);
          newImages[index].redoAction();
      }
    } catch (_) {
      log("Failed to find index");
    }
    state = state.copyWith(images: newImages);
  }

  static Future<Directory> getImageFolder(String strategyID) async {
    // Get the system's application support directory.
    final Directory appSupportDir = await getApplicationSupportDirectory();

    // Create the custom directory using the strategy ID.
    final Directory customDirectory =
        Directory(path.join(appSupportDir.path, strategyID));
    if (!await customDirectory.exists()) {
      await customDirectory.create(recursive: true);
    }

    final Directory imagesDirectory =
        Directory(path.join(customDirectory.path, 'images'));
    if (!await imagesDirectory.exists()) {
      await imagesDirectory.create(recursive: true);
    }

    return imagesDirectory;
  }

  Future<String> toJson(String strategyID) async {
    // Asynchronously convert each image using the custom serializer.
    final List<Map<String, dynamic>> jsonList =
        state.images.map((image) => image.toJson()).toList();

    return jsonEncode(jsonList);
  }

  static String objectToJson(List<PlacedImage> images, String strategyID) {
    final List<Map<String, dynamic>> jsonList =
        images.map((image) => image.toJson()).toList();

    return jsonEncode(jsonList);
  }

  static Future<List<PlacedImage>> fromJson(
      {required String jsonString, required String strategyID}) async {
    final List<dynamic> jsonList = jsonDecode(jsonString);

    // Use the custom deserializer for each JSON map.
    // final images = await Future.wait(
    //   jsonList.map((json) => PlacedImageSerializer.fromJson(
    //       json as Map<String, dynamic>, strategyID)),
    // );

    final images = jsonList
        .map((json) => PlacedImage.fromJson(json as Map<String, dynamic>))
        .toList();

    return images;
  }

  static Future<List<PlacedImage>> legacyFromJson(
      {required String jsonString, required String strategyID}) async {
    final List<dynamic> jsonList = jsonDecode(jsonString);

    // Use the custom deserializer for each JSON map.
    final images = await Future.wait(
      jsonList.map((json) => PlacedImageSerializer.fromJson(
          json as Map<String, dynamic>, strategyID)),
    );

    return images;
  }

  void updateScale(int index, double scale) {
    final newState = state.copyWith();

    newState.images[index].scale = scale;

    state = newState;
  }

  Future<void> saveSecureImage(
    Uint8List imageBytes,
    String imageID,
    String fileExtenstion,
  ) async {
    final strategyID = ref.read(strategyProvider).id;
    // Get the system's application support directory.
    if (kIsWeb) return;
    final directory = await getApplicationSupportDirectory();

    // Create a custom directory inside the application support directory.

    final customDirectory = Directory(path.join(directory.path, strategyID));

    if (!await customDirectory.exists()) {
      await customDirectory.create(recursive: true);
    }

    // Now create the full file path.
    final filePath = path.join(
      customDirectory.path,
      'images',
      '$imageID$fileExtenstion',
    );

    log(filePath);
    // Ensure the images subdirectory exists.
    final imagesDir = Directory(path.join(customDirectory.path, 'images'));
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }

    // Write the file.
    final file = File(filePath);
    await file.writeAsBytes(imageBytes);
  }

  static List<PlacedImage> deepCopyWith(List<PlacedImage> images) {
    return images.map((image) => image.copyWith()).toList();
  }

  void fromHive(List<PlacedImage> hiveImages) {
    poppedImages = [];
    state = state.copyWith(images: hiveImages);
  }

  void clearAll() {
    poppedImages = [];
    state = state.copyWith(images: []);
  }
}

/// A helper class to handle the asynchronous conversion of [PlacedImage].
///
/// Note: Because reading bytes from disk and writing them back is an
/// asynchronous operation, these methods should be called outside the
/// synchronous `toJson`/`fromJson` normally generated by [json_serializable].
class PlacedImageSerializer {
  /// Serializes a [PlacedImage] into a JSON map.
  ///
  /// The [strategyID] is required here to determine the parent folder
  /// where the image is stored.
  static Future<Map<String, dynamic>> toJson(
    PlacedImage image,
    String strategyID,
  ) async {
    // Compute the final file path.
    final filePath = await _computeFilePath(image, strategyID);

    // Read the image file as bytes.
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('Image file does not exist at $filePath');
    }
    final Uint8List fileBytes = await file.readAsBytes();

    // Use your custom serializer for Uint8List.
    final serializedBytes = serializeUint8List(fileBytes);

    // Get the basic JSON from the code-generated method.
    final Map<String, dynamic> json = image.toJson();

    // Add the image bytes into the JSON.
    json['imageBytes'] = serializedBytes;

    // Optionally update the object's link.
    image.updateLink(filePath);

    return json;
  }

  /// Deserializes a JSON map back into a [PlacedImage].
  ///
  /// A new strategy ID is generated for the file location using [Uuid].
  static Future<PlacedImage> fromJson(
      Map<String, dynamic> json, String strategyID) async {
    // Use your code-generated deserializer for basic fields.

    // Retrieve and deserialize the image bytes
    if (!json.containsKey('imageBytes') && !json.containsKey("image")) {
      throw Exception('JSON does not contain imageBytes.');
    }
    if (!json.containsKey('imageBytes')) {
      dynamic newImageBytes = json["image"];
      json["imageBytes"] = newImageBytes;
      json.remove("image");
    }

    final serializedBytes = json['imageBytes'];
    final Uint8List imageBytes = deserializeUint8List(serializedBytes);

    if (!json.containsKey('fileExtension')) {
      final String? fileExtension = _detectImageFormat(imageBytes);

      json['fileExtension'] = fileExtension;
    }

    final placedImage = PlacedImage.fromJson(json);

    // Compute the final file path to write the image.
    final filePath = await _computeFilePath(placedImage, strategyID);

    // Ensure the target directory exists.
    final file = File(filePath);
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }

    // Write the image bytes to disk.
    await file.writeAsBytes(imageBytes);

    // Update the link on the instance.
    placedImage.updateLink(filePath);

    return placedImage;
  }

  /// Computes the file path where the image should be stored.
  ///
  /// It uses the application support directory, creates a custom folder based
  /// on [strategyID] and an `images` subfolder, and forms the filename from the
  /// image's [id] and [fileExtension].
  static Future<String> _computeFilePath(
      PlacedImage image, String strategyID) async {
    // Get the system's application support directory.
    final Directory appSupportDir = await getApplicationSupportDirectory();

    // Create the custom directory using the strategy ID.
    final Directory customDirectory =
        Directory(path.join(appSupportDir.path, strategyID));
    if (!await customDirectory.exists()) {
      await customDirectory.create(recursive: true);
    }

    // Create the images subfolder.
    final Directory imagesDirectory =
        Directory(path.join(customDirectory.path, 'images'));
    if (!await imagesDirectory.exists()) {
      await imagesDirectory.create(recursive: true);
    }

    // The final file path: [id][fileExtension]
    return path.join(imagesDirectory.path, '${image.id}${image.fileExtension}');
  }
}

/// Dummy custom serializer for Uint8List.
/// Replace these with your actual implementations.
dynamic serializeUint8List(Uint8List data) {
  // For example, convert to a Base64 string.
  return base64Encode(data);
}

Uint8List deserializeUint8List(dynamic jsonData) {
  // For example, convert the Base64 string back into a Uint8List.
  if (jsonData is String) {
    return Uint8List.fromList(base64Decode(jsonData));
  }
  throw Exception('Invalid data for Uint8List deserialization.');
}

String? _detectImageFormat(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  if (decoder == null || !decoder.isValidFile(bytes)) return null;
  if (decoder is img.PngDecoder) return 'png';
  if (decoder is img.JpegDecoder) return 'jpeg';
  if (decoder is img.GifDecoder) return 'gif';
  if (decoder is img.WebPDecoder) return 'webp';
  // …etc.
  return null;
}
