import 'package:icarus/replay/recycle_bin_unavailable.dart';

/// There is no Recycle Bin outside a desktop, so nothing can go to one.
Future<void> moveToRecycleBin(String path) =>
    Future.error(RecycleBinUnavailable(path));
