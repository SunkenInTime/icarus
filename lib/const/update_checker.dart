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
    this.updateTitle,
    this.releaseNotes,
    this.features,
    this.errorCode,
    this.message,
  });

  final bool isSupported;
  final bool isUpdateAvailable;
  final String source;
  final String? remoteVersion;
  final String? updateTitle;
  final String? releaseNotes;
  final List<String>? features;
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
      if (windowsResult.isSupported) {
        if (!windowsResult.isUpdateAvailable) {
          return windowsResult;
        }
        return _enrichResultWithRemoteInfo(windowsResult);
      }

      final remoteResult = await _checkRemoteVersionSignal();
      if (!remoteResult.isSupported) {
        return windowsResult;
      }
      return remoteResult;
    }

    return _checkRemoteVersionSignal();
  }

  static Future<UpdateCheckResult> checkForWindowsStoreUpdateSignal({
    bool? isWebOverride,
    bool? isWindowsOverride,
  }) async {
    final bool isWeb = isWebOverride ?? kIsWeb;
    final bool isWindows = isWindowsOverride ?? (!isWeb && Platform.isWindows);

    if (!isWindows) {
      return _checkRemoteVersionSignal();
    }

    final windowsResult = await _checkWindowsStoreSignal();
    if (!windowsResult.isSupported || !windowsResult.isUpdateAvailable) {
      return windowsResult;
    }

    return _enrichResultWithRemoteInfo(windowsResult);
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

    final int? remoteVersionNumber = _extractVersionNumber(versionInfo);
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
      remoteVersion: _extractVersionName(versionInfo),
      updateTitle: _extractUpdateTitle(versionInfo),
      releaseNotes: _extractReleaseNotes(versionInfo),
      features: _extractFeatures(versionInfo),
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
      remoteVersion: _extractVersionName(versionInfo),
      updateTitle: _extractUpdateTitle(versionInfo),
      releaseNotes: _extractReleaseNotes(versionInfo),
      features: _extractFeatures(versionInfo),
      errorCode: baseResult.errorCode,
      message: baseResult.message,
    );
  }

  static void showUpdateDialog(BuildContext context, UpdateCheckResult result) {
    final String remoteVersion = result.remoteVersion ?? Settings.versionName;
    final String titleText =
        (result.updateTitle != null && result.updateTitle!.trim().isNotEmpty)
            ? result.updateTitle!
            : 'Version $remoteVersion is available';
    final String releaseNotes =
        result.releaseNotes ??
        'An update is available in the Microsoft Store.';
    final List<String> features = result.features ?? const <String>[];

    showDialog(
      context: context,
      builder: (BuildContext context) => ShadDialog.alert(
        title: const Text('Update Available'),
        description: Text.rich(
          TextSpan(
            text: '$titleText\n\n',
            children: [
              const TextSpan(text: 'Release Notes:\n'),
              TextSpan(text: '$releaseNotes\n'),
              if (features.isNotEmpty) const TextSpan(text: '\nWhat is new:\n'),
              if (features.isNotEmpty)
                TextSpan(
                  text: features.map((feature) => '- $feature').join('\n'),
                ),
            ],
          ),
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

  static int? _extractVersionNumber(Map<String, dynamic> versionInfo) {
    return _toInt(
      versionInfo['current_version_number'] ?? versionInfo['version_number'],
    );
  }

  static String? _extractVersionName(Map<String, dynamic> versionInfo) {
    return versionInfo['current_version']?.toString() ??
        versionInfo['version']?.toString();
  }

  static String? _extractUpdateTitle(Map<String, dynamic> versionInfo) {
    return versionInfo['update_title']?.toString() ??
        versionInfo['release_title']?.toString();
  }

  static String? _extractReleaseNotes(Map<String, dynamic> versionInfo) {
    return versionInfo['release_notes']?.toString() ??
        versionInfo['description']?.toString();
  }

  static List<String>? _extractFeatures(Map<String, dynamic> versionInfo) {
    final dynamic rawFeatures =
        versionInfo['list_of_features'] ?? versionInfo['features'];
    if (rawFeatures is! List) return null;

    final List<String> features = rawFeatures
        .map((feature) => feature?.toString().trim() ?? '')
        .where((feature) => feature.isNotEmpty)
        .toList();
    return features.isEmpty ? null : features;
  }
}
