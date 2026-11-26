import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
import 'package:icarus/strategy/open_seen.dart';

extension OpensNow on StrategyProvider {
  Future<bool> loadFromHive(String id, {String? pageId}) async =>
      await openLocal(id, pageId: pageId, asked: askedByTheUserNow())
          is Changed;

  Future<bool> openCloudStrategy(String id, {String? pageId}) async =>
      await openCloud(id, pageId: pageId, asked: askedByTheUserNow())
          is Changed;

  Future<void> clearCurrentStrategy() async {
    closeStrategy(asked: askedByTheUserNow());
  }
}

Future<bool> guardThen({
  required BuildContext context,
  required WidgetRef ref,
  required String source,
  required Future<void> Function() onContinue,
}) async {
  final answer = await guardUnsavedStrategyExit(
    context: context,
    ref: ref,
    source: source,
  );
  if (answer is! Leave) return false;
  await onContinue();
  return true;
}
