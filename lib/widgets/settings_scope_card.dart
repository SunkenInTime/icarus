import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class SettingsScopeCard extends StatelessWidget {
  const SettingsScopeCard({
    super.key,
    required this.title,
    this.description,
    required this.child,
    this.trailing,
  });

  final String title;
  final String? description;
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
                style: ShadTheme.of(context).textTheme.p.copyWith(
                      color: Settings.tacticalVioletTheme.foreground,
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      height: 1.25,
                    ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              trailing!,
            ],
          ],
        ),
        if (description != null) ...[
          const SizedBox(height: 4),
          Text(
            description!,
            style: ShadTheme.of(context).textTheme.small.copyWith(
                  color: Settings.tacticalVioletTheme.mutedForeground,
                  height: 1.35,
                ),
          ),
        ],
        child,
      ],
    );
  }
}
