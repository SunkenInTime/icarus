import 'dart:developer';
import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

Future<void> registerDeepLinkProtocol(String scheme) async {
  if (!Platform.isWindows) {
    return;
  }

  final appPath = Platform.resolvedExecutable;
  final expectedCommand = '"$appPath" "%1"';

  final protocolRegKey = 'Software\\Classes\\$scheme';
  const protocolRegValue = RegistryValue.string('URL Protocol', '');
  const protocolCmdRegKey = 'shell\\open\\command';

  final currentCommand = _readCurrentProtocolCommand(scheme);
  final looksLikeDevBuild = _looksLikeDevBuildPath(appPath);
  final canOverwriteDevRegistration = !looksLikeDevBuild ||
      const bool.fromEnvironment('ICARUS_FORCE_PROTOCOL_REGISTER');

  if (!canOverwriteDevRegistration &&
      currentCommand != null &&
      currentCommand.isNotEmpty &&
      currentCommand != expectedCommand) {
    log(
      'Deep link registration skipped for dev executable. '
      'existing="$currentCommand" '
      'resolvedExecutable="$appPath"',
      name: 'deep_link_registrar',
    );
    return;
  }

  final regKey = Registry.currentUser.createKey(protocolRegKey);
  regKey.createValue(protocolRegValue);
  regKey
      .createKey(protocolCmdRegKey)
      .createValue(RegistryValue.string('', expectedCommand));

  log(
    'Deep link registration updated. '
    'scheme="$scheme" command="$expectedCommand"',
    name: 'deep_link_registrar',
  );
}

String? _readCurrentProtocolCommand(String scheme) {
  final path = 'Software\\Classes\\$scheme\\shell\\open\\command';
  try {
    final key = Registry.openPath(RegistryHive.currentUser, path: path);
    final value = key.getStringValue('');
    key.close();
    return value;
  } catch (_) {
    return null;
  }
}

bool _looksLikeDevBuildPath(String appPath) {
  final normalized = appPath.toLowerCase().replaceAll('/', '\\');
  return normalized.contains('\\build\\windows\\x64\\runner\\debug\\');
}
