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

  String? _statusText;

  String? get statusText => _statusText;

  void _setStatus(String? text) {
    if (_statusText == text) return;
    _statusText = text;
    notifyListeners();
  }

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
    _setStatus('Helios is thinking...');
    final userMessage = ChatMessage.user(prompt, attachments);
    final llmMessage = ChatMessage.llm();
    _history.addAll([userMessage, llmMessage]);

    final response = _sendMessageStream(
      prompt: prompt,
      attachments: attachments,
      chat: _chat!,
    );

    try {
      yield* response.map((chunk) {
        llmMessage.append(chunk);
        return chunk;
      });
    } finally {
      _setStatus(null);
      notifyListeners();
    }
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
          // As soon as we have real model text, hide any "thinking/tool" status.
          if (statusText != null) _setStatus(null);
          yield chunk.text!;
        }
        if (chunk.functionCalls.isNotEmpty) {
          functionCalls.addAll(chunk.functionCalls);
        }
      }

      if (functionCalls.isEmpty) {
        break;
      }

      // Do not yield a newline here.
      // If we yield any text, flutter_ai_toolkit will treat the pending LLM
      // message as non-null and the built-in "jumping dots" loader disappears
      // while tools are executing.

      final functionResponses = <FunctionResponse>[];
      final extraParts = <Part>[];

      for (final functionCall in functionCalls) {
        _setStatus(_statusForTool(functionCall.name));
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

      _setStatus('Helios is analyzing...');
      responseStream = chat.sendMessageStream(
        Content('function', [...functionResponses, ...extraParts]),
      );
    }
  }

  static String _statusForTool(String toolName) {
    switch (toolName) {
      case 'get_visible_round':
        return 'Checking visible round...';
      case 'get_active_page':
        return 'Checking active page...';
      case 'get_roster':
        return 'Loading roster...';
      case 'get_round_kills':
        return 'Loading kill timeline...';
      case 'take_current_screenshot':
      case 'take_page_screenshot':
        return 'Capturing screenshot...';
      default:
        return 'Executing $toolName...';
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
