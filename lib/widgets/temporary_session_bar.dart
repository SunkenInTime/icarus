import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/dialogs/strategy/save_strategy_details_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class TemporarySessionBar extends ConsumerStatefulWidget {
  const TemporarySessionBar({super.key});

  @override
  ConsumerState<TemporarySessionBar> createState() =>
      _TemporarySessionBarState();
}

class _TemporarySessionBarState extends ConsumerState<TemporarySessionBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _slideAnim;
  bool _wasTemporary = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _fadeAnim = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    );
    _slideAnim = Tween<double>(begin: -1.0, end: 0.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _saveToOriginal() async {
    await ref
        .read(strategyProvider.notifier)
        .overwriteOriginalFromTemporaryCopy();
  }

  Future<void> _saveAsNew() async {
    final strategy = ref.read(strategyProvider);
    final notifier = ref.read(strategyProvider.notifier);
    final sourceName = strategy.stratName ?? 'Strategy';
    final sourceStrategy = notifier.currentStrategyData();
    final details = await showStrategySaveDetailsDialog(
      context: context,
      title: strategy.isQuickBoard ? 'Save Quick Board' : 'Save as New Strategy',
      confirmLabel: 'Save',
      initialName:
          strategy.isQuickBoard ? sourceName : '$sourceName (Copy)',
      initialFolderId: sourceStrategy?.folderID,
    );
    if (details == null) return;
    await notifier.saveTemporarySessionAsNewStrategy(
      name: details.name,
      folderID: details.folderId,
    );
  }

  Future<void> _exitDraft() async {
    final strategy = ref.read(strategyProvider);
    final confirmed = await _showExitConfirmation(
      isQuickBoard: strategy.isQuickBoard,
    );
    if (confirmed) {
      await ref.read(strategyProvider.notifier).discardTemporarySession();
    }
  }

  Future<bool> _showExitConfirmation({required bool isQuickBoard}) async {
    final accentColor = isQuickBoard
        ? Settings.quickBoardAccent
        : Settings.tempCopyAccent;

    final result = await showShadDialog<bool>(
      context: context,
      builder: (context) => ShadDialog(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isQuickBoard ? LucideIcons.zap : LucideIcons.penLine,
              size: 18,
              color: accentColor,
            ),
            const SizedBox(width: 8),
            Text(isQuickBoard
                ? 'Discard Quick Board?'
                : 'Discard Draft Changes?'),
          ],
        ),
        description: Text(
          isQuickBoard
              ? 'This Quick Board hasn\'t been saved. All changes will be lost.'
              : 'Unsaved changes to this draft will be lost. The original strategy will remain unchanged.',
        ),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(isQuickBoard ? 'Discard Board' : 'Discard Draft'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final strategy = ref.watch(strategyProvider);
    final isTemp = strategy.isTemporarySession;

    if (isTemp && !_wasTemporary) {
      _wasTemporary = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _animController.forward();
      });
    } else if (!isTemp && _wasTemporary) {
      _wasTemporary = false;
      _animController.reverse();
    } else if (isTemp && !_animController.isCompleted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_animController.isCompleted) {
          _animController.forward();
        }
      });
    }

    if (!isTemp && !_animController.isAnimating) {
      return const SizedBox.shrink();
    }

    final isQuickBoard = strategy.isQuickBoard;
    final accentColor =
        isQuickBoard ? Settings.quickBoardAccent : Settings.tempCopyAccent;
    final bgColor = isQuickBoard
        ? Settings.quickBoardAccentMuted
        : Settings.tempCopyAccentMuted;
    final fgColor = isQuickBoard
        ? Settings.quickBoardAccentForeground
        : Settings.tempCopyAccentForeground;

    final label = isQuickBoard ? 'Quick Board' : 'Draft Mode';
    final description = isQuickBoard
        ? 'Temporary workspace — save to keep your work'
        : 'Editing a copy of "${strategy.stratName ?? "Untitled"}"';
    final icon = isQuickBoard ? LucideIcons.zap : LucideIcons.penLine;

    return FadeTransition(
      opacity: _fadeAnim,
      child: AnimatedBuilder(
        animation: _slideAnim,
        builder: (context, child) => ClipRect(
          child: FractionalTranslation(
            translation: Offset(0, _slideAnim.value),
            child: child,
          ),
        ),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: bgColor,
            border: Border(
              bottom: BorderSide(
                color: accentColor.withValues(alpha: 0.2),
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 36,
                color: accentColor,
              ),
              const SizedBox(width: 12),
              Icon(icon, size: 15, color: accentColor),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  label,
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        color: accentColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                        letterSpacing: 0.3,
                      ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShadTheme.of(context).textTheme.small.copyWith(
                        color: fgColor.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                ),
              ),
              const SizedBox(width: 8),
              if (strategy.isTemporaryCopy) ...[
                _SessionBarButton(
                  onPressed: _saveToOriginal,
                  icon: LucideIcons.save,
                  label: 'Save to Original',
                  accentColor: accentColor,
                  isPrimary: true,
                ),
                const SizedBox(width: 6),
                _SessionBarButton(
                  onPressed: _saveAsNew,
                  icon: LucideIcons.filePlus,
                  label: 'Save as New',
                  accentColor: accentColor,
                  isPrimary: false,
                ),
              ] else ...[
                _SessionBarButton(
                  onPressed: _saveAsNew,
                  icon: LucideIcons.save,
                  label: 'Save Board',
                  accentColor: accentColor,
                  isPrimary: true,
                ),
              ],
              const SizedBox(width: 6),
              ShadTooltip(
                builder: (context) => Text(
                  isQuickBoard ? 'Discard board' : 'Discard draft',
                ),
                child: ShadIconButton.ghost(
                  onPressed: _exitDraft,
                  width: 28,
                  height: 28,
                  icon: Icon(LucideIcons.x, size: 14, color: fgColor.withValues(alpha: 0.5)),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionBarButton extends StatefulWidget {
  const _SessionBarButton({
    required this.onPressed,
    required this.icon,
    required this.label,
    required this.accentColor,
    required this.isPrimary,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String label;
  final Color accentColor;
  final bool isPrimary;

  @override
  State<_SessionBarButton> createState() => _SessionBarButtonState();
}

class _SessionBarButtonState extends State<_SessionBarButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.isPrimary
        ? widget.accentColor.withValues(alpha: _isHovered ? 0.25 : 0.15)
        : Colors.white.withValues(alpha: _isHovered ? 0.08 : 0.04);
    final fg = widget.isPrimary
        ? widget.accentColor
        : Colors.white.withValues(alpha: 0.7);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: widget.isPrimary
                ? Border.all(
                    color: widget.accentColor.withValues(alpha: 0.3),
                    width: 1,
                  )
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 13, color: fg),
              const SizedBox(width: 5),
              Text(
                widget.label,
                style: ShadTheme.of(context).textTheme.small.copyWith(
                      color: fg,
                      fontWeight:
                          widget.isPrimary ? FontWeight.w600 : FontWeight.w400,
                      fontSize: 12,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
