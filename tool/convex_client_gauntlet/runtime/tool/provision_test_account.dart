import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseKey = String.fromEnvironment('SUPABASE_KEY');

Future<void> main(List<String> arguments) async {
  if (supabaseUrl.isEmpty || supabaseKey.isEmpty || arguments.length != 1) {
    stderr.writeln(
      'Usage: dart --define=SUPABASE_URL=... --define=SUPABASE_KEY=... '
      'run tool/provision_test_account.dart <private output path>',
    );
    exitCode = 64;
    return;
  }

  final output = File(arguments.single);
  final random = Random.secure();
  final mailboxPassword = _randomSecret(random, 32);
  final accountPassword = '${_randomSecret(random, 24)}aA7!';
  final mailClient = http.Client();
  final supabase = SupabaseClient(
    supabaseUrl,
    supabaseKey,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );

  try {
    final domainResponse = await mailClient.get(
      Uri.parse('https://api.mail.tm/domains?page=1'),
    );
    _requireSuccess(domainResponse, 'list disposable mailbox domains');
    final domainBody = jsonDecode(domainResponse.body) as Map<String, dynamic>;
    final domains = domainBody['hydra:member'] as List<dynamic>;
    final domain = (domains.first as Map<String, dynamic>)['domain'] as String;
    final address =
        'icarus-gauntlet-${DateTime.now().microsecondsSinceEpoch}@$domain';

    final accountResponse = await mailClient.post(
      Uri.parse('https://api.mail.tm/accounts'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'address': address, 'password': mailboxPassword}),
    );
    _requireSuccess(accountResponse, 'create disposable mailbox');

    final tokenResponse = await mailClient.post(
      Uri.parse('https://api.mail.tm/token'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'address': address, 'password': mailboxPassword}),
    );
    _requireSuccess(tokenResponse, 'authenticate disposable mailbox');
    final mailToken =
        (jsonDecode(tokenResponse.body) as Map<String, dynamic>)['token']
            as String;

    await supabase.auth.signUp(
      email: address,
      password: accountPassword,
      data: const {'display_name': 'Icarus Convex gauntlet'},
    );

    final confirmationUrl = await _waitForConfirmation(
      client: mailClient,
      token: mailToken,
    );
    final confirmationRequest = http.Request('GET', confirmationUrl)
      ..followRedirects = false;
    final confirmationResponse = await mailClient.send(confirmationRequest);
    if (confirmationResponse.statusCode >= 400) {
      throw StateError(
        'Supabase confirmation failed with HTTP '
        '${confirmationResponse.statusCode}',
      );
    }

    final auth = await supabase.auth.signInWithPassword(
      email: address,
      password: accountPassword,
    );
    if (auth.session == null) {
      throw StateError('Confirmed test account did not produce a session');
    }

    await output.writeAsString(
      jsonEncode({'email': address, 'password': accountPassword}),
      flush: true,
    );
    await Process.run('chmod', ['600', output.path]);
    stdout.writeln('Disposable Supabase test account is confirmed and ready.');
  } finally {
    mailClient.close();
    await supabase.dispose();
  }
}

Future<Uri> _waitForConfirmation({
  required http.Client client,
  required String token,
}) async {
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  final headers = {'authorization': 'Bearer $token'};
  while (DateTime.now().isBefore(deadline)) {
    final messagesResponse = await client.get(
      Uri.parse('https://api.mail.tm/messages?page=1'),
      headers: headers,
    );
    _requireSuccess(messagesResponse, 'poll disposable mailbox');
    final body = jsonDecode(messagesResponse.body) as Map<String, dynamic>;
    final messages = body['hydra:member'] as List<dynamic>;
    if (messages.isNotEmpty) {
      final id = (messages.first as Map<String, dynamic>)['id'] as String;
      final messageResponse = await client.get(
        Uri.parse('https://api.mail.tm/messages/$id'),
        headers: headers,
      );
      _requireSuccess(messageResponse, 'read confirmation message');
      final message = jsonDecode(messageResponse.body) as Map<String, dynamic>;
      final source = <String>[
        if (message['text'] is String) message['text'] as String,
        if (message['html'] is List<dynamic>)
          ...(message['html'] as List<dynamic>).whereType<String>(),
      ].join('\n');
      final match = RegExp(
        r'''https://[^\s"'<>()\]]+/auth/v1/verify\?[^\s"'<>()\]]+''',
      ).firstMatch(source);
      if (match != null) {
        return Uri.parse(match.group(0)!.replaceAll('&amp;', '&'));
      }
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  throw TimeoutException('Supabase confirmation email did not arrive');
}

String _randomSecret(Random random, int length) {
  const alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return List.generate(
    length,
    (_) => alphabet[random.nextInt(alphabet.length)],
    growable: false,
  ).join();
}

void _requireSuccess(http.Response response, String operation) {
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError('$operation failed with HTTP ${response.statusCode}');
  }
}
