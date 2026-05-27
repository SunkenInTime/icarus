import 'package:flutter_riverpod/flutter_riverpod.dart';

enum DeleteMenuOpenReason {
  hover,
  click,
  keyboard,
}

class DeleteMenuState {
  const DeleteMenuState({
    required this.isOpenRequested,
    required this.reason,
    required this.requestId,
  });

  final bool isOpenRequested;
  final DeleteMenuOpenReason? reason;
  final int requestId;

  DeleteMenuState copyWith({
    bool? isOpenRequested,
    DeleteMenuOpenReason? reason,
    int? requestId,
    bool clearReason = false,
  }) {
    return DeleteMenuState(
      isOpenRequested: isOpenRequested ?? this.isOpenRequested,
      reason: clearReason ? null : (reason ?? this.reason),
      requestId: requestId ?? this.requestId,
    );
  }
}

final deleteMenuProvider =
    NotifierProvider<DeleteMenuNotifier, DeleteMenuState>(
  DeleteMenuNotifier.new,
);

class DeleteMenuNotifier extends Notifier<DeleteMenuState> {
  @override
  DeleteMenuState build() {
    return const DeleteMenuState(
      isOpenRequested: false,
      reason: null,
      requestId: 0,
    );
  }

  void requestOpen({required DeleteMenuOpenReason reason}) {
    state = DeleteMenuState(
      isOpenRequested: true,
      reason: reason,
      requestId: state.requestId + 1,
    );
  }

  void requestClose() {
    state = DeleteMenuState(
      isOpenRequested: false,
      reason: null,
      requestId: state.requestId + 1,
    );
  }
}
