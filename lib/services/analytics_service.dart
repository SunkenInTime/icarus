import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:icarus/const/settings.dart';
import 'package:uuid/uuid.dart';

/// Minimal, anonymous product analytics.
///
/// This intentionally uses PostHog's capture endpoint directly so analytics
/// works on Windows, which the official Flutter SDK does not currently support.
/// It does not collect screen views, exceptions, session replays, user-provided
/// content, or person profiles.
class AnalyticsService {
  AnalyticsService._({http.Client? client}) : _client = client ?? http.Client();

  static final AnalyticsService instance = AnalyticsService._();

  static const String _projectToken = String.fromEnvironment(
    'POSTHOG_PROJECT_TOKEN',
  );
  static const String _host = String.fromEnvironment(
    'POSTHOG_HOST',
    defaultValue: 'https://us.i.posthog.com',
  );
  static const String _environment = String.fromEnvironment(
    'ICARUS_ANALYTICS_ENVIRONMENT',
    defaultValue: 'production',
  );
  static const String storageBoxName = 'anonymous_analytics';
  static const String _anonymousIdKey = 'anonymous_id';

  final http.Client _client;
  static const String _enabledKey = 'enabled';

  Box<dynamic>? _storage;
  String? _anonymousId;
  bool _enabled = true;

  bool get isConfigured => _projectToken.trim().isNotEmpty;
  bool get isEnabled => _enabled;

  Future<void> initialize() async {
    _storage = Hive.box<dynamic>(storageBoxName);
    _enabled = _storage!.get(_enabledKey, defaultValue: true) as bool;
    _anonymousId = _storage!.get(_anonymousIdKey);
    if (_anonymousId == null) {
      _anonymousId = const Uuid().v4();
      await _storage!.put(_anonymousIdKey, _anonymousId!);
    }

    unawaited(capture('app_opened'));
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await _storage?.put(_enabledKey, enabled);
    if (enabled) unawaited(capture('app_opened'));
  }

  Future<void> capture(
    String event, {
    Map<String, Object>? properties,
  }) async {
    final anonymousId = _anonymousId;
    if (!_enabled || !isConfigured || anonymousId == null) return;

    final payload = <String, Object>{
      'api_key': _projectToken,
      'event': event,
      'uuid': const Uuid().v4(),
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'properties': <String, Object>{
        'distinct_id': anonymousId,
        r'$process_person_profile': false,
        r'$geoip_disable': true,
        'app_version': Settings.versionName,
        'build_number': Settings.versionNumber,
        'release_channel': kResolvedUpdateChannel,
        'analytics_environment': _environment,
        'platform': _platformName,
        ...?properties,
      },
    };

    try {
      await _client
          .post(
            _captureUri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Analytics must never affect app behavior or surface errors to users.
    }
  }

  Uri get _captureUri {
    final normalizedHost = _host.trim().replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$normalizedHost/i/v0/e/');
  }

  String get _platformName {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.linux => 'linux',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }
}

final analyticsEnabledProvider =
    NotifierProvider<AnalyticsEnabledNotifier, bool>(
  AnalyticsEnabledNotifier.new,
);

class AnalyticsEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => AnalyticsService.instance.isEnabled;

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    await AnalyticsService.instance.setEnabled(enabled);
  }
}
