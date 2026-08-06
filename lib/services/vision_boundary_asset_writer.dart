import 'vision_boundary_asset_writer_stub.dart'
    if (dart.library.io) 'vision_boundary_asset_writer_io.dart'
    as platform;

Future<String?> writeVisionBoundaryEditsAsset(String contents) =>
    platform.writeVisionBoundaryEditsAsset(contents);
