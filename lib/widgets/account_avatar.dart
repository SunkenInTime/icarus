import 'package:flutter/material.dart';

class AccountAvatar extends StatelessWidget {
  const AccountAvatar({
    super.key,
    required this.radius,
    required this.backgroundColor,
    required this.fallback,
    this.avatarUrl,
  });

  final double radius;
  final Color backgroundColor;
  final Widget fallback;
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    final image = avatarUrl == null ? null : NetworkImage(avatarUrl!);
    return CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor,
      foregroundImage: image,
      onForegroundImageError: image == null ? null : (_, __) {},
      child: fallback,
    );
  }
}
