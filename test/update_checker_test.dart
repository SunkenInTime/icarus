import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    UpdateChecker.fetchVersionInfoOverride = null;
    UpdateChecker.windowsStoreCheckOverride = null;
  });

  test('windows native signal returns update available', () async {
    UpdateChecker.windowsStoreCheckOverride = () async {
      return <String, dynamic>{
        'source': 'windows_store',
        'isSupported': true,
        'isUpdateAvailable': true,
      };
    };
    UpdateChecker.fetchVersionInfoOverride = () async {
      return <String, dynamic>{
        'current_version': '3.2.0',
        'current_version_number': '41',
        'release_notes': 'Store release notes',
      };
    };

    final result = await UpdateChecker.checkForUpdateSignal(
      isWebOverride: false,
      isWindowsOverride: true,
    );

    expect(result.isSupported, isTrue);
    expect(result.isUpdateAvailable, isTrue);
    expect(result.source, 'windows_store');
    expect(result.remoteVersion, '3.2.0');
    expect(result.releaseNotes, 'Store release notes');
  });

  test(
      'unsupported windows native signal does not use remote as update trigger',
      () async {
    UpdateChecker.windowsStoreCheckOverride = () async {
      return <String, dynamic>{
        'source': 'windows_store',
        'isSupported': false,
        'isUpdateAvailable': false,
        'message': 'No package identity',
      };
    };
    UpdateChecker.fetchVersionInfoOverride = () async {
      return <String, dynamic>{
        'current_version': '9.9.9',
        'current_version_number': '999',
        'release_notes': 'Test release',
      };
    };

    final result = await UpdateChecker.checkForUpdateSignal(
      isWebOverride: false,
      isWindowsOverride: true,
    );

    expect(result.source, 'windows_store');
    expect(result.isSupported, isFalse);
    expect(result.isUpdateAvailable, isFalse);
  });

  test('remote check handles invalid version number deterministically',
      () async {
    UpdateChecker.fetchVersionInfoOverride = () async {
      return <String, dynamic>{
        'current_version': '3.1.3',
        'current_version_number': 'not-an-int',
        'release_notes': 'Bad payload',
      };
    };

    final result = await UpdateChecker.checkForUpdateSignal(
      isWebOverride: true,
      isWindowsOverride: false,
    );

    expect(result.source, 'remote_version_file');
    expect(result.isSupported, isFalse);
    expect(result.isUpdateAvailable, isFalse);
  });

  test('provider exposes update result from checker service', () async {
    UpdateChecker.windowsStoreCheckOverride = () async {
      return <String, dynamic>{
        'source': 'windows_store',
        'isSupported': true,
        'isUpdateAvailable': true,
      };
    };
    UpdateChecker.fetchVersionInfoOverride = () async {
      return <String, dynamic>{
        'current_version': '9.9.9',
        'current_version_number': '999',
        'release_notes': 'Provider test release',
      };
    };

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final result = await container.read(appUpdateStatusProvider.future);

    expect(result.source, 'windows_store');
    expect(result.isUpdateAvailable, isTrue);
    expect(result.releaseNotes, 'Provider test release');
  });

  test('windows native checker exception returns safe non-crashing result',
      () async {
    UpdateChecker.windowsStoreCheckOverride = () async {
      throw Exception('simulated native failure');
    };

    final result = await UpdateChecker.checkForUpdateSignal(
      isWebOverride: false,
      isWindowsOverride: true,
    );

    expect(result.source, 'windows_store');
    expect(result.isSupported, isFalse);
    expect(result.isUpdateAvailable, isFalse);
    expect(result.message, isNotNull);
  });

  test('windows native checker platform exception returns safe result',
      () async {
    UpdateChecker.windowsStoreCheckOverride = () async {
      throw MissingPluginException('channel unavailable');
    };

    final result = await UpdateChecker.checkForUpdateSignal(
      isWebOverride: false,
      isWindowsOverride: true,
    );

    expect(result.source, 'windows_store');
    expect(result.isSupported, isFalse);
    expect(result.isUpdateAvailable, isFalse);
    expect(result.message, contains('not available'));
  });
}
