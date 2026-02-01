import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:icarus/const/ai_models.dart';

class AiChatView extends StatelessWidget {
  const AiChatView({super.key});

  @override
  Widget build(BuildContext context) {
    return LlmChatView(
      provider: FirebaseProvider(
        model: FirebaseAI.googleAI().generativeModel(
          model: AiModels.geminiFlash,
        ),
      ),
      enableAttachments: false,
      enableVoiceNotes: false,
      autofocus: true,
    );
  }
}
