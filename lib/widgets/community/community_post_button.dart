import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/collab/community_repository.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/dialogs/community/post_to_community_dialog.dart';
import 'package:icarus/widgets/loading_spinner.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile_sections.dart';
import 'package:icarus/widgets/text_editing_shortcut_scope.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const double _pickerWidth = 340;
const double _rowHeight = 50;
const int _rowsShown = 6;

/// The user's strategies to post, read each time the picker opens.
final _postableProvider =
    FutureProvider.autoDispose<List<PostableStrategy>>((ref) {
  return ref.read(communityRepositoryProvider).fetchPostable();
});

/// The Community tab's Post button: picks one of the user's strategies and
/// opens its posting dialog. Signed out, it asks them to sign in.
class CommunityPostButton extends ConsumerStatefulWidget {
  const CommunityPostButton({super.key, required this.height});

  final double height;

  @override
  ConsumerState<CommunityPostButton> createState() =>
      _CommunityPostButtonState();
}

class _CommunityPostButtonState extends ConsumerState<CommunityPostButton> {
  final _popover = ShadPopoverController();

  @override
  void dispose() {
    _popover.dispose();
    super.dispose();
  }

  void _pressed() {
    final auth = ref.read(authProvider);
    if (!auth.isAuthenticated) {
      showDialog<void>(context: context, builder: (_) => const AuthDialog());
      return;
    }
    if (!_popover.isOpen) ref.invalidate(_postableProvider);
    _popover.toggle();
  }

  void _picked(PostableStrategy strategy) {
    _popover.hide();
    showPostToCommunityDialog(context, strategy.strategyPublicId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ShadPopover(
      controller: _popover,
      padding: EdgeInsets.zero,
      anchor: const ShadAnchor(
        offset: Offset(0, 6),
        childAlignment: Alignment.topRight,
        overlayAlignment: Alignment.bottomRight,
      ),
      popover: (context) => _Picker(onPicked: _picked),
      child: ShadButton(
        key: const ValueKey('community-post-button'),
        height: widget.height,
        padding: const EdgeInsets.only(left: 8, right: 10),
        onPressed: _pressed,
        leading: const Icon(LucideIcons.arrowUp, size: 16),
        child: Text(l10n.communityPostButton),
      ),
    );
  }
}

class _Picker extends ConsumerStatefulWidget {
  const _Picker({required this.onPicked});

  final ValueChanged<PostableStrategy> onPicked;

  @override
  ConsumerState<_Picker> createState() => _PickerState();
}

class _PickerState extends ConsumerState<_Picker> {
  final _query = TextEditingController();
  int _highlighted = 0;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() => _highlighted = 0));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<PostableStrategy> _matches(List<PostableStrategy> all) {
    final query = _query.text.trim().toLowerCase();
    if (query.isEmpty) return all;
    return [
      for (final strategy in all)
        if (strategy.name.toLowerCase().contains(query)) strategy,
    ];
  }

  KeyEventResult _onKey(List<PostableStrategy> matches, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (matches.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlighted = (_highlighted + 1) % matches.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() =>
          _highlighted = (_highlighted - 1 + matches.length) % matches.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      widget.onPicked(matches[_highlighted.clamp(0, matches.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final l10n = context.l10n;
    final postable = ref.watch(_postableProvider);
    final matches = _matches(postable.valueOrNull ?? const []);

    final Widget list;
    if (postable.hasError) {
      list = _PickerMessage(l10n.communityPickerFailed);
    } else if (!postable.hasValue) {
      list = const _PickerMessage(null);
    } else if (postable.value!.isEmpty) {
      list = _PickerMessage(l10n.communityPickerEmpty);
    } else if (matches.isEmpty) {
      list = _PickerMessage(l10n.communityPickerNoMatch);
    } else {
      list = ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _rowHeight * _rowsShown),
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.all(6),
          itemCount: matches.length,
          itemBuilder: (context, index) => _PickerRow(
            strategy: matches[index],
            highlighted: index == _highlighted,
            onHover: () => setState(() => _highlighted = index),
            onTap: () => widget.onPicked(matches[index]),
          ),
        ),
      );
    }

    return SizedBox(
      width: _pickerWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Focus(
            onKeyEvent: (_, event) => _onKey(matches, event),
            child: TextEditingShortcutScope(
              child: ShadInput(
                key: const ValueKey('community-post-picker-search'),
                controller: _query,
                autofocus: true,
                decoration: const ShadDecoration(
                  border: ShadBorder.none,
                  focusedBorder: ShadBorder.none,
                ),
                leading: Icon(
                  LucideIcons.search,
                  size: 16,
                  color: theme.mutedForeground,
                ),
                placeholder: Text(l10n.communityPickerPlaceholder),
              ),
            ),
          ),
          Divider(height: 1, color: theme.border),
          list,
        ],
      ),
    );
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.strategy,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
  });

  final PostableStrategy strategy;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final l10n = context.l10n;
    final map = strategy.map;
    final mapName = map == null ? null : Maps.mapNames[map];
    final when = StrategyTileViewData.timeAgo(l10n, strategy.updatedAt);
    return Semantics(
      button: true,
      label: strategy.name,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: _rowHeight,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: highlighted ? theme.secondary : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: SizedBox(
                    width: 52,
                    height: 32,
                    child: mapName == null
                        ? ColoredBox(color: theme.muted)
                        : Image.asset(
                            'assets/maps/thumbnails/${mapName}_thumbnail.webp',
                            fit: BoxFit.cover,
                            cacheWidth: 104,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strategy.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        mapName == null
                            ? when
                            : '${mapName[0].toUpperCase()}'
                                '${mapName.substring(1)} · $when',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
                if (strategy.postPublicId != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    l10n.communityPostedBadge,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.mutedForeground,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PickerMessage extends StatelessWidget {
  /// A spinner when [text] is null.
  const _PickerMessage(this.text);

  final String? text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: Center(
        child: text == null
            ? const SizedBox.square(
                dimension: 18,
                child: LoadingSpinner(strokeWidth: 2),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  text!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Settings.tacticalVioletTheme.mutedForeground,
                  ),
                ),
              ),
      ),
    );
  }
}
