// Strategy image files on this device. Web keeps no image files, so there
// every lookup misses and images come from their cloud URL instead.
export 'local_image_file_stub.dart'
    if (dart.library.io) 'local_image_file_native.dart';
