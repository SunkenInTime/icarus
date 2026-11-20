import 'package:hive_ce/hive_ce.dart';
import 'package:web/web.dart';

import '../store/engine.dart';

Future<Stored<T>> guarded<T>(Future<T> Function() task) async {
  try {
    return Done(await task());
    // ignore: invalid_runtime_check_with_js_interop_types
  } on DOMException catch (error) {
    return StorageFailed(DeviceFailure('${error.name}: ${error.message}'));
  } on HiveError catch (error) {
    return StorageFailed(DeviceFailure(error.message));
  }
}
