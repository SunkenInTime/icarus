import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:icarus/const/settings.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.isSupported,
    required this.isUpdateAvailable,
    required this.source,
    this.remoteVersion,
    this.releaseNotes,
    this.errorCode,
    this.message,
  });

  final bool isSupported;
  final bool isUpdateAvailable;
  final String source;
  final String? remoteVersion;
  final String? releaseNotes;
  final int? errorCode;
  final String? message;
}

class UpdateChecker {
  static const MethodChannel _channel = MethodChannel('icarus/update_checker');
  static const int appVersionNumber = Settings.versionNumber;
  static const String versionInfoUrl =
      'https://sunkenintime.github.io/icarus/version.json';
  static const String _windowsStoreSchemeUrl =
      'ms-windows-store://pdp/?productid=9PBWHHZRQFW6';

  @visibleForTesting
  static Future<Map<String, dynamic>?> Function()? fetchVersionInfoOverride;
  @visibleForTesting
  static Future<Map<String, dynamic>> Function()? windowsStoreCheckOverride;

  static Future<Map<String, dynamic>?> fetchVersionInfo() async {
    final fetchOverride = fetchVersionInfoOverride;
    if (fetchOverride != null) return fetchOverride();

    try {
      final response = await http.get(Uri.parse(versionInfoUrl));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      } else {
        debugPrint('Failed to load version info: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('Error fetching version info: $e');
      return null;
    }
  }

  static Future<UpdateCheckResult> checkForUpdateSignal({
    bool? isWebOverride,
    bool? isWindowsOverride,
  }) async {
    final bool isWeb = isWebOverride ?? kIsWeb;
    final bool isWindows = isWindowsOverride ?? (!isWeb && Platform.isWindows);

    if (isWindows) {
      final windowsResult = await _checkWindowsStoreSignal();
      if (!windowsResult.isUpdateAvailable) {
        return windowsResult;
      }
      return _enrichResultWithRemoteInfo(windowsResult);
    }

    return _checkRemoteVersionSignal();
  }

  static Future<UpdateCheckResult> _checkWindowsStoreSignal() async {
    final callOverride = windowsStoreCheckOverride;

    try {
      final dynamic responseDynamic = callOverride != null
          ? await callOverride()
          : await _channel.invokeMethod<dynamic>('checkWindowsStoreUpdate');

      if (responseDynamic is! Map) {
        return const UpdateCheckResult(
          isSupported: false,
          isUpdateAvailable: false,
          source: 'windows_store',
          message: 'Unexpected Windows Store payload.',
        );
      }

      final response = Map<String, dynamic>.from(responseDynamic);
      return UpdateCheckResult(
        isSupported: response['isSupported'] == true,
        isUpdateAvailable: response['isUpdateAvailable'] == true,
        source: '${response['source'] ?? 'windows_store'}',
        errorCode: _toInt(response['errorCode']),
        message: response['message']?.toString(),
      );
    } on MissingPluginException {
      return const UpdateCheckResult(
        isSupported: false,
        isUpdateAvailable: false,
        source: 'windows_store',
        message: 'Windows Store checker plugin not available.',
      );
    } on PlatformException catch (e) {
      return UpdateCheckResult(
        isSupported: false,
        isUpdateAvailable: false,
        source: 'windows_store',
        errorCode: e.code.isEmpty ? null : int.tryParse(e.code),
        message: e.message,
      );
    } catch (e) {
      return UpdateCheckResult(
        isSupported: false,
        isUpdateAvailable: false,
        source: 'windows_store',
        message: '$e',
      );
    }
  }

  static Future<UpdateCheckResult> _checkRemoteVersionSignal() async {
    final versionInfo = await fetchVersionInfo();
    if (versionInfo == null) {
      return const UpdateCheckResult(
        isSupported: false,
        isUpdateAvailable: false,
        source: 'remote_version_file',
        message: 'Version info unavailable.',
      );
    }

    final int? remoteVersionNumber =
        int.tryParse('${versionInfo['current_version_number'] ?? ''}');
    if (remoteVersionNumber == null) {
      return const UpdateCheckResult(
        isSupported: false,
        isUpdateAvailable: false,
        source: 'remote_version_file',
        message: 'Invalid remote version number.',
      );
    }

    return UpdateCheckResult(
      isSupported: true,
      isUpdateAvailable: remoteVersionNumber > appVersionNumber,
      source: 'remote_version_file',
      remoteVersion: versionInfo['current_version']?.toString(),
      releaseNotes: versionInfo['release_notes']?.toString(),
    );
  }

  static Future<UpdateCheckResult> _enrichResultWithRemoteInfo(
      UpdateCheckResult baseResult) async {
    final versionInfo = await fetchVersionInfo();
    if (versionInfo == null) {
      return baseResult;
    }

    return UpdateCheckResult(
      isSupported: baseResult.isSupported,
      isUpdateAvailable: baseResult.isUpdateAvailable,
      source: baseResult.source,
      remoteVersion: versionInfo['current_version']?.toString(),
      releaseNotes: versionInfo['release_notes']?.toString(),
      errorCode: baseResult.errorCode,
      message: baseResult.message,
    );
  }

  static void showUpdateDialog(BuildContext context, UpdateCheckResult result) {
    final String remoteVersion = result.remoteVersion ?? Settings.versionName;
    final String releaseNotes =
        result.releaseNotes ?? 'An update is available in the Microsoft Store.';

    showDialog(
      context: context,
      builder: (BuildContext context) => ShadDialog.alert(
        title: const Text('Update Available'),
        description: Text(
          'A new version ($remoteVersion) is available.\n\n'
          'Release Notes: $releaseNotes',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: const Text('Later'),
          ),
          TextButton(
            onPressed: () async {
              final Uri storeUri = (result.source == 'windows_store')
                  ? Uri.parse(_windowsStoreSchemeUrl)
                  : Settings.windowsStoreLink;
              await launchUrl(storeUri);
              if (!context.mounted) return;

              Navigator.of(context).pop();
            },
            child: const Text('Update Now'),
          ),
        ],
      ),
    );
  }

  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }
}
