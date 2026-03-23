String sanitizeStrategyFileName(String input) {
  final sanitized = input.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  return sanitized.isEmpty ? 'untitled' : sanitized;
}

String buildLibraryBackupFileName(DateTime timestamp) {
  String twoDigit(int value) => value.toString().padLeft(2, '0');
  return 'icarus-library-backup-'
      '${timestamp.year}-${twoDigit(timestamp.month)}-${twoDigit(timestamp.day)}_'
      '${twoDigit(timestamp.hour)}-${twoDigit(timestamp.minute)}-${twoDigit(timestamp.second)}.zip';
}
