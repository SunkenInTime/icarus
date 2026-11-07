import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

/// Tells an export dialog when a page it refused for its captions may fit
/// now, so the refusal lasts only as long as the notes that caused it.
///
/// The open page is read from the editor, which takes a teammate's edits as
/// they arrive. Another page of a cloud strategy is watched on the server
/// while it's refused. A local strategy's other pages can't change while a
/// dialog covers the editor.
class RefusedCaptionsWatch {
  RefusedCaptionsWatch(this._ref, {required this.onChange});

  /// How long changes are gathered before [onChange]: a drag or a run of
  /// edits asks for one check, not one per frame.
  static const settle = Duration(milliseconds: 400);

  final WidgetRef _ref;

  /// Called once watched pages have changed and settled.
  final VoidCallback onChange;

  List<ProviderSubscription<Object?>> _openPage = const [];
  final Map<String, StreamSubscription<RemotePageSnapshot>> _pages = {};
  Timer? _settling;

  /// Watches [pageIds], and stops watching every other page.
  void watch(Set<String> pageIds) {
    final openPageId = _ref.read(strategyPageSessionProvider).activePageId;
    final watchOpenPage = pageIds.contains(openPageId);
    if (watchOpenPage && _openPage.isEmpty) {
      void changed(Object? _, Object? __) => _changed();
      _openPage = [
        _ref.listenManual(agentProvider, changed),
        _ref.listenManual(abilityProvider, changed),
        _ref.listenManual(textProvider, changed),
        _ref.listenManual(placedImageProvider, changed),
        _ref.listenManual(utilityProvider, changed),
        _ref.listenManual(drawingProvider, changed),
      ];
    } else if (!watchOpenPage) {
      _closeOpenPage();
    }

    final strategy = _ref.read(strategyProvider);
    final strategyId = strategy.strategyId;
    final others = strategy.source == StrategySource.cloud && strategyId != null
        ? ({...pageIds}..remove(openPageId))
        : const <String>{};
    for (final pageId in [..._pages.keys]) {
      if (!others.contains(pageId)) unawaited(_pages.remove(pageId)!.cancel());
    }
    final linkView = _ref.read(shareLinkViewProvider);
    final shareToken =
        linkView?.strategyPublicId == strategyId ? linkView!.token : null;
    for (final pageId in others) {
      // Its first answer counts as a change too: the page may have changed
      // between the check that refused it and this watch starting.
      _pages[pageId] ??= _ref
          .read(convexStrategyRepositoryProvider)
          .watchPageSnapshot(
            strategyPublicId: strategyId!,
            pagePublicId: pageId,
            shareToken: shareToken,
          )
          .listen((_) => _changed(), onError: (Object _) {});
    }
    if (_openPage.isEmpty && _pages.isEmpty) {
      _settling?.cancel();
      _settling = null;
    }
  }

  void _changed() {
    _settling?.cancel();
    _settling = Timer(settle, onChange);
  }

  void _closeOpenPage() {
    for (final subscription in _openPage) {
      subscription.close();
    }
    _openPage = const [];
  }

  void dispose() {
    _settling?.cancel();
    _closeOpenPage();
    for (final subscription in _pages.values) {
      unawaited(subscription.cancel());
    }
    _pages.clear();
  }
}
