import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';

class IcarusFunctionCallResult {
  const IcarusFunctionCallResult(
      {required this.response, this.extraParts = const []});

  final Map<String, Object?> response;

  /// Extra parts to include with the function response turn.
  ///
  /// This is primarily used to attach an image (InlineDataPart) after a
  /// screenshot tool call so the model can do vision.
  final List<Part> extraParts;
}

/// A Firebase AI provider like flutter_ai_toolkit's [FirebaseProvider], but
/// allows attaching extra Parts (e.g. screenshots) to the function-response turn.
class IcarusFirebaseProvider extends LlmProvider with ChangeNotifier {
  IcarusFirebaseProvider({
    required GenerativeModel model,
    Iterable<ChatMessage>? history,
    List<SafetySetting>? chatSafetySettings,
    GenerationConfig? chatGenerationConfig,
    Future<IcarusFunctionCallResult?> Function(FunctionCall)? onFunctionCall,
  })  : _model = model,
        _history = history?.toList() ?? [],
        _chatSafetySettings = chatSafetySettings,
        _chatGenerationConfig = chatGenerationConfig,
        _onFunctionCall = onFunctionCall {
    _chat = _startChat(history);
  }

  final GenerativeModel _model;
  final List<SafetySetting>? _chatSafetySettings;
  final GenerationConfig? _chatGenerationConfig;
  final List<ChatMessage> _history;
  final Future<IcarusFunctionCallResult?> Function(FunctionCall)?
      _onFunctionCall;
  ChatSession? _chat;

  @override
  Stream<String> generateStream(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) =>
      _sendMessageStream(
        prompt: prompt,
        attachments: attachments,
        // For one-off generation we create an isolated chat session.
        chat: _startChat(null)!,
      );

  @override
  Stream<String> sendMessageStream(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) async* {
    final userMessage = ChatMessage.user(prompt, attachments);
    final llmMessage = ChatMessage.llm();
    _history.addAll([userMessage, llmMessage]);

    final response = _sendMessageStream(
      prompt: prompt,
      attachments: attachments,
      chat: _chat!,
    );

    yield* response.map((chunk) {
      llmMessage.append(chunk);
      return chunk;
    });

    notifyListeners();
  }

  Stream<String> _sendMessageStream({
    required String prompt,
    required Iterable<Attachment> attachments,
    required ChatSession chat,
  }) async* {
    final content = Content('user', [
      TextPart(prompt),
      ...attachments.map(_partFrom),
    ]);

    var responseStream = chat.sendMessageStream(content);

    while (true) {
      final functionCalls = <FunctionCall>[];

      await for (final chunk in responseStream) {
        if (chunk.text != null) {
          yield chunk.text!;
        }
        if (chunk.functionCalls.isNotEmpty) {
          functionCalls.addAll(chunk.functionCalls);
        }
      }

      if (functionCalls.isEmpty) {
        break;
      }

      yield '\n';

      final functionResponses = <FunctionResponse>[];
      final extraParts = <Part>[];

      for (final functionCall in functionCalls) {
        try {
          final result = await _onFunctionCall?.call(functionCall);
          functionResponses.add(
            FunctionResponse(functionCall.name, result?.response ?? {}),
          );
          if (result != null && result.extraParts.isNotEmpty) {
            extraParts.addAll(result.extraParts);
          }
        } catch (ex) {
          functionResponses.add(
            FunctionResponse(functionCall.name, {'error': ex.toString()}),
          );
        }
      }

      responseStream = chat.sendMessageStream(
        Content('function', [...functionResponses, ...extraParts]),
      );
    }
  }

  @override
  Iterable<ChatMessage> get history => _history;

  @override
  set history(Iterable<ChatMessage> history) {
    _history
      ..clear()
      ..addAll(history);
    _chat = _startChat(history);
    notifyListeners();
  }

  ChatSession? _startChat(Iterable<ChatMessage>? history) => _model.startChat(
        history: history?.map(_contentFrom).toList(),
        safetySettings: _chatSafetySettings,
        generationConfig: _chatGenerationConfig,
      );

  static Part _partFrom(Attachment attachment) => switch (attachment) {
        (final FileAttachment a) => InlineDataPart(a.mimeType, a.bytes),
        (final LinkAttachment a) => TextPart(a.url.toString()),
      };

  static Content _contentFrom(ChatMessage message) => Content(
        message.origin.isUser ? 'user' : 'model',
        [TextPart(message.text ?? ''), ...message.attachments.map(_partFrom)],
      );
}
