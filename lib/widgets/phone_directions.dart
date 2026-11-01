// Throwaway mocks for choosing a phone editor direction. Nothing here is wired
// to touch: each `?dir=` and `?state=` draws one still, over the real map.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _theme = Settings.tacticalVioletTheme;
const _pages = ['Default', 'Take A', 'Retake'];

class PhoneDirectionMock extends ConsumerWidget {
  const PhoneDirectionMock({super.key, required this.dir, required this.state});

  final String dir;

  /// open, place, draw or pages.
  final String state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placed = ref.watch(agentProvider);
    final comp = <AgentType>[];
    for (final item in placed) {
      if (item.isAlly && !comp.contains(item.type)) comp.add(item.type);
    }
    for (final extra in AgentData.agents.keys) {
      if (comp.length >= 5) break;
      if (!comp.contains(extra)) comp.add(extra);
    }
    final five = comp.take(5).toList();
    return Scaffold(
      backgroundColor: _theme.background,
      body: switch (dir) {
        '1' => _Roster(state: state, comp: five),
        '2' => _Tray(state: state, comp: five),
        '3' => _Team(state: state, comp: five),
        _ => _Spot(state: state, comp: five),
      },
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn(this.icon,
      {this.active = false, this.size = 44, this.dim = false});

  final IconData icon;
  final bool active;
  final double size;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: active
          ? Settings.raisedPrimary(10)
          : BoxDecoration(borderRadius: BorderRadius.circular(10)),
      child: Icon(
        icon,
        size: 20,
        color: active
            ? Colors.white
            : dim
                ? _theme.mutedForeground.withValues(alpha: 0.45)
                : _theme.foreground,
      ),
    );
  }
}

class _Agent extends StatelessWidget {
  const _Agent(this.type, {this.size = 32, this.active = false});

  final AgentType type;
  final double size;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: active ? _theme.primary : _theme.secondary,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Image.asset(AgentData.agents[type]!.iconPath, fit: BoxFit.cover),
    );
  }
}

class _Ability extends StatelessWidget {
  const _Ability(this.type, this.index, {this.size = 34, this.active = false});

  final AgentType type;
  final int index;
  final double size;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final abilities = AgentData.agents[type]!.abilities;
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(5),
      decoration: active
          ? Settings.raisedPrimary(6)
          : BoxDecoration(
              color: _theme.secondary,
              borderRadius: BorderRadius.circular(6),
            ),
      child: index < abilities.length
          ? Image.asset(abilities[index].iconPath, fit: BoxFit.contain)
          : null,
    );
  }
}

/// Small enough to sit in a corner: where you are, and a thumb's step either
/// way. The number opens the list.
class _Pager extends StatelessWidget {
  const _Pager({this.vertical = false});

  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final count = Text(
      '2/3',
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: _theme.foreground,
      ),
    );
    final children = [
      _Btn(
        vertical ? LucideIcons.chevronUp : LucideIcons.chevronLeft,
        size: 40,
      ),
      SizedBox(
        width: vertical ? 40 : 30,
        height: vertical ? 24 : 40,
        child: Center(child: count),
      ),
      _Btn(
        vertical ? LucideIcons.chevronDown : LucideIcons.chevronRight,
        size: 40,
      ),
    ];
    return vertical
        ? Column(mainAxisSize: MainAxisSize.min, children: children)
        : Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}

class _PageList extends StatelessWidget {
  const _PageList({this.width = 170});

  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: _theme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _theme.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, name) in _pages.indexed)
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.centerLeft,
              decoration: i == 1 ? Settings.raisedSurface(8) : null,
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontSize: 13,
                        color: _theme.mutedForeground,
                      ),
                    ),
                  ),
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color:
                          i == 1 ? _theme.foreground : _theme.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Icon(LucideIcons.plus, size: 16, color: _theme.mutedForeground),
                const SizedBox(width: 6),
                Text(
                  'New page',
                  style: TextStyle(
                    fontSize: 14,
                    color: _theme.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Five colours and how the line ends: all a quick drawing needs.
class _DrawOptions extends StatelessWidget {
  const _DrawOptions({this.vertical = false});

  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final dots = [
      for (final (i, option) in Settings.penColors.indexed)
        Container(
          width: 32,
          height: 32,
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: option.color,
            shape: BoxShape.circle,
            border: i == 0 ? Border.all(color: _theme.primary, width: 3) : null,
          ),
        ),
    ];
    final strokes = [
      const _Btn(LucideIcons.moveUpRight, active: true, size: 40),
      const _Btn(LucideIcons.spline, size: 40),
      const _Btn(LucideIcons.type, size: 40),
      const _Btn(LucideIcons.eraser, size: 40),
    ];
    if (vertical) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(mainAxisSize: MainAxisSize.min, children: dots),
          const SizedBox(width: 6),
          Column(mainAxisSize: MainAxisSize.min, children: strokes),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(alignment: WrapAlignment.center, children: dots),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: strokes),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: _theme.card,
        border: Border.all(color: _theme.border),
      ),
      child: child,
    );
  }
}

/// A sample of what the state is doing on the map.
class _Ghost extends StatelessWidget {
  const _Ghost(this.left, this.top, this.child);

  final double left;
  final double top;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left,
      top: top,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _theme.primary.withValues(alpha: 0.35),
        ),
        child: child,
      ),
    );
  }
}

class _Stroke extends StatelessWidget {
  const _Stroke();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(child: CustomPaint(painter: _StrokePainter())),
    );
  }
}

class _StrokePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final a = Offset(size.width * 0.5 - 40, size.height * 0.72);
    final b = Offset(size.width * 0.5 + 60, size.height * 0.42);
    canvas.drawPath(
      Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(a.dx + 70, a.dy - 10, b.dx, b.dy),
      paint,
    );
    canvas.drawLine(b, b + const Offset(-14, 3), paint);
    canvas.drawLine(b, b + const Offset(-1, 14), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

Widget _map({bool stroke = false, Widget? ghost}) {
  return Stack(
    children: [
      const Positioned.fill(
        child: RepaintBoundary(
          child: InteractiveMap(sideBarWidth: 0, showDeleteArea: false),
        ),
      ),
      if (stroke) const _Stroke(),
      if (ghost != null) ghost,
    ],
  );
}

Widget _allyEnemy() {
  Widget side(String label, bool on) => Expanded(
        child: Container(
          height: 30,
          alignment: Alignment.center,
          decoration: on ? Settings.raisedSurface(6) : null,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: on ? const Color(0xFF69F0AE) : _theme.mutedForeground,
            ),
          ),
        ),
      );
  return Row(children: [side('Ally', true), side('Enemy', false)]);
}

/// Every agent on screen at once, at a size that fits them all, for building
/// fast with both thumbs.
class _Roster extends StatelessWidget {
  const _Roster({required this.state, required this.comp});

  final String state;
  final List<AgentType> comp;

  @override
  Widget build(BuildContext context) {
    final drawing = state == 'draw';
    final placing = state == 'place';
    final picked = comp.first;
    final grid = Wrap(
      spacing: 3,
      runSpacing: 3,
      children: [
        for (final type in AgentData.agents.keys)
          _Agent(type, size: 32, active: placing && type == picked),
      ],
    );
    final abilities = Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 0; i < 4; i++)
          _Ability(picked, i, size: 40, active: placing && i == 1),
      ],
    );
    return Row(
      children: [
        Container(
          width: 56,
          decoration: BoxDecoration(
            color: _theme.card,
            border: Border(right: BorderSide(color: _theme.border)),
          ),
          child: Column(
            children: [
              const _Btn(LucideIcons.house200),
              const _Btn(LucideIcons.cloudCheck200),
              _Btn(LucideIcons.pencil200, active: drawing),
              const Spacer(),
              const _Btn(LucideIcons.undo2200),
              const _Btn(LucideIcons.redo2200, dim: true),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              _map(
                stroke: drawing,
                ghost: placing
                    ? _Ghost(
                        250,
                        120,
                        _Ability(picked, 1, size: 32, active: true),
                      )
                    : null,
              ),
              Positioned(
                left: 8,
                bottom: 8,
                child: state == 'pages'
                    ? const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _PageList(),
                          SizedBox(height: 6),
                          _Pager(),
                        ],
                      )
                    : const _Pager(),
              ),
            ],
          ),
        ),
        _Panel(
          width: 186,
          child: drawing
              ? const Align(
                  alignment: Alignment.bottomCenter,
                  child: _DrawOptions(),
                )
              : Column(
                  children: [
                    _allyEnemy(),
                    const SizedBox(height: 6),
                    grid,
                    const Spacer(),
                    abilities,
                  ],
                ),
        ),
      ],
    );
  }
}

/// Just the map until asked: four buttons on one edge, and a tray that opens
/// over the empty margin beside the map.
class _Tray extends StatelessWidget {
  const _Tray({required this.state, required this.comp});

  final String state;
  final List<AgentType> comp;

  @override
  Widget build(BuildContext context) {
    final drawing = state == 'draw';
    final placing = state == 'place';
    final paging = state == 'pages';
    final picked = comp.first;
    return Stack(
      children: [
        Positioned.fill(
          child: _map(
            stroke: drawing,
            ghost: placing
                ? _Ghost(420, 110, _Ability(picked, 1, size: 32, active: true))
                : null,
          ),
        ),
        const Positioned(left: 6, top: 6, child: _Btn(LucideIcons.house200)),
        const Positioned(
          left: 6,
          top: 50,
          child: _Btn(LucideIcons.cloudCheck200),
        ),
        const Positioned(
          left: 6,
          bottom: 6,
          child: Column(
            children: [
              _Btn(LucideIcons.redo2200, dim: true),
              _Btn(LucideIcons.undo2200),
            ],
          ),
        ),
        Positioned(
          right: 6,
          bottom: 6,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Btn(LucideIcons.layers200, active: paging),
              _Btn(LucideIcons.pencil200, active: drawing),
              _Btn(LucideIcons.usersRound200, active: placing),
            ],
          ),
        ),
        if (placing)
          Positioned(
            right: 56,
            top: 0,
            bottom: 0,
            child: _Panel(
              width: 172,
              child: Column(
                children: [
                  Wrap(
                    spacing: 3,
                    runSpacing: 3,
                    children: [
                      for (final type in AgentData.agents.keys)
                        _Agent(type, size: 33, active: type == picked),
                    ],
                  ),
                  const Spacer(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (var i = 0; i < 4; i++)
                        _Ability(picked, i, size: 37, active: i == 1),
                    ],
                  ),
                ],
              ),
            ),
          ),
        if (drawing)
          const Positioned(
            right: 56,
            bottom: 6,
            child: _DrawOptions(vertical: false),
          ),
        if (paging) const Positioned(right: 56, bottom: 6, child: _PageList()),
      ],
    );
  }
}

/// This strategy's agents with their abilities in one block, one touch each,
/// since abilities are what gets placed over and over.
class _Team extends StatelessWidget {
  const _Team({required this.state, required this.comp});

  final String state;
  final List<AgentType> comp;

  @override
  Widget build(BuildContext context) {
    final drawing = state == 'draw';
    final placing = state == 'place';
    final paging = state == 'pages';
    final picked = comp.first;
    final team = Column(
      children: [
        _allyEnemy(),
        const SizedBox(height: 6),
        for (final type in comp)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _Agent(type, size: 40, active: placing && type == picked),
                for (var i = 0; i < 4; i++)
                  _Ability(
                    type,
                    i,
                    size: 40,
                    active: placing && type == picked && i == 1,
                  ),
              ],
            ),
          ),
        const Spacer(),
        Container(
          height: 40,
          decoration: BoxDecoration(
            color: _theme.secondary,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.plus, size: 16, color: _theme.foreground),
              const SizedBox(width: 6),
              Text(
                'Add an agent',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: _theme.foreground,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return Row(
      children: [
        Container(
          width: 56,
          decoration: BoxDecoration(
            color: _theme.card,
            border: Border(right: BorderSide(color: _theme.border)),
          ),
          child: Column(
            children: [
              const _Btn(LucideIcons.house200),
              const _Btn(LucideIcons.cloudCheck200),
              const Spacer(),
              _Btn(LucideIcons.pencil200, active: drawing),
              const _Btn(LucideIcons.redo2200, dim: true),
              const _Btn(LucideIcons.undo2200),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              _map(
                stroke: drawing,
                ghost: placing
                    ? _Ghost(
                        230,
                        120,
                        _Ability(picked, 1, size: 32, active: true),
                      )
                    : null,
              ),
              Positioned(
                left: 8,
                bottom: 6,
                child: paging
                    ? const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _PageList(),
                          SizedBox(height: 6),
                          _Pager(vertical: false),
                        ],
                      )
                    : const _Pager(vertical: false),
              ),
            ],
          ),
        ),
        _Panel(
          width: 232,
          child: drawing
              ? const Align(
                  alignment: Alignment.bottomCenter,
                  child: _DrawOptions(),
                )
              : team,
        ),
      ],
    );
  }
}

/// No panels: touch the place on the map, then choose what goes there, so a
/// finger never drags across the screen.
class _Spot extends StatelessWidget {
  const _Spot({required this.state, required this.comp});

  final String state;
  final List<AgentType> comp;

  @override
  Widget build(BuildContext context) {
    final drawing = state == 'draw';
    final placing = state == 'place';
    final paging = state == 'pages';
    return Stack(
      children: [
        Positioned.fill(
          child: _map(
            stroke: drawing,
            ghost: placing
                ? Positioned(
                    left: 330,
                    top: 150,
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _theme.primary.withValues(alpha: 0.4),
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  )
                : null,
          ),
        ),
        const Positioned(left: 6, top: 6, child: _Btn(LucideIcons.house200)),
        const Positioned(
          left: 6,
          top: 50,
          child: _Btn(LucideIcons.cloudCheck200),
        ),
        const Positioned(
          left: 6,
          bottom: 6,
          child: Column(
            children: [
              _Btn(LucideIcons.redo2200, dim: true),
              _Btn(LucideIcons.undo2200),
            ],
          ),
        ),
        Positioned(
          right: 6,
          top: 6,
          child: _Btn(LucideIcons.pencil200, active: drawing),
        ),
        if (drawing)
          const Positioned(
            right: 8,
            top: 54,
            child: _DrawOptions(vertical: true),
          ),
        Positioned(
            right: 6, bottom: 6, child: paging ? _pagesOpen() : const _Pager()),
        if (placing)
          Positioned(
            left: 372,
            top: 40,
            child: Container(
              width: 232,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: _theme.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _theme.border),
                boxShadow: const [
                  BoxShadow(blurRadius: 24, color: Color(0x47000000)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final type in comp)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _Agent(type, size: 40),
                          for (var i = 0; i < 4; i++)
                            _Ability(type, i, size: 40),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _pagesOpen() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [_PageList(), SizedBox(height: 6), _Pager()],
    );
  }
}
