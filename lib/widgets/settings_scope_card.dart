import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum SettingsScope {
  strategy,
  workspace,
}

class SettingsScopeCard extends StatelessWidget {
  const SettingsScopeCard({
    super.key,
    required this.scope,
    required this.title,
    required this.description,
    required this.child,
    this.trailing,
  });

  final SettingsScope scope;
  final String title;
  final String description;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: ShadTheme.of(context)
                    .textTheme
                    .lead
                    .copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              trailing!,
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '$description ${_scopeDescription(scope)}',
          style: ShadTheme.of(context).textTheme.small.copyWith(
                color: Settings.tacticalVioletTheme.mutedForeground,
                height: 1.35,
              ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

String _scopeDescription(SettingsScope scope) {
  switch (scope) {
    case SettingsScope.strategy:
      return 'Saved with this strategy.';
    case SettingsScope.workspace:
      return 'Only affects this workspace.';
  }
}
