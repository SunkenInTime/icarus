import 'package:flutter/material.dart';
import 'package:icarus/ai/ai_chat_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class AiChatSheet extends StatelessWidget {
  const AiChatSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return ShadSheet(
      title: Text('AI Chat', style: ShadTheme.of(context).textTheme.h3),
      description: const Text('Ask Helios for a round plan or visual review.'),
      child: SizedBox(
        width: 520,
        height: 620,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: const AiChatView(),
        ),
      ),
    );
  }
}
