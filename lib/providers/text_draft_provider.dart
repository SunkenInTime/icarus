import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/text_provider.dart';

final textDraftProvider =
    NotifierProvider<TextDraftProvider, Map<String, String>>(
  TextDraftProvider.new,
);

class TextDraftProvider extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() {
    return {};
  }

  void setDraft(String id, String text) {
    state = {
      ...state,
      id: text,
    };
  }

  String? draftFor(String id) {
    return state[id];
  }

  void clearDraft(String id) {
    if (!state.containsKey(id)) return;

    final nextState = {...state}..remove(id);
    state = nextState;
  }

  void clearAllDrafts() {
    if (state.isEmpty) return;
    state = {};
  }

  void commitDraft(String id) {
    final draft = state[id];
    if (draft == null) return;

    final texts = ref.read(textProvider);
    final index = texts.indexWhere((element) => element.id == id);
    if (index < 0) {
      clearDraft(id);
      return;
    }

    final committedText = texts[index].text;
    if (draft == committedText) {
      clearDraft(id);
      return;
    }

    ref.read(textProvider.notifier).commitText(id, draft);
    clearDraft(id);
  }

  void commitAllDrafts() {
    final ids = state.keys.toList(growable: false);
    for (final id in ids) {
      commitDraft(id);
    }
  }
}
