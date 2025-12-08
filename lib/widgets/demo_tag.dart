import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/demo_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DemoTag extends ConsumerWidget {
  const DemoTag({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    const accent = Colors.red;

    return InkWell(
      onTap: () async {
        await showShadDialog<void>(
          context: context,
          builder: (context) {
            return const DemoDialog();
          },
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: accent.withAlpha(31), // 0.12
          border: Border.all(color: accent, width: 1.5),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: accent.withAlpha(64), // 0.25
              blurRadius: 8,
              spreadRadius: 1,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.science_outlined,
              size: 14,
              color: Colors.white.withAlpha(230), // 0.9
            ),
            const SizedBox(width: 6),
            Text(
              'DEMO',
              style: theme.textTheme.labelMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ) ??
                  const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
