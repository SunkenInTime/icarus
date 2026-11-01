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
                Text(
                  '2 of 3',
                  style: TextStyle(
                    fontSize: 11,
                    color: _theme.mutedForeground,
                  ),
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
  const _CardBtn(this.icon,
      {this.width = 52, this.height = 52, this.danger = false});

  final IconData icon;
  final double width;
  final double height;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: _card(),
      child: Icon(
        icon,
        size: 22,
        color: danger ? _theme.destructive : _theme.foreground,
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

/// This strategy's team, each row the agent then its abilities, all of them
/// tiles that place. The agent you used last sits at the foot, by the thumb.
class _TeamGrid extends StatelessWidget {
  const _TeamGrid({required this.comp});

  final List<AgentType> comp;

  @override
  Widget build(BuildContext context) {
    final recent = comp[3];
    return Container(
      width: 216,
      padding: const EdgeInsets.all(5),
      decoration: _card(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final type in comp)
            if (type != recent)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Opacity(
                  opacity: 0.7,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _Agent(type, size: 39),
                      for (var a = 0; a < 4; a++) _Ability(type, a, size: 39),
                    ],
                  ),
                ),
              ),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 3),
            decoration: BoxDecoration(
              color: _theme.accent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _Agent(recent, size: 39),
                for (var a = 0; a < 4; a++) _Ability(recent, a, size: 39),
              ],
            ),
          ),
          const SizedBox(height: 4),
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
/// side the way out, the sync state, undo and pages.
class _Bench extends StatelessWidget {
  const _Bench({required this.state, required this.comp, required this.child});

  final String state;
  final List<AgentType> comp;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mapCentre = MediaQuery.sizeOf(context).center(Offset.zero);
    final cluster = mapCentre + const Offset(94, 30);
    return Stack(
      children: [
        const Positioned.fill(
          child: RepaintBoundary(
            child: InteractiveMap(sideBarWidth: 0, showDeleteArea: false),
          ),
        ),
        if (state == 'draw')
          Positioned.fill(
            child: IgnorePointer(child: CustomPaint(painter: _StrokePainter())),
          ),
        if (state == 'placed')
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
        if (state == 'pick')
          Positioned(
            left: cluster.dx - 30,
            top: cluster.dy - 30,
            child: Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        const Positioned(
          left: 6,
          top: 6,
          child: Column(
            children: [
              _Btn(LucideIcons.house200),
              _Btn(LucideIcons.cloudCheck200),
            ],
          ),
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
                    const _CardBtn(LucideIcons.undo2, width: 85, height: 44),
                    const SizedBox(width: 6),
                    Opacity(
                      opacity: 0.5,
                      child: const _CardBtn(
                        LucideIcons.redo2,
                        width: 85,
                        height: 44,
                      ),
                    ),
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

/// The pieces under a finger, pulled apart, when a touch lands on a stack.
class _PickCard extends StatelessWidget {
  const _PickCard({required this.comp});

  final List<AgentType> comp;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: _card(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, type) in comp.take(3).indexed)
            Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
              child: _Agent(type, size: 46),
            ),
          const SizedBox(width: 4),
          _Ability(comp[3], 1, size: 46),
        ],
      ),
    );
  }
}

/// Another of the same, a touch away, with the bin beside the thumb while
/// something is picked up.
class _Recent extends StatelessWidget {
  const _Recent({required this.comp});

  final List<AgentType> comp;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: _card(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 4; i++)
            Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 3),
              child: _Ability(comp[3], i, size: 44),
            ),
        ],
      ),
    );
  }
}

/// Just the map until asked. One button opens the team's abilities, and what
/// you used last stays one touch away after you place it.
class _Tray extends StatelessWidget {
  const _Tray({required this.state, required this.comp});

  final String state;
  final List<AgentType> comp;

  @override
  Widget build(BuildContext context) {
    final open = state == 'choose' || state == 'add';
    final holding = state == 'placed' || state == 'pick';
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
                holding
                    ? const _CardBtn(LucideIcons.trash2, danger: true)
                    : const _CardBtn(LucideIcons.pencil),
                const SizedBox(width: 8),
                _Btn(
                  open ? LucideIcons.x : LucideIcons.plus,
                  primary: true,
                  size: 52,
                ),
              ],
            ),
          ),
          if (state == 'choose')
            Positioned(right: 6, bottom: 64, child: _TeamGrid(comp: comp)),
          if (state == 'add')
            Positioned(right: 6, bottom: 64, child: _Roster(comp: comp)),
          if (state == 'placed')
            Positioned(right: 6, bottom: 64, child: _Recent(comp: comp)),
          if (state == 'pick')
            Positioned(right: 6, top: 96, child: _PickCard(comp: comp)),
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
    final holding = state == 'placed' || state == 'pick';
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
                holding
                    ? const _CardBtn(LucideIcons.trash2, danger: true)
                    : const _CardBtn(LucideIcons.pencil),
                const SizedBox(width: 8),
                _CardBtn(adding ? LucideIcons.x : LucideIcons.userPlus),
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
                    Container(
                      height: 30,
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
                    const SizedBox(height: 4),
                    for (final (i, type) in comp.indexed)
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : 3),
                        child: _Agent(
                          type,
                          size: 44,
                          active: working && i == 3,
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
                width: 52,
                padding: const EdgeInsets.all(4),
                decoration: _card(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Agent(comp[3], size: 44),
                    for (var i = 0; i < 4; i++)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: _Ability(comp[3], i),
                      ),
                  ],
                ),
              ),
            ),
          if (state == 'pick')
            Positioned(
              right: 64,
              bottom: 64,
              child: Container(
                width: 52,
                padding: const EdgeInsets.all(4),
                decoration: _card(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (i, type) in comp.take(3).indexed)
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : 3),
                        child: _Agent(type, size: 44),
                      ),
                    const SizedBox(height: 3),
                    _Ability(comp[3], 1),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
