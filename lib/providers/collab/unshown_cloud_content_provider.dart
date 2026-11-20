import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

final unshownCloudContentProvider =
    StateProvider<UnshownCloudContent>((ref) => UnshownCloudContent.none);
