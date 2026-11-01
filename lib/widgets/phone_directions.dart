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
const _allyInk = Color(0xFF69F0AE);

class PhoneDirectionMock extends ConsumerWidget {
  const PhoneDirectionMock({super.key, required this.dir, required this.state});

  final String dir;

  /// open, choose, placed, add, draw, pages or pick.
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
      body: dir == '3'
          ? _Rail(state: state, comp: five)
          : _Tray(state: state, comp: five),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn(
    this.icon, {
    this.active = false,
    this.primary = false,
    this.size = 44,
    this.dim = false,
  });

  final IconData icon;
  final bool active;

  /// The one command this screen is for.
  final bool primary;
  final double size;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: active || primary
          ? Settings.raisedPrimary(12)
          : BoxDecoration(borderRadius: BorderRadius.circular(12)),
      child: Icon(
        icon,
        size: primary ? 24 : 20,
        color: active || primary
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
        borderRadius: BorderRadius.circular(8),
      ),
      child: Image.asset(AgentData.agents[type]!.iconPath, fit: BoxFit.cover),
    );
  }
}

class _Ability extends StatelessWidget {
  const _Ability(this.type, this.index, {this.size = 44, this.active = false});

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
      padding: EdgeInsets.all(size * 0.15),
      decoration: active
          ? Settings.raisedPrimary(8)
          : BoxDecoration(
              color: _theme.secondary,
              borderRadius: BorderRadius.circular(8),
            ),
      child: index < abilities.length
          ? Image.asset(abilities[index].iconPath, fit: BoxFit.contain)
          : null,
    );
  }
}

BoxDecoration _card() => BoxDecoration(
      color: _theme.card,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: _theme.border),
    );

/// The page you're on by name, and a thumb's step either way. The name opens
/// the list.
class _Pager extends StatelessWidget {
  const _Pager();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: _card(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Btn(LucideIcons.chevronLeft, size: 42),
          SizedBox(
            width: 84,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Take A',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _theme.foreground,
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '2 of 3',
                      style: TextStyle(
                        fontSize: 11,
                        color: _theme.mutedForeground,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Icon(
                      LucideIcons.cloudCheck,
                      size: 12,
                      color: _theme.mutedForeground,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const _Btn(LucideIcons.chevronRight, size: 42),
        ],
      ),
    );
  }
}

class _PageList extends StatelessWidget {
  const _PageList();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 172,
      padding: const EdgeInsets.all(6),
      decoration: _card(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, name) in _pages.indexed)
            Container(
              height: 44,
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
            height: 44,
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

/// A button that holds its own on the map: a card behind it, a full thumb's
/// size.
class _CardBtn extends StatelessWidget {
  const _CardBtn(
    this.icon, {
    this.width = 52,
    this.height = 52,
    this.danger = false,
    this.dim = false,
  });

  final IconData icon;
  final double width;
  final double height;
  final bool danger;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: _card(),
      child: Icon(
        icon,
        size: 22,
        color: danger
            ? _theme.destructive
            : dim
                ? _theme.mutedForeground.withValues(alpha: 0.5)
                : _theme.foreground,
      ),
    );
  }
}

/// Drawing's kit, packed into the right thumb's corner. One tool lit at a
/// time, and Done is always the way back.
class _DrawKit extends StatelessWidget {
  const _DrawKit();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              width: 52,
              padding: const EdgeInsets.symmetric(vertical: 2),
              decoration: _card(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (i, option) in Settings.penColors.indexed)
                    SizedBox(
                      height: 42,
                      child: Center(
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: option.color,
                            shape: BoxShape.circle,
                            border: i == 0
                                ? Border.all(color: _theme.primary, width: 3)
                                : null,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Container(
              width: 52,
              padding: const EdgeInsets.symmetric(vertical: 2),
              decoration: _card(),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Btn(LucideIcons.type),
                  _Btn(LucideIcons.eraser),
                  _Btn(LucideIcons.spline),
                  _Btn(LucideIcons.moveUpRight, active: true),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          width: 110,
          height: 52,
          alignment: Alignment.center,
          decoration: _card(),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.check, size: 18, color: _theme.foreground),
              const SizedBox(width: 6),
              Text(
                'Done',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _theme.foreground,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _sideSwitch() {
  Widget side(String label, bool on) => Expanded(
        child: Container(
          height: 34,
          alignment: Alignment.center,
          decoration: on ? Settings.raisedSurface(8) : null,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: on ? _allyInk : _theme.mutedForeground,
            ),
          ),
        ),
      );
  return Row(children: [side('Ally', true), side('Enemy', false)]);
}

/// Every agent, small enough that none needs scrolling. Already on the team
/// is lit.
class _Roster extends StatelessWidget {
  const _Roster({required this.comp});

  final List<AgentType> comp;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 192,
      padding: const EdgeInsets.all(6),
      decoration: _card(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 3,
            runSpacing: 3,
            children: [
              for (final type in AgentData.agents.keys)
                _Agent(type, size: 33, active: comp.contains(type)),
            ],
          ),
          const SizedBox(height: 6),
          _sideSwitch(),
        ],
      ),
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

/// What every direction shares: the map, full bleed, and on the left thumb's
/// side undo and pages. Touching a stack of pieces zooms in until they part.
class _Bench extends StatelessWidget {
  const _Bench({required this.state, required this.comp, required this.child});

  final String state;
  final List<AgentType> comp;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final mapCentre = size.center(Offset.zero);
    final stack = mapCentre + const Offset(94, 30);
    final zoomed = state == 'pick';
    const map = RepaintBoundary(
      child: InteractiveMap(sideBarWidth: 0, showDeleteArea: false),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: zoomed
              ? Transform.translate(
                  offset: mapCentre - stack - const Offset(40, 20),
                  child: Transform.scale(
                    scale: 2.4,
                    alignment: Alignment(
                      stack.dx / size.width * 2 - 1,
                      stack.dy / size.height * 2 - 1,
                    ),
                    child: map,
                  ),
                )
              : map,
        ),
        if (state == 'draw')
          Positioned.fill(
            child: IgnorePointer(child: CustomPaint(painter: _StrokePainter())),
          ),
        if (state == 'placed') ...[
          Positioned(
            left: mapCentre.dx - 34,
            top: mapCentre.dy - 34,
            child: Container(
              width: 68,
              height: 68,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _theme.primary.withValues(alpha: 0.28),
                border: Border.all(color: _theme.primary, width: 2),
              ),
              child: _Ability(comp[3], 1, size: 34),
            ),
          ),
          Positioned(
            left: mapCentre.dx - 22,
            top: mapCentre.dy - 34 - 50,
            child: const _CardBtn(
              LucideIcons.trash2,
              width: 44,
              height: 44,
              danger: true,
            ),
          ),
        ],
        const Positioned(
          left: 6,
          top: 6,
          child: _CardBtn(LucideIcons.house, width: 44, height: 44),
        ),
        Positioned(
          left: 6,
          bottom: 6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state == 'pages')
                const _PageList()
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _CardBtn(LucideIcons.undo2, width: 64, height: 44),
                    const SizedBox(width: 6),
                    const _CardBtn(
                      LucideIcons.redo2,
                      width: 44,
                      height: 44,
                      dim: true,
                    ),
                    if (zoomed) ...[
                      const SizedBox(width: 6),
                      const _CardBtn(
                        LucideIcons.minimize2,
                        width: 44,
                        height: 44,
                      ),
                    ],
                  ],
                ),
              const SizedBox(height: 6),
              const _Pager(),
            ],
          ),
        ),
        if (state == 'draw')
          const Positioned(right: 6, bottom: 6, child: _DrawKit())
        else
          Positioned.fill(child: child),
      ],
    );
  }
}

/// A tile that places, named under it: a glyph alone doesn't say which smoke
/// it is.
class _Named extends StatelessWidget {
  const _Named({
    required this.tile,
    required this.name,
    this.width = 42,
    this.lines = 1,
  });

  final Widget tile;
  final String name;
  final double width;
  final int lines;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          tile,
          const SizedBox(height: 2),
          Text(
            name.split(' / ').first,
            maxLines: lines,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 9.5,
              height: 1.1,
              color: _theme.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

List<Widget> _placeable(AgentType type, {required double size}) {
  final agent = AgentData.agents[type]!;
  return [
    _Named(
      tile: _Agent(type, size: size),
      name: agent.name,
      width: size + 2,
      lines: 2,
    ),
    for (var i = 0; i < 4; i++)
      _Named(
        tile: _Ability(type, i, size: size),
        name: i < agent.abilities.length ? agent.abilities[i].name : '',
        width: size + 2,
        lines: 2,
      ),
  ];
}

/// Pieces under the finger after the zoom, named as what they are.
class _HereBar extends StatelessWidget {
  const _HereBar({required this.comp});

  final List<AgentType> comp;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 226,
      padding: const EdgeInsets.all(5),
      decoration: _card(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 3, bottom: 4),
            child: Text(
              'On the map here',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: _theme.mutedForeground,
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _Agent(comp[0], size: 40, active: true),
              _Agent(comp[1], size: 40),
              _Agent(comp[2], size: 40),
              _Ability(comp[3], 1, size: 40),
              const _CardBtn(
                LucideIcons.trash2,
                width: 40,
                height: 40,
                danger: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AddAgent extends StatelessWidget {
  const _AddAgent();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: _card(),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.plus, size: 18, color: _theme.foreground),
          Text(
            'Agent',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: _theme.foreground,
            ),
          ),
        ],
      ),
    );
  }
}

/// One shelf in the corner under the right thumb: the team's faces, and the
/// picked agent with its abilities below them, by name. It stays open while
/// you place, and shuts when you say.
class _Shelf extends StatelessWidget {
  const _Shelf({required this.comp});

  final List<AgentType> comp;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 226,
      padding: const EdgeInsets.all(5),
      decoration: _card(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: _sideSwitch()),
              const SizedBox(width: 4),
              Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: _theme.secondary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.plus, size: 14, color: _theme.foreground),
                    const SizedBox(width: 3),
                    Text(
                      'Agent',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _theme.foreground,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final (i, type) in comp.indexed)
                _Agent(type, size: 40, active: i == 3),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: _placeable(comp[3], size: 40),
          ),
        ],
      ),
    );
  }
}

/// Just the map until asked. The button opens a small shelf in the same
/// corner, and it stays open until you close it.
class _Tray extends StatelessWidget {
  const _Tray({required this.state, required this.comp});

  final String state;
  final List<AgentType> comp;

  @override
  Widget build(BuildContext context) {
    final shelf = state == 'choose' || state == 'placed';
    final open = shelf || state == 'add';
    return _Bench(
      state: state,
      comp: comp,
      child: Stack(
        children: [
          Positioned(
            right: 6,
            bottom: 6,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _CardBtn(LucideIcons.pencil),
                const SizedBox(width: 8),
                _Btn(
                  open ? LucideIcons.x : LucideIcons.plus,
                  primary: true,
                  size: 52,
                ),
              ],
            ),
          ),
          if (shelf)
            Positioned(right: 6, bottom: 64, child: _Shelf(comp: comp)),
          if (state == 'add')
            Positioned(right: 6, bottom: 64, child: _Roster(comp: comp)),
          if (state == 'pick')
            Positioned(right: 6, bottom: 64, child: _HereBar(comp: comp)),
        ],
      ),
    );
  }
}

/// The team's faces stand on the right edge, always there. Touch one and its
/// abilities stand beside it, off the map, until you touch another.
class _Rail extends StatelessWidget {
  const _Rail({required this.state, required this.comp});

  final String state;
  final List<AgentType> comp;

  @override
  Widget build(BuildContext context) {
    final adding = state == 'add';
    final working = state == 'choose' || state == 'placed';
    final agent = AgentData.agents[comp[3]]!;
    return _Bench(
      state: state,
      comp: comp,
      child: Stack(
        children: [
          Positioned(
            right: 6,
            bottom: 6,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _CardBtn(LucideIcons.pencil),
                const SizedBox(width: 8),
                adding ? const _CardBtn(LucideIcons.x) : const _AddAgent(),
              ],
            ),
          ),
          if (adding)
            Positioned(right: 6, bottom: 64, child: _Roster(comp: comp))
          else
            Positioned(
              right: 6,
              bottom: 64,
              child: Container(
                width: 52,
                padding: const EdgeInsets.all(4),
                decoration: _card(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (i, type) in comp.indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: _Agent(
                          type,
                          size: 42,
                          active: working && i == 3,
                        ),
                      ),
                    Container(
                      height: 30,
                      width: double.infinity,
                      alignment: Alignment.center,
                      decoration: Settings.raisedSurface(8),
                      child: const Text(
                        'Ally',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _allyInk,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (working)
            Positioned(
              right: 64,
              bottom: 64,
              child: Container(
                width: 56,
                padding: const EdgeInsets.all(4),
                decoration: _card(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Named(
                      tile: _Agent(comp[3], size: 36),
                      name: agent.name,
                      width: 46,
                    ),
                    for (var i = 0; i < 4; i++)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: _Named(
                          tile: _Ability(comp[3], i, size: 36),
                          name: i < agent.abilities.length
                              ? agent.abilities[i].name
                              : '',
                          width: 46,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (state == 'pick')
            Positioned(right: 64, bottom: 64, child: _HereBar(comp: comp)),
        ],
      ),
    );
  }
}
