import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';

void main() {
  test('an email in a failure never reaches the log', () {
    final entry = AppErrorReporter.addDebugLog(
      'Email/password sign-up failed.',
      level: DebugLogLevel.warning,
      source: 'auth',
      // Supabase quotes the address it refused.
      error: 'AuthApiException(message: Unable to send email to '
          'sam.o-neil+icarus@mail.example.co.uk, statusCode: 500)',
      stackTrace: StackTrace.fromString('#0 resetFor(sam@example.com)'),
    );

    final text = entry.toClipboardText();
    expect(text, isNot(contains('@')));
    expect(
      text,
      contains('Unable to send email to <email>, statusCode: 500'),
    );
    expect(text, contains('#0 resetFor(<email>)'));
  });
}
