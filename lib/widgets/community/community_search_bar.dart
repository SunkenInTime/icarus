import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/community_provider.dart';
import 'package:icarus/widgets/community/community_post_card.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/widgets/text_editing_shortcut_scope.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const double communitySearchBarWidth = 620;
const double communitySearchBarHeight = 52;
const double _panelPadding = 18;
const double _radius = 16;

/// The Community tab's one control: a bar floating at the foot of the feed.
/// Words search titles and authors. `@` starts a filter (`@ascent`,
/// `@sova`, `@attack`) that becomes a tag in the bar; clicking the empty bar
/// opens every map, agent and side to pick from instead.
class CommunitySearchBar extends ConsumerStatefulWidget {
  const CommunitySearchBar({
    super.key,
    required this.onPanelChanged,
    required this.maxPanelHeight,
  });

  /// Whether the bar has grown into its panel, so the feed behind can dim.
  final ValueChanged<bool> onPanelChanged;
  final double maxPanelHeight;

  @override
  ConsumerState<CommunitySearchBar> createState() => _CommunitySearchBarState();
}

class _CommunitySearchBarState extends ConsumerState<CommunitySearchBar> {
  final _controller = TextEditingController();
  final _focus = FocusNode(debugLabel: 'community-search');
  final _sortMenu = ShadPopoverController();
  Timer? _textDebounce;
  int _highlight = 0;
  bool _panelOpen = false;

  /// The filter word being typed after `@`, or null.
  static final _atWord = RegExp(r'(?:^|\s)@(\S*)$');

  @override
  void initState() {
    super.initState();
    _controller.text = ref.read(communityFilterProvider).text;
    _controller.addListener(_onTextChanged);
    _focus.addListener(_syncPanel);
  }

  @override
  void dispose() {
    _textDebounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    _sortMenu.dispose();
    super.dispose();
  }

  String? get _typedFilter => _atWord.firstMatch(_controller.text)?.group(1);

  /// Starred is the reader's own: offered only with an account.
  bool get _signedIn {
    final auth = ref.read(authProvider);
    return auth.isAuthenticated && auth.isConvexUserReady;
  }

  String get _freeText => _controller.text.replaceFirst(_atWord, '').trim();

  void _onTextChanged() {
    _highlight = 0;
    _syncPanel();
    _textDebounce?.cancel();
    final text = _freeText;
    if (text == ref.read(communityFilterProvider).text) return;
    // Each change is a server read: wait for a pause in the typing.
    _textDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      final filter = ref.read(communityFilterProvider.notifier);
      filter.state = filter.state.copyWith(text: _freeText);
    });
  }

  void _syncPanel() {
    final open = _focus.hasFocus &&
        (_typedFilter != null || _controller.text.trim().isEmpty);
    if (open != _panelOpen) {
      setState(() => _panelOpen = open);
      widget.onPanelChanged(open);
    } else {
      setState(() {});
    }
  }

  void _close() {
    _focus.unfocus();
  }

  void _update(CommunityFilter Function(CommunityFilter) change) {
    final filter = ref.read(communityFilterProvider.notifier);
    filter.state = change(filter.state);
  }

  void _toggleMap(MapValue map) => _update(
        (f) => f.map == map ? f.copyWith(clearMap: true) : f.copyWith(map: map),
      );

  void _toggleSide(CommunitySide side) => _update(
        (f) => f.side == side
            ? f.copyWith(clearSide: true)
            : f.copyWith(side: side),
      );

  void _toggleAgent(AgentType agent) => _update((f) {
        if (f.agents.contains(agent)) {
          return f.copyWith(agents: [...f.agents]..remove(agent));
        }
        // The server matches at most six agents at once.
        if (f.agents.length >= 6) return f;
        return f.copyWith(agents: [...f.agents, agent]);
      });

  /// Takes the `@word` out of the field and makes it a tag.
  void _pick(_Suggestion suggestion) {
    switch (suggestion) {
      case _MapSuggestion(:final map):
        _update((f) => f.copyWith(map: map));
      case _AgentSuggestion(:final agent):
        final current = ref.read(communityFilterProvider);
        if (!current.agents.contains(agent)) _toggleAgent(agent);
      case _SideSuggestion(:final side):
        _update((f) => f.copyWith(side: side));
      case _StarredSuggestion():
        _update((f) => f.copyWith(starred: true));
    }
    final rest = _controller.text.replaceFirst(_atWord, '').trimRight();
    _controller.value = TextEditingValue(
      text: rest.isEmpty ? '' : '$rest ',
      selection: TextSelection.collapsed(
        offset: rest.isEmpty ? 0 : rest.length + 1,
      ),
    );
  }

  /// Removes the last tag: Backspace in an empty field.
  void _removeLastTag() {
    final filter = ref.read(communityFilterProvider);
    if (filter.agents.isNotEmpty) {
      _toggleAgent(filter.agents.last);
    } else if (filter.side != null) {
      _update((f) => f.copyWith(clearSide: true));
    } else if (filter.map != null) {
      _update((f) => f.copyWith(clearMap: true));
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (_typedFilter != null) {
        _controller.text = _controller.text.replaceFirst(_atWord, '');
      } else {
        _close();
      }
      return KeyEventResult.handled;
    }
    final suggestions = _suggestions(context);
    if (suggestions.isNotEmpty) {
      if (key == LogicalKeyboardKey.arrowDown) {
        setState(() => _highlight = (_highlight + 1) % suggestions.length);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        setState(() => _highlight =
            (_highlight - 1 + suggestions.length) % suggestions.length);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.tab) {
        _pick(suggestions[_highlight.clamp(0, suggestions.length - 1)]);
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.backspace &&
        _controller.selection.baseOffset == 0 &&
        _controller.selection.extentOffset == 0) {
      _removeLastTag();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  List<_Suggestion> _suggestions(BuildContext context) {
    final typed = _typedFilter;
    if (typed == null) return const [];
    final l10n = context.l10n;
    final query = typed.toLowerCase();
    final filter = ref.read(communityFilterProvider);
    final starts = <_Suggestion>[];
    final contains = <_Suggestion>[];
    void consider(_Suggestion suggestion, List<String> names) {
      final lower = [for (final name in names) name.toLowerCase()];
      if (lower.any((name) => name.startsWith(query))) {
        starts.add(suggestion);
      } else if (query.isNotEmpty &&
          lower.any((name) => name.contains(query))) {
        contains.add(suggestion);
      }
    }

    for (final agent in _agentsByName) {
      if (filter.agents.contains(agent.type)) continue;
      consider(
        _AgentSuggestion(agent.type),
        [agent.name, l10n.gameName(agent.name)],
      );
    }
    for (final map in _mapsByName) {
      if (filter.map == map) continue;
      consider(_MapSuggestion(map), [Maps.displayName(map), l10n.mapName(map)]);
    }
    for (final side in const [CommunitySide.attack, CommunitySide.defense]) {
      if (filter.side == side) continue;
      consider(_SideSuggestion(side), [
        side.name,
        if (side == CommunitySide.defense) 'defend',
        _sideLabel(l10n, side),
      ]);
    }
    if (!filter.starred && _signedIn) {
      consider(const _StarredSuggestion(), ['starred', l10n.communityStarred]);
    }
    return [...starts, ...contains].take(6).toList();
  }

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final signedIn = ref.watch(
      authProvider.select(
        (auth) => auth.isAuthenticated && auth.isConvexUserReady,
      ),
    );
    // Signed out, there are no stars to narrow to.
    ref.listen(
      authProvider.select(
        (auth) => auth.isAuthenticated && auth.isConvexUserReady,
      ),
      (_, signedIn) {
        if (!signedIn && ref.read(communityFilterProvider).starred) {
          _update((f) => f.copyWith(starred: false));
        }
      },
    );
    final filter = ref.watch(communityFilterProvider);
    final l10n = context.l10n;
    final suggestions = _suggestions(context);
    final typing = _typedFilter != null;
    final showPicker = _panelOpen && !typing;
    final showSuggestions = _panelOpen && typing;

    Widget? panel;
    if (showPicker) {
      panel = _PickerPanel(
        filter: filter,
        onMap: _toggleMap,
        onAgent: _toggleAgent,
        onSide: _toggleSide,
      );
    } else if (showSuggestions) {
      panel = suggestions.isEmpty
          ? Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
              child: Text(
                l10n.communitySearchNoFilterMatch,
                style: TextStyle(color: theme.mutedForeground),
              ),
            )
          : _SuggestionList(
              suggestions: suggestions,
              highlight: _highlight.clamp(0, suggestions.length - 1),
              onPick: _pick,
              onHover: (index) => setState(() => _highlight = index),
            );
    }

    return TapRegion(
      onTapOutside: (_) {
        if (_focus.hasFocus) _close();
      },
      child: Container(
        width: communitySearchBarWidth,
        decoration: BoxDecoration(
          color: theme.card,
          borderRadius: BorderRadius.circular(_radius),
          border: Border.all(color: theme.input),
          boxShadow: const [
            BoxShadow(
              color: Color(0xBF000000),
              blurRadius: 48,
              offset: Offset(0, 16),
            ),
            BoxShadow(
              color: Color(0x8A000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Settings.easeOut,
              alignment: Alignment.bottomCenter,
              child: panel == null
                  ? const SizedBox(width: double.infinity)
                  : ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight:
                            (widget.maxPanelHeight - communitySearchBarHeight)
                                .clamp(120, double.infinity),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(child: SingleChildScrollView(child: panel)),
                          Divider(height: 1, thickness: 1, color: theme.border),
                        ],
                      ),
                    ),
            ),
            SizedBox(
              height: communitySearchBarHeight,
              child: Padding(
                padding: const EdgeInsets.only(left: 18, right: 8),
                child: Row(
                  children: [
                    const Icon(
                      LucideIcons.search,
                      size: 18,
                      color: Settings.toolbarGlyph,
                    ),
                    const SizedBox(width: 12),
                    ..._tags(filter),
                    Expanded(
                      // Typing must not set off the app's one-key shortcuts;
                      // the field's own keys (arrows, Enter, Esc) come first.
                      child: TextEditingShortcutScope(
                        child: Focus(
                          onKeyEvent: _onKey,
                          child: TextField(
                            key: const ValueKey('community-search-field'),
                            controller: _controller,
                            focusNode: _focus,
                            cursorColor: theme.primary,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                            decoration: InputDecoration.collapsed(
                              hintText: _panelOpen && !typing
                                  ? l10n.communitySearchPickHint
                                  : filter.copyWith(starred: false).isEmpty
                                      ? l10n.communitySearchHint
                                      : null,
                              hintStyle: TextStyle(
                                color: theme.mutedForeground,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (signedIn) ...[
                      _StarredToggle(
                        on: filter.starred,
                        onTap: () => _update(
                          (f) => f.copyWith(starred: !f.starred),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    // Starred posts list newest star first; no sort applies.
                    if (!filter.starred) _SortButton(menu: _sortMenu),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _tags(CommunityFilter filter) {
    final l10n = context.l10n;
    final tags = <Widget>[
      if (filter.map case final map?)
        _Tag(
          label: l10n.mapName(map),
          leading: _Thumb(
            asset:
                'assets/maps/thumbnails/${Maps.mapNames[map]}_thumbnail.webp',
            width: 34,
          ),
          onRemove: () => _update((f) => f.copyWith(clearMap: true)),
        ),
      if (filter.side case final side?)
        _Tag(
          label: _sideLabel(l10n, side),
          labelColor: side == CommunitySide.attack
              ? Settings.attackColor
              : Settings.defenderColor,
          onRemove: () => _update((f) => f.copyWith(clearSide: true)),
        ),
      for (final agent in filter.agents)
        _Tag(
          label: l10n.gameName(AgentData.agents[agent]!.name),
          leading: _Thumb(asset: AgentData.agents[agent]!.iconPath, width: 24),
          onRemove: () => _toggleAgent(agent),
        ),
    ];
    // Past three tags the field would have no room left to type in.
    if (tags.length > 3) {
      return [
        ...tags.take(2).expand((tag) => [tag, const SizedBox(width: 6)]),
        _MoreTags(count: tags.length - 2),
        const SizedBox(width: 10),
      ];
    }
    return [
      for (final tag in tags) ...[tag, const SizedBox(width: 6)],
      if (tags.isNotEmpty) const SizedBox(width: 4),
    ];
  }
}

String _sideLabel(AppLocalizations l10n, CommunitySide side) => switch (side) {
      CommunitySide.attack => l10n.strategyTileSideAttack,
      CommunitySide.defense => l10n.strategyTileSideDefend,
      CommunitySide.mixed => l10n.strategyTileSideMixed,
    };

final List<AgentData> _agentsByName = [...AgentData.agents.values]
  ..sort((a, b) => a.name.compareTo(b.name));

final List<MapValue> _mapsByName = [...MapValue.values]
  ..sort((a, b) => Maps.displayName(a).compareTo(Maps.displayName(b)));

sealed class _Suggestion {
  const _Suggestion();
}

class _StarredSuggestion extends _Suggestion {
  const _StarredSuggestion();
}

class _MapSuggestion extends _Suggestion {
  const _MapSuggestion(this.map);
  final MapValue map;
}

class _AgentSuggestion extends _Suggestion {
  const _AgentSuggestion(this.agent);
  final AgentType agent;
}

class _SideSuggestion extends _Suggestion {
  const _SideSuggestion(this.side);
  final CommunitySide side;
}

class _SuggestionList extends StatelessWidget {
  const _SuggestionList({
    required this.suggestions,
    required this.highlight,
    required this.onPick,
    required this.onHover,
  });

  final List<_Suggestion> suggestions;
  final int highlight;
  final ValueChanged<_Suggestion> onPick;
  final ValueChanged<int> onHover;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, suggestion) in suggestions.indexed)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => onHover(index),
              child: GestureDetector(
                onTap: () => onPick(suggestion),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Settings.easeOut,
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: index == highlight
                        ? theme.secondary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 26,
                        child: switch (suggestion) {
                          _AgentSuggestion(:final agent) => _Thumb(
                              asset: AgentData.agents[agent]!.iconPath,
                              width: 26,
                            ),
                          _MapSuggestion(:final map) => _Thumb(
                              asset:
                                  'assets/maps/thumbnails/${Maps.mapNames[map]}_thumbnail.webp',
                              width: 26,
                            ),
                          _SideSuggestion(:final side) => Icon(
                              side == CommunitySide.attack
                                  ? LucideIcons.swords
                                  : LucideIcons.shield,
                              size: 18,
                              color: side == CommunitySide.attack
                                  ? Settings.attackColor
                                  : Settings.defenderColor,
                            ),
                          _StarredSuggestion() => const Center(
                              child: CommunityStarGlyph(
                                filled: true,
                                color: Settings.accentInk,
                              ),
                            ),
                        },
                      ),
                      const SizedBox(width: 12),
                      Text(
                        switch (suggestion) {
                          _AgentSuggestion(:final agent) =>
                            l10n.gameName(AgentData.agents[agent]!.name),
                          _MapSuggestion(:final map) => l10n.mapName(map),
                          _SideSuggestion(:final side) =>
                            _sideLabel(l10n, side),
                          _StarredSuggestion() => l10n.communityStarred,
                        },
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        switch (suggestion) {
                          _AgentSuggestion() => l10n.communitySuggestionAgent,
                          _MapSuggestion() => l10n.communitySuggestionMap,
                          _SideSuggestion() => l10n.communitySuggestionSide,
                          _StarredSuggestion() =>
                            l10n.communitySuggestionStarred,
                        },
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.mutedForeground,
                        ),
                      ),
                      const Spacer(),
                      if (index == highlight) _Keycap(l10n.communityEnterKey),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Keycap extends StatelessWidget {
  const _Keycap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: theme.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.input),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Every map, agent and side, to pick by clicking instead of typing.
class _PickerPanel extends StatelessWidget {
  const _PickerPanel({
    required this.filter,
    required this.onMap,
    required this.onAgent,
    required this.onSide,
  });

  final CommunityFilter filter;
  final ValueChanged<MapValue> onMap;
  final ValueChanged<AgentType> onAgent;
  final ValueChanged<CommunitySide> onSide;

  static const _rolesLeft = [AgentRole.duelist, AgentRole.controller];
  static const _rolesRight = [AgentRole.initiator, AgentRole.sentinel];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _panelPadding,
        16,
        _panelPadding,
        _panelPadding,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const columns = 7;
          const gap = 6.0;
          final tileWidth =
              (constraints.maxWidth - gap * (columns - 1)) / columns;
          final halfWidth = (constraints.maxWidth - 24) / 2;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _SectionLabel(l10n.communityFilterMap),
              Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final map in _mapsByName)
                    _MapTile(
                      map: map,
                      width: tileWidth,
                      selected: filter.map == map,
                      onTap: () => onMap(map),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (index, roles)
                      in [_rolesLeft, _rolesRight].indexed)
                    Padding(
                      padding: EdgeInsets.only(left: index == 0 ? 0 : 24),
                      child: SizedBox(
                        width: halfWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final role in roles) ...[
                              _RoleLabel(role: role),
                              _AgentGroup(
                                role: role,
                                selected: filter.agents,
                                onAgent: onAgent,
                              ),
                              const SizedBox(height: 10),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              _SectionLabel(l10n.communityFilterSide),
              Row(
                children: [
                  for (final (index, side) in const [
                    CommunitySide.attack,
                    CommunitySide.defense,
                  ].indexed) ...[
                    if (index > 0) const SizedBox(width: 24),
                    SizedBox(
                      width: halfWidth,
                      child: _SideButton(
                        side: side,
                        selected: filter.side == side,
                        onTap: () => onSide(side),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _RoleLabel extends StatelessWidget {
  const _RoleLabel({required this.role});

  final AgentRole role;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Image.asset(
            'assets/agents/${agentRoleNames[role]}.webp',
            width: 14,
            height: 14,
            cacheWidth: 42,
          ),
          const SizedBox(width: 6),
          Text(
            switch (role) {
              AgentRole.duelist => l10n.communityRoleDuelists,
              AgentRole.controller => l10n.communityRoleControllers,
              AgentRole.initiator => l10n.communityRoleInitiators,
              AgentRole.sentinel => l10n.communityRoleSentinels,
            },
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Small enough that all nine duelists fit on one line of a half column.
const double _agentSize = 26;
const double _agentGap = 3;

class _AgentGroup extends StatelessWidget {
  const _AgentGroup({
    required this.role,
    required this.selected,
    required this.onAgent,
  });

  final AgentRole role;
  final List<AgentType> selected;
  final ValueChanged<AgentType> onAgent;

  @override
  Widget build(BuildContext context) {
    final agents = [
      for (final agent in _agentsByName)
        if (agent.role == role) agent,
    ];
    return Wrap(
      spacing: _agentGap,
      runSpacing: _agentGap,
      children: [
        for (final agent in agents)
          _AgentToggle(
            agent: agent,
            selected: selected.contains(agent.type),
            dimmed: selected.isNotEmpty && !selected.contains(agent.type),
            onTap: () => onAgent(agent.type),
          ),
      ],
    );
  }
}

class _AgentToggle extends StatefulWidget {
  const _AgentToggle({
    required this.agent,
    required this.selected,
    required this.dimmed,
    required this.onTap,
  });

  final AgentData agent;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  State<_AgentToggle> createState() => _AgentToggleState();
}

class _AgentToggleState extends State<_AgentToggle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Tooltip(
      message: context.l10n.gameName(widget.agent.name),
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            curve: Settings.easeOut,
            opacity: widget.dimmed && !_hovered ? 0.55 : 1,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Settings.easeOut,
              width: _agentSize,
              height: _agentSize,
              padding: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                color: theme.card,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  width: 2,
                  color: widget.selected
                      ? Settings.accentInk
                      : _hovered
                          ? theme.input
                          : Colors.transparent,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Image.asset(widget.agent.iconPath, cacheWidth: 64),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MapTile extends StatefulWidget {
  const _MapTile({
    required this.map,
    required this.width,
    required this.selected,
    required this.onTap,
  });

  final MapValue map;
  final double width;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_MapTile> createState() => _MapTileState();
}

class _MapTileState extends State<_MapTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Settings.easeOut,
          width: widget.width,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              width: 2,
              color: widget.selected
                  ? Settings.accentInk
                  : _hovered
                      ? theme.input
                      : theme.border,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  'assets/maps/thumbnails/${Maps.mapNames[widget.map]}_thumbnail.webp',
                  fit: BoxFit.cover,
                  cacheWidth: 200,
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0xB3000000)],
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(7, 0, 4, 4),
                    child: Text(
                      context.l10n.mapName(widget.map),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SideButton extends StatefulWidget {
  const _SideButton({
    required this.side,
    required this.selected,
    required this.onTap,
  });

  final CommunitySide side;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SideButton> createState() => _SideButtonState();
}

class _SideButtonState extends State<_SideButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final color = widget.side == CommunitySide.attack
        ? Settings.attackColor
        : Settings.defenderColor;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Settings.easeOut,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hovered ? theme.input : theme.secondary,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              width: 2,
              color: widget.selected ? Settings.accentInk : Colors.transparent,
            ),
          ),
          child: Text(
            _sideLabel(context.l10n, widget.side),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

/// A filter in the bar, removed with its ×.
class _Tag extends StatefulWidget {
  const _Tag({
    required this.label,
    required this.onRemove,
    this.leading,
    this.labelColor,
  });

  final String label;
  final Widget? leading;
  final Color? labelColor;
  final VoidCallback onRemove;

  @override
  State<_Tag> createState() => _TagState();
}

class _TagState extends State<_Tag> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        height: 32,
        padding:
            EdgeInsets.only(left: widget.leading == null ? 10 : 4, right: 4),
        decoration: BoxDecoration(
          color: theme.secondary,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.leading case final leading?) ...[
              leading,
              const SizedBox(width: 8),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 110),
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: widget.labelColor ?? theme.foreground,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Semantics(
              button: true,
              label: context.l10n.communityRemoveFilter(widget.label),
              child: GestureDetector(
                onTap: widget.onRemove,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: Icon(
                      LucideIcons.x,
                      size: 14,
                      color:
                          _hovered ? theme.foreground : theme.mutedForeground,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MoreTags extends StatelessWidget {
  const _MoreTags({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.secondary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '+$count',
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.asset, required this.width});

  final String asset;
  final double width;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: Image.asset(
        asset,
        width: width,
        height: 24,
        fit: BoxFit.cover,
        cacheWidth: (width * 3).round(),
      ),
    );
  }
}

class _SortButton extends ConsumerWidget {
  const _SortButton({required this.menu});

  final ShadPopoverController menu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const theme = Settings.tacticalVioletTheme;
    final l10n = context.l10n;
    final sort = ref.watch(communityFilterProvider.select((f) => f.sort));
    String label(CommunitySort value) => switch (value) {
          CommunitySort.trending => l10n.communitySortTrending,
          CommunitySort.newest => l10n.communitySortNewest,
          CommunitySort.top => l10n.communitySortTop,
        };
    return ShadPopover(
      controller: menu,
      padding: const EdgeInsets.all(6),
      anchor: const ShadAnchor(
        offset: Offset(0, -8),
        childAlignment: Alignment.bottomRight,
        overlayAlignment: Alignment.topRight,
      ),
      popover: (context) => ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 168),
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final value in CommunitySort.values)
                ShadButton.ghost(
                  height: 32,
                  mainAxisAlignment: MainAxisAlignment.start,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  gap: 8,
                  onPressed: () {
                    menu.hide();
                    final filter = ref.read(communityFilterProvider.notifier);
                    filter.state = filter.state.copyWith(sort: value);
                  },
                  leading: SizedBox(
                    width: 18,
                    child: value == sort
                        ? const Icon(
                            LucideIcons.check,
                            size: 16,
                            color: Settings.accentInk,
                          )
                        : null,
                  ),
                  child: Text(
                    label(value),
                    style: TextStyle(color: theme.foreground),
                  ),
                ),
            ],
          ),
        ),
      ),
      child: ShadButton.secondary(
        key: const ValueKey('community-sort'),
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        gap: 8,
        // No outline inside the bar, but the button's own rounded corners.
        decoration: ShadDecoration(
          border: ShadBorder(radius: BorderRadius.circular(8)),
        ),
        onPressed: menu.toggle,
        leading: const Icon(LucideIcons.arrowDownWideNarrow, size: 16),
        child: Text(
          label(sort),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// Narrows the feed to the posts the reader starred.
class _StarredToggle extends StatelessWidget {
  const _StarredToggle({required this.on, required this.onTap});

  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final l10n = context.l10n;
    return Semantics(
      button: true,
      toggled: on,
      label: l10n.communityStarred,
      child: ShadTooltip(
        builder: (context) => Text(
          on ? l10n.communityShowAll : l10n.communityShowStarred,
        ),
        child: ShadButton.secondary(
          key: const ValueKey('community-starred'),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          gap: 8,
          decoration: ShadDecoration(
            border: ShadBorder(radius: BorderRadius.circular(8)),
          ),
          backgroundColor:
              on ? Settings.accentInk.withValues(alpha: 0.18) : null,
          onPressed: onTap,
          leading: CommunityStarGlyph(
            filled: on,
            color: on ? Settings.accentInk : theme.foreground,
          ),
          child: on
              ? Text(
                  l10n.communityStarred,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                )
              : null,
        ),
      ),
    );
  }
}
