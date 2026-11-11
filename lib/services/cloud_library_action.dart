import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';

enum CloudLibraryActionStatus {
  succeeded,
  cancelled,
  authenticationRequired,
  failed,
}

class CloudLibraryActionResult {
  const CloudLibraryActionResult._(this.status, {this.userMessage});

  static const succeeded = CloudLibraryActionResult._(
    CloudLibraryActionStatus.succeeded,
  );
  static const cancelled = CloudLibraryActionResult._(
    CloudLibraryActionStatus.cancelled,
  );
  factory CloudLibraryActionResult.authenticationRequired(
    AppLocalizations l10n,
  ) =>
      CloudLibraryActionResult._(
        CloudLibraryActionStatus.authenticationRequired,
        userMessage: l10n.cloudActionReconnect,
      );

  factory CloudLibraryActionResult.failed(String userMessage) =>
      CloudLibraryActionResult._(
        CloudLibraryActionStatus.failed,
        userMessage: userMessage,
      );

  final CloudLibraryActionStatus status;
  final String? userMessage;

  bool get didSucceed => status == CloudLibraryActionStatus.succeeded;
  bool get wasCancelled => status == CloudLibraryActionStatus.cancelled;
}

final cloudLibraryActionReporterProvider = Provider<CloudLibraryActionReporter>(
  (ref) => CloudLibraryActionReporter(l10n: ref.watch(l10nProvider)),
);

class CloudLibraryActionReporter {
  const CloudLibraryActionReporter({
    this.l10n,
    this.showMessage = _showDefaultMessage,
    this.reportTechnicalFailure = _reportDefaultTechnicalFailure,
  });

  /// The words for [CloudLibraryActionResult.authenticationRequired];
  /// English when none are given.
  final AppLocalizations? l10n;

  final void Function(String message) showMessage;
  final void Function({
    required String source,
    required Object error,
    required StackTrace stackTrace,
  }) reportTechnicalFailure;

  Future<CloudLibraryActionResult> run({
    required Future<bool> Function() action,
    required String source,
    required String failureMessage,
    required Future<void> Function(Object error, StackTrace stackTrace)
        reportAuthenticationFailure,
    bool showFailureMessage = false,
  }) async {
    try {
      final completed = await action();
      return completed
          ? CloudLibraryActionResult.succeeded
          : CloudLibraryActionResult.cancelled;
    } catch (error, stackTrace) {
      if (isConvexUnauthenticatedError(error)) {
        await reportAuthenticationFailure(error, stackTrace);
        return CloudLibraryActionResult.authenticationRequired(
          l10n ?? lookupAppLocalizations(const Locale('en')),
        );
      }

      reportTechnicalFailure(
        source: source,
        error: error,
        stackTrace: stackTrace,
      );
      if (showFailureMessage) {
        showMessage(failureMessage);
      }
      return CloudLibraryActionResult.failed(failureMessage);
    }
  }

  static void _showDefaultMessage(String message) {
    Settings.showToast(
      message: message,
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  }

  static void _reportDefaultTechnicalFailure({
    required String source,
    required Object error,
    required StackTrace stackTrace,
  }) {
    AppErrorReporter.reportError(
      'Cloud library action failed.',
      source: source,
      error: error,
      stackTrace: stackTrace,
      promptUser: false,
    );
  }
}
