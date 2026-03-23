import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/favorite_agents_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/archive_manifest.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

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

class NewerVersionImportException implements Exception {
  const NewerVersionImportException({
    required this.importedVersion,
    required this.currentVersion,
  });

  final int importedVersion;
  final int currentVersion;

  static const String userMessage =
      'This strategy was created in a newer version of Icarus. '
      'Please update the app and try again.';

  @override
  String toString() {
    return 'NewerVersionImportException('
        'importedVersion: $importedVersion, '
        'currentVersion: $currentVersion'
        ')';
  }
}

enum ImportIssueCode {
  newerVersion,
  invalidStrategy,
  invalidArchiveMetadata,
  unsupportedFile,
  ioError,
}

class ImportIssue {
  const ImportIssue({
    required this.path,
    required this.code,
  });

  final String path;
  final ImportIssueCode code;
}

class ImportBatchResult {
  const ImportBatchResult({
    required this.strategiesImported,
    required this.foldersCreated,
    this.themeProfilesImported = 0,
    this.globalStateRestored = false,
    required this.issues,
  });

  const ImportBatchResult.empty()
      : strategiesImported = 0,
        foldersCreated = 0,
        themeProfilesImported = 0,
        globalStateRestored = false,
        issues = const [];

  final int strategiesImported;
  final int foldersCreated;
  final int themeProfilesImported;
  final bool globalStateRestored;
  final List<ImportIssue> issues;

  bool get hasImports =>
      strategiesImported > 0 ||
      foldersCreated > 0 ||
      themeProfilesImported > 0 ||
      globalStateRestored;

  ImportBatchResult merge(ImportBatchResult other) {
    return ImportBatchResult(
      strategiesImported: strategiesImported + other.strategiesImported,
      foldersCreated: foldersCreated + other.foldersCreated,
      themeProfilesImported:
          themeProfilesImported + other.themeProfilesImported,
      globalStateRestored: globalStateRestored || other.globalStateRestored,
      issues: [...issues, ...other.issues],
    );
  }
}

class _ImportEntityListing {
  const _ImportEntityListing({
    required this.entities,
    required this.issues,
  });

  final List<FileSystemEntity> entities;
  final List<ImportIssue> issues;
}

class _ArchiveExportState {
  _ArchiveExportState({
    required this.rootDirectory,
  });

  final Directory rootDirectory;
  final List<ArchiveFolderEntry> folders = [];
  final List<ArchiveStrategyEntry> strategies = [];
}

class _ManifestImportData {
  const _ManifestImportData({
    required this.rootDirectory,
    required this.manifestFile,
    required this.manifest,
  });

  final Directory rootDirectory;
  final File manifestFile;
  final ArchiveManifest manifest;
}

class _GlobalImportResult {
  const _GlobalImportResult({
    required this.themeProfilesImported,
    required this.globalStateRestored,
    required this.profileIdRemap,
  });

  final int themeProfilesImported;
  final bool globalStateRestored;
  final Map<String, String> profileIdRemap;
}

class _ZipManifestData {
  const _ZipManifestData({
    required this.manifest,
    required this.rootPrefix,
    required this.filesByPath,
    required this.manifestArchivePath,
  });

  final ArchiveManifest manifest;
  final String rootPrefix;
  final Map<String, ArchiveFile> filesByPath;
  final String manifestArchivePath;
}

class StrategyImportExportService {
  StrategyImportExportService(this.ref);

  final dynamic ref;

  void _reportImportFailure(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    required String source,
  }) {
    AppErrorReporter.reportError(
      message,
      error: error,
      stackTrace: stackTrace,
      source: source,
      promptUser: false,
    );
  }

  Future<void> loadFromFilePath(String filePath) async {
    await _importStrategyFile(
      file: XFile(filePath),
      targetFolderId: null,
    );
  }

  Future<void> loadFromFilePicker() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ['ica'],
    );

    if (result == null) return;

    for (final file in result.files) {
      await _importStrategyFile(
        file: file.xFile,
        targetFolderId: null,
      );
    }
  }

  Future<ImportBatchResult> importBackupFromFilePicker() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );

    if (result == null || result.files.isEmpty) {
      return const ImportBatchResult.empty();
    }

    final pickedFile = result.files.single;
    final filePath = pickedFile.path;
    if (filePath == null || filePath.isEmpty) {
      return const ImportBatchResult.empty();
    }

    return _importZipArchive(
      zipFile: File(filePath),
      parentFolderId: null,
    );
  }

  Future<ImportBatchResult> loadFromFileDrop(List<XFile> files) async {
    final targetFolderId = ref.read(folderProvider);
    var result = const ImportBatchResult.empty();

    for (final file in files) {
      result = result.merge(
        await _importDroppedItem(
          file: file,
          targetFolderId: targetFolderId,
        ),
      );
    }

    return result;
  }

  Future<Directory> getTempDirectory(String strategyID) async {
    String tempDirectoryPath;
    try {
      tempDirectoryPath = (await getTemporaryDirectory()).path;
    } on MissingPluginException {
      tempDirectoryPath = Directory.systemTemp.path;
    } on MissingPlatformDirectoryException {
      tempDirectoryPath = Directory.systemTemp.path;
    }

    return Directory(
      path.join(tempDirectoryPath, 'xyz_icarus_strats', strategyID),
    ).create(recursive: true);
  }

  Future<void> cleanUpTempDirectory(String strategyID) async {
    final tempDirectory = await getTempDirectory(strategyID);
    await tempDirectory.delete(recursive: true);
  }

  Future<Directory> _getApplicationSupportDirectoryOrSystemTemp() async {
    try {
      return await getApplicationSupportDirectory();
    } on MissingPluginException {
      return Directory.systemTemp;
    } on MissingPlatformDirectoryException {
      return Directory.systemTemp;
    }
  }

  Future<void> _extractArchiveEntriesToDisk({
    required Archive archive,
    required Directory destination,
  }) async {
    final destinationPath = path.normalize(destination.path);

    for (final entry in archive) {
      final normalizedName = normalizeArchivePath(entry.name);
      if (normalizedName.isEmpty) {
        continue;
      }
      if (path.isAbsolute(normalizedName)) {
        continue;
      }

      final segments = path.posix.split(normalizedName);
      if (segments.any((segment) => segment == '..')) {
        continue;
      }

      final targetPath = path.joinAll([
        destinationPath,
        ...segments,
      ]);
      final normalizedTargetPath = path.normalize(targetPath);
      final isWithinDestination =
          path.isWithin(destinationPath, normalizedTargetPath) ||
              normalizedTargetPath == destinationPath;
      if (!isWithinDestination) {
        continue;
      }

      if (entry.isFile) {
        final targetFile = File(normalizedTargetPath);
        await targetFile.parent.create(recursive: true);
        await targetFile.writeAsBytes(entry.content as List<int>);
      } else {
        await Directory(normalizedTargetPath).create(recursive: true);
      }
    }
  }

  Future<bool> isZipFile(File file) async {
    final raf = file.openSync(mode: FileMode.read);
    final header = raf.readSync(4);
    await raf.close();

    return header.length == 4 &&
        header[0] == 0x50 &&
        header[1] == 0x4B &&
        header[2] == 0x03 &&
        header[3] == 0x04;
  }

  Future<ImportBatchResult> _importDroppedItem({
    required XFile file,
    required String? targetFolderId,
  }) async {
    if (file.path.isEmpty) {
      return const ImportBatchResult(
        strategiesImported: 0,
        foldersCreated: 0,
        themeProfilesImported: 0,
        globalStateRestored: false,
        issues: [
          ImportIssue(path: '', code: ImportIssueCode.ioError),
        ],
      );
    }

    try {
      final entityType =
          await FileSystemEntity.type(file.path, followLinks: false);
      switch (entityType) {
        case FileSystemEntityType.directory:
          return await _importDirectoryTree(
            sourceDir: Directory(file.path),
            parentFolderId: targetFolderId,
          );
        case FileSystemEntityType.file:
          final extension = path.extension(file.path).toLowerCase();
          if (extension == '.ica') {
            await _importStrategyFile(
              file: file,
              targetFolderId: targetFolderId,
            );
            return const ImportBatchResult(
              strategiesImported: 1,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [],
            );
          }

          if (await isZipFile(File(file.path))) {
            return await _importZipArchive(
              zipFile: File(file.path),
              parentFolderId: targetFolderId,
            );
          }

          return ImportBatchResult(
            strategiesImported: 0,
            foldersCreated: 0,
            themeProfilesImported: 0,
            globalStateRestored: false,
            issues: [
              ImportIssue(
                path: file.path,
                code: ImportIssueCode.unsupportedFile,
              ),
            ],
          );
        case FileSystemEntityType.notFound:
        case FileSystemEntityType.link:
        case FileSystemEntityType.unixDomainSock:
        case FileSystemEntityType.pipe:
        default:
          return ImportBatchResult(
            strategiesImported: 0,
            foldersCreated: 0,
            themeProfilesImported: 0,
            globalStateRestored: false,
            issues: [
              ImportIssue(
                path: file.path,
                code: ImportIssueCode.ioError,
              ),
            ],
          );
      }
    } on NewerVersionImportException {
      return ImportBatchResult(
        strategiesImported: 0,
        foldersCreated: 0,
        themeProfilesImported: 0,
        globalStateRestored: false,
        issues: [
          ImportIssue(
            path: file.path,
            code: ImportIssueCode.newerVersion,
          ),
        ],
      );
    } catch (error, stackTrace) {
      _reportImportFailure(
        'Failed to import dropped item ${file.path}.',
        error: error,
        stackTrace: stackTrace,
        source: 'StrategyImportExportService._importDroppedItem',
      );
      return ImportBatchResult(
        strategiesImported: 0,
        foldersCreated: 0,
        themeProfilesImported: 0,
        globalStateRestored: false,
        issues: [
          ImportIssue(
            path: file.path,
            code: ImportIssueCode.ioError,
          ),
        ],
      );
    }
  }

  Future<Folder> _createImportedFolder({
    required String name,
    required String? parentFolderId,
  }) {
    return ref.read(folderProvider.notifier).createFolder(
          name: name,
          icon: Icons.drive_folder_upload,
          color: FolderColor.generic,
          parentID: parentFolderId,
        );
  }

  List<FileSystemEntity> _sortedImportEntities(
    Iterable<FileSystemEntity> entities,
  ) {
    final filtered = entities.where((entity) {
      final basename = path.basename(entity.path);
      return !_shouldIgnoreImportedEntityName(basename);
    }).toList();
    filtered.sort((a, b) => a.path.compareTo(b.path));
    return filtered;
  }

  bool _shouldIgnoreImportedEntityName(String name) {
    return name.isEmpty ||
        name == '__MACOSX' ||
        name == '.DS_Store' ||
        name == archiveMetadataFileName ||
        name.startsWith('._');
  }

  bool _isIcaFileEntity(FileSystemEntity entity) {
    return entity is File &&
        path.extension(entity.path).toLowerCase() == '.ica';
  }

  Future<_ImportEntityListing> _listImportEntities(Directory directory) async {
    final issues = <ImportIssue>[];
    try {
      final entities = directory.listSync(followLinks: false);
      return _ImportEntityListing(
        entities: _sortedImportEntities(entities),
        issues: issues,
      );
    } on FileSystemException catch (error, stackTrace) {
      final errorPath = _resolveImportErrorPath(error, directory.path);
      _reportImportFailure(
        'Failed to list import directory $errorPath.',
        error: error,
        stackTrace: stackTrace,
        source: 'StrategyImportExportService._listImportEntities',
      );
      issues.add(
        ImportIssue(
          path: errorPath,
          code: ImportIssueCode.ioError,
        ),
      );
    }

    return _ImportEntityListing(
      entities: const [],
      issues: issues,
    );
  }

  String _resolveImportErrorPath(Object error, String fallbackPath) {
    if (error is FileSystemException) {
      return error.path ?? fallbackPath;
    }
    return fallbackPath;
  }

  Future<ImportBatchResult> _importEntitiesIntoFolder({
    required Iterable<FileSystemEntity> entities,
    required String parentFolderId,
  }) async {
    var result = const ImportBatchResult.empty();
    final sortedEntities = _sortedImportEntities(entities);

    for (final entity in sortedEntities) {
      if (entity is Directory) {
        result = result.merge(
          await _importDirectoryTree(
            sourceDir: entity,
            parentFolderId: parentFolderId,
          ),
        );
        continue;
      }

      if (_isIcaFileEntity(entity)) {
        try {
          await _importStrategyFile(
            file: XFile(entity.path),
            targetFolderId: parentFolderId,
          );
          result = result.merge(
            const ImportBatchResult(
              strategiesImported: 1,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [],
            ),
          );
        } on NewerVersionImportException {
          result = result.merge(
            ImportBatchResult(
              strategiesImported: 0,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [
                ImportIssue(
                  path: entity.path,
                  code: ImportIssueCode.newerVersion,
                ),
              ],
            ),
          );
        } catch (error, stackTrace) {
          _reportImportFailure(
            'Failed to import strategy file ${entity.path}.',
            error: error,
            stackTrace: stackTrace,
            source: 'StrategyImportExportService._importEntitiesIntoFolder',
          );
          result = result.merge(
            ImportBatchResult(
              strategiesImported: 0,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [
                ImportIssue(
                  path: entity.path,
                  code: ImportIssueCode.invalidStrategy,
                ),
              ],
            ),
          );
        }
        continue;
      }

      result = result.merge(
        ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 0,
          themeProfilesImported: 0,
          globalStateRestored: false,
          issues: [
            ImportIssue(
              path: entity.path,
              code: ImportIssueCode.unsupportedFile,
            ),
          ],
        ),
      );
    }

    return result;
  }

  Future<ImportBatchResult> _importDirectoryTree({
    required Directory sourceDir,
    required String? parentFolderId,
  }) async {
    final manifestFile =
        File(path.join(sourceDir.path, archiveMetadataFileName));
    _ManifestImportData? manifestData;
    if (await manifestFile.exists()) {
      try {
        manifestData = await _loadManifestIfPresent(sourceDir);
        if (manifestData != null) {
          _validateArchiveManifest(manifestData);
        }
      } catch (error, stackTrace) {
        _reportImportFailure(
          'Failed to import manifest archive from ${sourceDir.path}.',
          error: error,
          stackTrace: stackTrace,
          source: 'StrategyImportExportService._importDirectoryTree',
        );
        return ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 0,
          themeProfilesImported: 0,
          globalStateRestored: false,
          issues: [
            ImportIssue(
              path: manifestFile.path,
              code: ImportIssueCode.invalidArchiveMetadata,
            ),
          ],
        ).merge(
          await _importDirectoryTreeLegacy(
            sourceDir: sourceDir,
            parentFolderId: parentFolderId,
          ),
        );
      }
    }

    if (manifestData != null) {
      return _importManifestArchive(
        manifestData: manifestData,
        parentFolderId: parentFolderId,
      );
    }

    return _importDirectoryTreeLegacy(
      sourceDir: sourceDir,
      parentFolderId: parentFolderId,
    );
  }

  Future<ImportBatchResult> _importDirectoryTreeLegacy({
    required Directory sourceDir,
    required String? parentFolderId,
  }) async {
    final importedFolder = await _createImportedFolder(
      name: path.basename(sourceDir.path),
      parentFolderId: parentFolderId,
    );

    var result = const ImportBatchResult(
      strategiesImported: 0,
      foldersCreated: 1,
      themeProfilesImported: 0,
      globalStateRestored: false,
      issues: [],
    );

    final listing = await _listImportEntities(sourceDir);
    if (listing.issues.isNotEmpty) {
      result = result.merge(
        ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 0,
          themeProfilesImported: 0,
          globalStateRestored: false,
          issues: listing.issues,
        ),
      );
    }

    result = result.merge(
      await _importEntitiesIntoFolder(
        entities: listing.entities,
        parentFolderId: importedFolder.id,
      ),
    );

    return result;
  }

  Future<ImportBatchResult> _importZipArchive({
    required File zipFile,
    required String? parentFolderId,
  }) async {
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    _ZipManifestData? manifestData;
    try {
      manifestData = _loadManifestFromArchive(archive);
      if (manifestData != null) {
        _validateArchiveManifestFromZip(manifestData);
      }
    } catch (error, stackTrace) {
      _reportImportFailure(
        'Failed to import manifest zip ${zipFile.path}.',
        error: error,
        stackTrace: stackTrace,
        source: 'StrategyImportExportService._importZipArchive',
      );
      return ImportBatchResult(
        strategiesImported: 0,
        foldersCreated: 0,
        themeProfilesImported: 0,
        globalStateRestored: false,
        issues: [
          ImportIssue(
            path: zipFile.path,
            code: ImportIssueCode.invalidArchiveMetadata,
          ),
        ],
      ).merge(
        await _importLegacyZipArchiveFromEntries(
          archive: archive,
          parentFolderId: parentFolderId,
          zipFileName: path.basenameWithoutExtension(zipFile.path),
        ),
      );
    }

    if (manifestData != null) {
      return _importManifestArchiveFromZip(
        manifestData: manifestData,
        parentFolderId: parentFolderId,
      );
    }

    return _importLegacyZipArchiveFromEntries(
      archive: archive,
      parentFolderId: parentFolderId,
      zipFileName: path.basenameWithoutExtension(zipFile.path),
    );
  }

  _ZipManifestData? _loadManifestFromArchive(Archive archive) {
    final filesByPath = <String, ArchiveFile>{};
    for (final entry in archive) {
      if (!entry.isFile) {
        continue;
      }
      filesByPath[normalizeArchivePath(entry.name)] = entry;
    }

    final manifestPaths = filesByPath.keys
        .where((pathValue) =>
            path.posix.basename(pathValue) == archiveMetadataFileName)
        .toList(growable: false);
    if (manifestPaths.isEmpty) {
      return null;
    }
    if (manifestPaths.length > 1) {
      throw const FormatException('Archive contains multiple manifest files');
    }

    final manifestArchivePath = manifestPaths.single;
    final manifestEntry = filesByPath[manifestArchivePath]!;
    final decoded = jsonDecode(utf8.decode(_archiveFileBytes(manifestEntry)));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Archive manifest must decode to an object');
    }

    final rootPrefix = path.posix.dirname(manifestArchivePath);
    return _ZipManifestData(
      manifest: ArchiveManifest.fromJson(decoded),
      rootPrefix: rootPrefix == '.' ? '' : rootPrefix,
      filesByPath: filesByPath,
      manifestArchivePath: manifestArchivePath,
    );
  }

  List<int> _archiveFileBytes(ArchiveFile entry) {
    return entry.content as List<int>;
  }

  Future<File> _writeArchiveEntryToTempFile({
    required ArchiveFile archiveFile,
    required Directory tempDirectory,
  }) async {
    final baseName = path.basename(normalizeArchivePath(archiveFile.name));
    final file = File(path.join(tempDirectory.path, baseName));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(_archiveFileBytes(archiveFile));
    return file;
  }

  Future<ImportBatchResult> _importManifestArchiveFromZip({
    required _ZipManifestData manifestData,
    required String? parentFolderId,
  }) async {
    var result = const ImportBatchResult.empty();
    var profileIdRemap = const <String, String>{};

    if (manifestData.manifest.archiveType == ArchiveType.libraryBackup) {
      final globals = manifestData.manifest.globals;
      if (globals == null) {
        throw const FormatException(
            'Library backup archive is missing globals');
      }
      final globalImportResult = await _importArchiveGlobals(globals);
      profileIdRemap = globalImportResult.profileIdRemap;
      result = result.merge(
        ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 0,
          themeProfilesImported: globalImportResult.themeProfilesImported,
          globalStateRestored: globalImportResult.globalStateRestored,
          issues: const [],
        ),
      );
    }

    final folderEntries = [...manifestData.manifest.folders]..sort((a, b) {
        final depthCompare = _archivePathDepth(a.archivePath)
            .compareTo(_archivePathDepth(b.archivePath));
        if (depthCompare != 0) {
          return depthCompare;
        }
        return a.archivePath.compareTo(b.archivePath);
      });

    final localFolderIdsByManifestId = <String, String>{};
    for (final folderEntry in folderEntries) {
      final resolvedParentFolderId = folderEntry.parentManifestId == null
          ? (manifestData.manifest.archiveType == ArchiveType.folderTree
              ? parentFolderId
              : null)
          : localFolderIdsByManifestId[folderEntry.parentManifestId!];
      if (folderEntry.parentManifestId != null &&
          resolvedParentFolderId == null) {
        throw FormatException(
          'Missing parent folder mapping for ${folderEntry.manifestId}',
        );
      }

      final createdFolder =
          await ref.read(folderProvider.notifier).createFolder(
                name: folderEntry.name,
                icon: folderEntry.icon.toIconData(),
                color: folderEntry.color,
                customColor: folderEntry.customColorValue == null
                    ? null
                    : Color(folderEntry.customColorValue!),
                parentID: resolvedParentFolderId,
              );
      localFolderIdsByManifestId[folderEntry.manifestId] = createdFolder.id;
      result = result.merge(
        const ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 1,
          themeProfilesImported: 0,
          globalStateRestored: false,
          issues: [],
        ),
      );
    }

    final materializedDirectory =
        await Directory.systemTemp.createTemp('icarus-zip-manifest-import');
    try {
      for (final strategyEntry in [...manifestData.manifest.strategies]
        ..sort((a, b) => a.archivePath.compareTo(b.archivePath))) {
        final targetFolderId = strategyEntry.folderManifestId == null
            ? null
            : localFolderIdsByManifestId[strategyEntry.folderManifestId!];
        final archivePath = _zipArchiveAbsolutePath(
          rootPrefix: manifestData.rootPrefix,
          relativePath: strategyEntry.archivePath,
        );
        final archiveFile = manifestData.filesByPath[archivePath];
        if (archiveFile == null) {
          throw FormatException('Missing strategy file: $archivePath');
        }

        try {
          final tempFile = await _writeArchiveEntryToTempFile(
            archiveFile: archiveFile,
            tempDirectory: materializedDirectory,
          );
          await _importStrategyFile(
            file: XFile(tempFile.path),
            targetFolderId: targetFolderId,
            displayNameOverride: strategyEntry.name,
            themeProfileIdRemap: profileIdRemap,
          );
          result = result.merge(
            const ImportBatchResult(
              strategiesImported: 1,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [],
            ),
          );
        } on NewerVersionImportException {
          result = result.merge(
            ImportBatchResult(
              strategiesImported: 0,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [
                ImportIssue(
                  path: archivePath,
                  code: ImportIssueCode.newerVersion,
                ),
              ],
            ),
          );
        } catch (error, stackTrace) {
          _reportImportFailure(
            'Failed to import manifest strategy $archivePath.',
            error: error,
            stackTrace: stackTrace,
            source: 'StrategyImportExportService._importManifestArchiveFromZip',
          );
          result = result.merge(
            ImportBatchResult(
              strategiesImported: 0,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [
                ImportIssue(
                  path: archivePath,
                  code: ImportIssueCode.invalidStrategy,
                ),
              ],
            ),
          );
        }
      }
    } finally {
      try {
        await materializedDirectory.delete(recursive: true);
      } catch (_) {}
    }

    final undeclaredIssues = _collectUndeclaredZipArchiveIssues(manifestData);
    if (undeclaredIssues.isNotEmpty) {
      result = result.merge(
        ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 0,
          themeProfilesImported: 0,
          globalStateRestored: false,
          issues: undeclaredIssues,
        ),
      );
    }

    return result;
  }

  void _validateArchiveManifestFromZip(_ZipManifestData manifestData) {
    final manifest = manifestData.manifest;
    final folderIds = <String>{};
    final folderPaths = <String>{};
    final rootFolders = <ArchiveFolderEntry>[];

    for (final folder in manifest.folders) {
      if (!folderIds.add(folder.manifestId)) {
        throw FormatException(
            'Duplicate folder manifest ID: ${folder.manifestId}');
      }
      if (!folderPaths.add(folder.archivePath)) {
        throw FormatException(
            'Duplicate folder archive path: ${folder.archivePath}');
      }
      if (folder.parentManifestId == null) {
        rootFolders.add(folder);
      } else if (!manifest.folders.any(
          (candidate) => candidate.manifestId == folder.parentManifestId)) {
        throw FormatException('Missing parent folder for ${folder.manifestId}');
      }
    }

    if (manifest.archiveType == ArchiveType.folderTree) {
      if (rootFolders.length != 1) {
        throw const FormatException(
            'Folder tree archives must contain one root');
      }
      if (rootFolders.single.archivePath.isNotEmpty) {
        throw const FormatException(
          'Folder tree root folder must use the manifest root path',
        );
      }
    }

    final knownFolderIds =
        manifest.folders.map((folder) => folder.manifestId).toSet();
    final strategyPaths = <String>{};
    for (final strategy in manifest.strategies) {
      if (!strategyPaths.add(strategy.archivePath)) {
        throw FormatException(
          'Duplicate strategy archive path: ${strategy.archivePath}',
        );
      }
      if (strategy.folderManifestId != null &&
          !knownFolderIds.contains(strategy.folderManifestId)) {
        throw FormatException(
          'Unknown strategy folder reference: ${strategy.folderManifestId}',
        );
      }
      if (manifest.archiveType == ArchiveType.folderTree &&
          strategy.folderManifestId == null) {
        throw const FormatException(
          'Folder tree strategies must reference the exported root folder',
        );
      }
      final archivePath = _zipArchiveAbsolutePath(
        rootPrefix: manifestData.rootPrefix,
        relativePath: strategy.archivePath,
      );
      if (!manifestData.filesByPath.containsKey(archivePath)) {
        throw FormatException('Missing strategy file: $archivePath');
      }
    }
  }

  String _zipArchiveAbsolutePath({
    required String rootPrefix,
    required String relativePath,
  }) {
    return normalizeArchivePath(
      rootPrefix.isEmpty
          ? relativePath
          : path.posix.join(rootPrefix, relativePath),
    );
  }

  List<ImportIssue> _collectUndeclaredZipArchiveIssues(
    _ZipManifestData manifestData,
  ) {
    final allowedFiles = <String>{manifestData.manifestArchivePath};
    for (final strategy in manifestData.manifest.strategies) {
      allowedFiles.add(
        _zipArchiveAbsolutePath(
          rootPrefix: manifestData.rootPrefix,
          relativePath: strategy.archivePath,
        ),
      );
    }

    final issues = <ImportIssue>[];
    for (final archivePath in manifestData.filesByPath.keys) {
      if (!allowedFiles.contains(archivePath) &&
          !_shouldIgnoreImportedEntityName(path.posix.basename(archivePath))) {
        issues.add(
          ImportIssue(
            path: archivePath,
            code: ImportIssueCode.unsupportedFile,
          ),
        );
      }
    }
    return issues;
  }

  Future<ImportBatchResult> _importLegacyZipArchiveFromEntries({
    required Archive archive,
    required String? parentFolderId,
    required String zipFileName,
  }) async {
    final filesByPath = <String, ArchiveFile>{};
    for (final entry in archive) {
      if (!entry.isFile) {
        continue;
      }
      final normalizedPath = normalizeArchivePath(entry.name);
      if (_shouldIgnoreImportedEntityName(
          path.posix.basename(normalizedPath))) {
        continue;
      }
      filesByPath[normalizedPath] = entry;
    }

    final topLevelSegments = <String>{};
    final looseTopLevelIca = <String>[];
    for (final archivePath in filesByPath.keys) {
      final segments = archivePath.split('/');
      if (segments.isEmpty) {
        continue;
      }
      topLevelSegments.add(segments.first);
      if (segments.length == 1 &&
          path.extension(archivePath).toLowerCase() == '.ica') {
        looseTopLevelIca.add(archivePath);
      }
    }

    if (topLevelSegments.length == 1 && looseTopLevelIca.isEmpty) {
      return _importLegacyZipDirectory(
        directoryPrefix: topLevelSegments.single,
        filesByPath: filesByPath,
        parentFolderId: parentFolderId,
      );
    }

    final wrapperFolder = await _createImportedFolder(
      name: zipFileName,
      parentFolderId: parentFolderId,
    );

    return const ImportBatchResult(
      strategiesImported: 0,
      foldersCreated: 1,
      themeProfilesImported: 0,
      globalStateRestored: false,
      issues: [],
    ).merge(
      await _importLegacyZipEntitiesIntoFolder(
        parentPrefix: '',
        filesByPath: filesByPath,
        parentFolderId: wrapperFolder.id,
      ),
    );
  }

  Future<ImportBatchResult> _importLegacyZipDirectory({
    required String directoryPrefix,
    required Map<String, ArchiveFile> filesByPath,
    required String? parentFolderId,
  }) async {
    final importedFolder = await _createImportedFolder(
      name: path.posix.basename(directoryPrefix),
      parentFolderId: parentFolderId,
    );

    return const ImportBatchResult(
      strategiesImported: 0,
      foldersCreated: 1,
      themeProfilesImported: 0,
      globalStateRestored: false,
      issues: [],
    ).merge(
      await _importLegacyZipEntitiesIntoFolder(
        parentPrefix: directoryPrefix,
        filesByPath: filesByPath,
        parentFolderId: importedFolder.id,
      ),
    );
  }

  Future<ImportBatchResult> _importLegacyZipEntitiesIntoFolder({
    required String parentPrefix,
    required Map<String, ArchiveFile> filesByPath,
    required String parentFolderId,
  }) async {
    final directDirectories = <String>{};
    final directFiles = <String>[];
    final normalizedParentPrefix = normalizeArchivePath(parentPrefix);

    for (final archivePath in filesByPath.keys) {
      final parentPath = path.posix.dirname(archivePath);
      if (normalizedParentPrefix.isEmpty) {
        if (parentPath == '.') {
          directFiles.add(archivePath);
        } else if (!parentPath.contains('/')) {
          directDirectories.add(parentPath);
        }
        continue;
      }

      if (parentPath == normalizedParentPrefix) {
        directFiles.add(archivePath);
        continue;
      }

      if (archivePath.startsWith('$normalizedParentPrefix/')) {
        final remainder =
            archivePath.substring(normalizedParentPrefix.length + 1);
        if (remainder.isEmpty || !remainder.contains('/')) {
          continue;
        }
        final childDirectory = remainder.substring(0, remainder.indexOf('/'));
        directDirectories.add(
          normalizeArchivePath(
            path.posix.join(normalizedParentPrefix, childDirectory),
          ),
        );
      }
    }

    var result = const ImportBatchResult.empty();

    final tempDirectory =
        await Directory.systemTemp.createTemp('icarus-zip-legacy-import');
    try {
      final sortedDirectories = directDirectories.toList()..sort();
      for (final directoryPrefix in sortedDirectories) {
        result = result.merge(
          await _importLegacyZipDirectory(
            directoryPrefix: directoryPrefix,
            filesByPath: filesByPath,
            parentFolderId: parentFolderId,
          ),
        );
      }

      directFiles.sort();
      for (final archivePath in directFiles) {
        if (path.extension(archivePath).toLowerCase() != '.ica') {
          result = result.merge(
            ImportBatchResult(
              strategiesImported: 0,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [
                ImportIssue(
                  path: archivePath,
                  code: ImportIssueCode.unsupportedFile,
                ),
              ],
            ),
          );
          continue;
        }

        try {
          final tempFile = await _writeArchiveEntryToTempFile(
            archiveFile: filesByPath[archivePath]!,
            tempDirectory: tempDirectory,
          );
          await _importStrategyFile(
            file: XFile(tempFile.path),
            targetFolderId: parentFolderId,
          );
          result = result.merge(
            const ImportBatchResult(
              strategiesImported: 1,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [],
            ),
          );
        } on NewerVersionImportException {
          result = result.merge(
            ImportBatchResult(
              strategiesImported: 0,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [
                ImportIssue(
                  path: archivePath,
                  code: ImportIssueCode.newerVersion,
                ),
              ],
            ),
          );
        } catch (error, stackTrace) {
          _reportImportFailure(
            'Failed to import zip strategy $archivePath.',
            error: error,
            stackTrace: stackTrace,
            source:
                'StrategyImportExportService._importLegacyZipEntitiesIntoFolder',
          );
          result = result.merge(
            ImportBatchResult(
              strategiesImported: 0,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [
                ImportIssue(
                  path: archivePath,
                  code: ImportIssueCode.invalidStrategy,
                ),
              ],
            ),
          );
        }
      }
    } finally {
      try {
        await tempDirectory.delete(recursive: true);
      } catch (_) {}
    }

    return result;
  }

  Future<_ManifestImportData?> _loadManifestIfPresent(
    Directory directory,
  ) async {
    final manifestFile =
        File(path.join(directory.path, archiveMetadataFileName));
    if (!await manifestFile.exists()) {
      return null;
    }

    final raw = await manifestFile.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Archive metadata must decode to an object');
    }

    return _ManifestImportData(
      rootDirectory: directory,
      manifestFile: manifestFile,
      manifest: ArchiveManifest.fromJson(decoded),
    );
  }

  Future<ImportBatchResult> _importManifestArchive({
    required _ManifestImportData manifestData,
    required String? parentFolderId,
  }) async {
    _validateArchiveManifest(manifestData);

    var result = const ImportBatchResult.empty();
    var profileIdRemap = const <String, String>{};

    if (manifestData.manifest.archiveType == ArchiveType.libraryBackup) {
      final globals = manifestData.manifest.globals;
      if (globals == null) {
        throw const FormatException(
            'Library backup archive is missing globals');
      }
      final globalImportResult = await _importArchiveGlobals(globals);
      profileIdRemap = globalImportResult.profileIdRemap;
      result = result.merge(
        ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 0,
          themeProfilesImported: globalImportResult.themeProfilesImported,
          globalStateRestored: globalImportResult.globalStateRestored,
          issues: const [],
        ),
      );
    }

    final folderEntries = [...manifestData.manifest.folders]..sort((a, b) {
        final depthCompare = _archivePathDepth(a.archivePath)
            .compareTo(_archivePathDepth(b.archivePath));
        if (depthCompare != 0) {
          return depthCompare;
        }
        return a.archivePath.compareTo(b.archivePath);
      });

    final localFolderIdsByManifestId = <String, String>{};
    for (final folderEntry in folderEntries) {
      final resolvedParentFolderId = folderEntry.parentManifestId == null
          ? (manifestData.manifest.archiveType == ArchiveType.folderTree
              ? parentFolderId
              : null)
          : localFolderIdsByManifestId[folderEntry.parentManifestId!];
      if (folderEntry.parentManifestId != null &&
          resolvedParentFolderId == null) {
        throw FormatException(
          'Missing parent folder mapping for ${folderEntry.manifestId}',
        );
      }

      final createdFolder =
          await ref.read(folderProvider.notifier).createFolder(
                name: folderEntry.name,
                icon: folderEntry.icon.toIconData(),
                color: folderEntry.color,
                customColor: folderEntry.customColorValue == null
                    ? null
                    : Color(folderEntry.customColorValue!),
                parentID: resolvedParentFolderId,
              );
      localFolderIdsByManifestId[folderEntry.manifestId] = createdFolder.id;
      result = result.merge(
        const ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 1,
          themeProfilesImported: 0,
          globalStateRestored: false,
          issues: [],
        ),
      );
    }

    final strategyEntries = [...manifestData.manifest.strategies]
      ..sort((a, b) => a.archivePath.compareTo(b.archivePath));
    for (final strategyEntry in strategyEntries) {
      final targetFolderId = strategyEntry.folderManifestId == null
          ? null
          : localFolderIdsByManifestId[strategyEntry.folderManifestId!];
      if (strategyEntry.folderManifestId != null && targetFolderId == null) {
        throw FormatException(
          'Missing folder mapping for strategy ${strategyEntry.archivePath}',
        );
      }

      try {
        await _importStrategyFile(
          file: XFile(
            _archivePathToFile(
              manifestData.rootDirectory,
              strategyEntry.archivePath,
            ).path,
          ),
          targetFolderId: targetFolderId,
          displayNameOverride: strategyEntry.name,
          themeProfileIdRemap: profileIdRemap,
        );
        result = result.merge(
          const ImportBatchResult(
            strategiesImported: 1,
            foldersCreated: 0,
            themeProfilesImported: 0,
            globalStateRestored: false,
            issues: [],
          ),
        );
      } on NewerVersionImportException {
        result = result.merge(
          ImportBatchResult(
            strategiesImported: 0,
            foldersCreated: 0,
            themeProfilesImported: 0,
            globalStateRestored: false,
            issues: [
              ImportIssue(
                path: strategyEntry.archivePath,
                code: ImportIssueCode.newerVersion,
              ),
            ],
          ),
        );
      } catch (error, stackTrace) {
        _reportImportFailure(
          'Failed to import manifest strategy ${strategyEntry.archivePath}.',
          error: error,
          stackTrace: stackTrace,
          source: 'StrategyImportExportService._importManifestArchive',
        );
        result = result.merge(
          ImportBatchResult(
            strategiesImported: 0,
            foldersCreated: 0,
            themeProfilesImported: 0,
            globalStateRestored: false,
            issues: [
              ImportIssue(
                path: strategyEntry.archivePath,
                code: ImportIssueCode.invalidStrategy,
              ),
            ],
          ),
        );
      }
    }

    final undeclaredIssues = await _collectUndeclaredArchiveIssues(
      manifestData: manifestData,
    );
    if (undeclaredIssues.isNotEmpty) {
      result = result.merge(
        ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 0,
          themeProfilesImported: 0,
          globalStateRestored: false,
          issues: undeclaredIssues,
        ),
      );
    }

    return result;
  }

  void _validateArchiveManifest(_ManifestImportData manifestData) {
    final manifest = manifestData.manifest;
    final folderIds = <String>{};
    final folderPaths = <String>{};
    final rootFolders = <ArchiveFolderEntry>[];

    for (final folder in manifest.folders) {
      if (!folderIds.add(folder.manifestId)) {
        throw FormatException(
            'Duplicate folder manifest ID: ${folder.manifestId}');
      }
      if (!folderPaths.add(folder.archivePath)) {
        throw FormatException(
            'Duplicate folder archive path: ${folder.archivePath}');
      }
      if (folder.parentManifestId == null) {
        rootFolders.add(folder);
      } else if (!manifest.folders.any(
          (candidate) => candidate.manifestId == folder.parentManifestId)) {
        throw FormatException('Missing parent folder for ${folder.manifestId}');
      }
    }

    if (manifest.archiveType == ArchiveType.folderTree) {
      if (rootFolders.length != 1) {
        throw const FormatException(
            'Folder tree archives must contain one root');
      }
      if (rootFolders.single.archivePath.isNotEmpty) {
        throw const FormatException(
          'Folder tree root folder must use the manifest root path',
        );
      }
    }

    final knownFolderIds =
        manifest.folders.map((folder) => folder.manifestId).toSet();
    final strategyPaths = <String>{};
    for (final strategy in manifest.strategies) {
      if (!strategyPaths.add(strategy.archivePath)) {
        throw FormatException(
          'Duplicate strategy archive path: ${strategy.archivePath}',
        );
      }
      if (strategy.folderManifestId != null &&
          !knownFolderIds.contains(strategy.folderManifestId)) {
        throw FormatException(
          'Unknown strategy folder reference: ${strategy.folderManifestId}',
        );
      }
      if (manifest.archiveType == ArchiveType.folderTree &&
          strategy.folderManifestId == null) {
        throw const FormatException(
          'Folder tree strategies must reference the exported root folder',
        );
      }
      if (!_archivePathToFile(manifestData.rootDirectory, strategy.archivePath)
          .existsSync()) {
        throw FormatException('Missing strategy file: ${strategy.archivePath}');
      }
    }
  }

  int _archivePathDepth(String archivePath) {
    if (archivePath.isEmpty) {
      return 0;
    }
    return archivePath.split('/').length;
  }

  File _archivePathToFile(Directory rootDirectory, String archivePath) {
    final normalized = normalizeArchivePath(archivePath);
    final segments =
        normalized.isEmpty ? const <String>[] : normalized.split('/');
    return File(path.joinAll([rootDirectory.path, ...segments]));
  }

  Future<List<ImportIssue>> _collectUndeclaredArchiveIssues({
    required _ManifestImportData manifestData,
  }) async {
    final allowedFiles = <String>{archiveMetadataFileName};
    final allowedDirectories = <String>{};

    void addAllowedDirectoryAncestors(String archivePath) {
      var current = normalizeArchivePath(archivePath);
      if (current.isEmpty) {
        return;
      }
      while (current.isNotEmpty && current != '.') {
        allowedDirectories.add(current);
        final parent = path.posix.dirname(current);
        if (parent == '.' || parent == current) {
          break;
        }
        current = parent;
      }
    }

    for (final folder in manifestData.manifest.folders) {
      addAllowedDirectoryAncestors(folder.archivePath);
    }
    for (final strategy in manifestData.manifest.strategies) {
      final normalizedPath = normalizeArchivePath(strategy.archivePath);
      allowedFiles.add(normalizedPath);
      final parentDirectory = path.posix.dirname(normalizedPath);
      if (parentDirectory != '.') {
        addAllowedDirectoryAncestors(parentDirectory);
      }
    }

    final issues = <ImportIssue>[];
    await for (final entity in manifestData.rootDirectory
        .list(recursive: true, followLinks: false)) {
      final relativePath = normalizeArchivePath(
        path.relative(entity.path, from: manifestData.rootDirectory.path),
      );
      if (relativePath.isEmpty) {
        continue;
      }

      if (entity is File) {
        if (!allowedFiles.contains(relativePath)) {
          issues.add(
            ImportIssue(
              path: entity.path,
              code: ImportIssueCode.unsupportedFile,
            ),
          );
        }
        continue;
      }

      final directoryAllowed = allowedDirectories.contains(relativePath) ||
          allowedFiles.any((allowed) => allowed.startsWith('$relativePath/'));
      if (!directoryAllowed) {
        issues.add(
          ImportIssue(
            path: entity.path,
            code: ImportIssueCode.unsupportedFile,
          ),
        );
      }
    }

    return issues;
  }

  Future<_GlobalImportResult> _importArchiveGlobals(
    ArchiveGlobals globals,
  ) async {
    await MapThemeProfilesProvider.bootstrap();

    final profileBox =
        Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    final appPreferencesBox =
        Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox);
    final favoriteAgentsBox = Hive.box<bool>(HiveBoxNames.favoriteAgentsBox);

    final profileIdRemap = <String, String>{};
    var themeProfilesImported = 0;

    final existingProfiles = profileBox.values.toList();
    for (final importedProfile in globals.themeProfiles) {
      if (importedProfile.isBuiltIn) {
        if (profileBox.get(importedProfile.id) != null) {
          profileIdRemap[importedProfile.id] = importedProfile.id;
        }
        continue;
      }

      final matchingExisting = existingProfiles.firstWhere(
        (existing) =>
            !existing.isBuiltIn &&
            existing.name == importedProfile.name &&
            existing.palette == importedProfile.palette,
        orElse: () => MapThemeProfile(
          id: '',
          name: '',
          palette: MapThemeProfilesProvider.immutableDefaultPalette,
          isBuiltIn: false,
        ),
      );

      if (matchingExisting.id.isNotEmpty) {
        profileIdRemap[importedProfile.id] = matchingExisting.id;
        continue;
      }

      var localProfileId = importedProfile.id;
      if (profileBox.get(localProfileId) != null ||
          MapThemeProfilesProvider.immutableBuiltInProfiles
              .any((profile) => profile.id == localProfileId)) {
        localProfileId = const Uuid().v4();
      }

      final createdProfile = MapThemeProfile(
        id: localProfileId,
        name: importedProfile.name,
        palette: importedProfile.palette,
        isBuiltIn: false,
      );
      await profileBox.put(createdProfile.id, createdProfile);
      existingProfiles.add(createdProfile);
      profileIdRemap[importedProfile.id] = createdProfile.id;
      themeProfilesImported++;
    }

    final resolvedDefaultProfileId = globals
                .defaultThemeProfileIdForNewStrategies ==
            null
        ? MapThemeProfilesProvider.immutableDefaultProfileId
        : profileIdRemap[globals.defaultThemeProfileIdForNewStrategies!] ??
            (profileBox.get(globals.defaultThemeProfileIdForNewStrategies!) !=
                    null
                ? globals.defaultThemeProfileIdForNewStrategies!
                : MapThemeProfilesProvider.immutableDefaultProfileId);

    await appPreferencesBox.put(
      MapThemeProfilesProvider.appPreferencesSingletonKey,
      (appPreferencesBox
                  .get(MapThemeProfilesProvider.appPreferencesSingletonKey) ??
              AppPreferences(
                defaultThemeProfileIdForNewStrategies:
                    MapThemeProfilesProvider.immutableDefaultProfileId,
              ))
          .copyWith(
        defaultThemeProfileIdForNewStrategies: resolvedDefaultProfileId,
      ),
    );

    await favoriteAgentsBox.clear();
    for (final favorite in globals.favoriteAgentTypes()) {
      await favoriteAgentsBox.put(favorite.name, true);
    }

    await ref.read(mapThemeProfilesProvider.notifier).refreshFromHive();
    await ref.read(appPreferencesProvider.notifier).refreshFromHive();
    ref.invalidate(favoriteAgentsProvider);

    return _GlobalImportResult(
      themeProfilesImported: themeProfilesImported,
      globalStateRestored: true,
      profileIdRemap: profileIdRemap,
    );
  }

  Future<void> _importStrategyFile({
    required XFile file,
    required String? targetFolderId,
    String? displayNameOverride,
    Map<String, String> themeProfileIdRemap = const {},
  }) async {
    final newID = const Uuid().v4();
    final isZip = await isZipFile(File(file.path));

    log('Is ZIP file: $isZip');
    final bytes = await file.readAsBytes();
    String jsonData = '';

    try {
      if (isZip) {
        final archive = ZipDecoder().decodeBytes(bytes);

        final imageFolder = await PlacedImageProvider.getImageFolder(newID);
        final tempDirectory = await getTempDirectory(newID);

        await _extractArchiveEntriesToDisk(
          archive: archive,
          destination: tempDirectory,
        );

        final tempDirectoryList = tempDirectory.listSync();
        log('Temp directory list: ${tempDirectoryList.length}.');

        for (final fileEntity in tempDirectoryList) {
          if (fileEntity is File) {
            log(fileEntity.path);
            if (path.extension(fileEntity.path) == '.json') {
              log('Found JSON file');
              jsonData = await fileEntity.readAsString();
            } else if (path.extension(fileEntity.path) != '.ica') {
              final fileName = path.basename(fileEntity.path);
              await fileEntity.copy(path.join(imageFolder.path, fileName));
            }
          }
        }
        if (jsonData.isEmpty) {
          throw Exception('No .ica file found');
        }
      } else {
        jsonData = await file.readAsString();
      }

      final json = jsonDecode(jsonData) as Map<String, dynamic>;
      final versionNumber = int.tryParse(json['versionNumber'].toString()) ??
          Settings.versionNumber;
      _throwIfImportedVersionIsTooNew(versionNumber);

      final drawingData =
          DrawingProvider.fromJson(jsonEncode(json['drawingData'] ?? []));
      final agentData =
          AgentProvider.fromJson(jsonEncode(json['agentData'] ?? []))
              .whereType<PlacedAgent>()
              .toList(growable: false);
      final abilityData =
          AbilityProvider.fromJson(jsonEncode(json['abilityData'] ?? []));
      final mapData = MapProvider.fromJson(jsonEncode(json['mapData']));
      final textData =
          TextProvider.fromJson(jsonEncode(json['textData'] ?? []));

      List<PlacedImage> imageData = [];
      if (!kIsWeb) {
        if (isZip) {
          imageData = await PlacedImageProvider.fromJson(
            jsonString: jsonEncode(json['imageData'] ?? []),
            strategyID: newID,
          );
        } else {
          log('Legacy image data loading');
          imageData = await PlacedImageProvider.legacyFromJson(
            jsonString: jsonEncode(json['imageData'] ?? []),
            strategyID: newID,
          );
        }
      }

      final StrategySettings settingsData;
      final bool isAttack;
      final List<PlacedUtility> utilityData;

      if (json['settingsData'] != null) {
        settingsData = ref
            .read(strategySettingsProvider.notifier)
            .fromJson(jsonEncode(json['settingsData']));
      } else {
        settingsData = StrategySettings();
      }

      if (json['isAttack'] != null) {
        isAttack = json['isAttack'] == 'true' ? true : false;
      } else {
        isAttack = true;
      }

      if (json['utilityData'] != null) {
        utilityData = UtilityProvider.fromJson(jsonEncode(json['utilityData']));
      } else {
        utilityData = [];
      }

      final importedThemeOverridePalette =
          json['themePalette'] is Map<String, dynamic>
              ? MapThemePalette.fromJson(json['themePalette'])
              : (json['themePalette'] is Map
                  ? MapThemePalette.fromJson(
                      Map<String, dynamic>.from(json['themePalette']),
                    )
                  : null);
      final rawImportedThemeProfileId = json['themeProfileId'];
      final importedThemeProfileId = rawImportedThemeProfileId is String &&
              rawImportedThemeProfileId.isNotEmpty
          ? rawImportedThemeProfileId
          : null;
      final resolvedThemeProfileId = importedThemeProfileId == null
          ? null
          : (themeProfileIdRemap[importedThemeProfileId] ??
              importedThemeProfileId);

      final pages = json['pages'] != null
          ? await StrategyPage.listFromJson(
              json: jsonEncode(json['pages']),
              strategyID: newID,
              isZip: isZip,
            )
          : <StrategyPage>[];

      var newStrategy = StrategyData(
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        drawingData: drawingData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        agentData: agentData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        abilityData: abilityData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        textData: textData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        imageData: imageData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        utilityData: utilityData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        isAttack: isAttack,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        strategySettings: settingsData,
        pages: pages,
        id: newID,
        name: displayNameOverride ?? path.basenameWithoutExtension(file.name),
        mapData: mapData,
        versionNumber: versionNumber,
        lastEdited: DateTime.now(),
        folderID: targetFolderId,
        themeProfileId: resolvedThemeProfileId,
        themeOverridePalette: resolvedThemeProfileId == null
            ? importedThemeOverridePalette
            : null,
      );

      newStrategy = await StrategyMigrator.migrateLegacyData(newStrategy);

      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(newStrategy.id, newStrategy);
    } finally {
      if (isZip) {
        try {
          await cleanUpTempDirectory(newID);
        } catch (_) {}
      }
    }
  }

  static bool isNewerVersionImportError(Object error) {
    return error is NewerVersionImportException;
  }

  @visibleForTesting
  static void throwIfImportedVersionIsTooNewForTest(int importedVersion) {
    _throwIfImportedVersionIsTooNew(importedVersion);
  }

  static void _throwIfImportedVersionIsTooNew(int importedVersion) {
    if (importedVersion <= Settings.versionNumber) {
      return;
    }

    throw NewerVersionImportException(
      importedVersion: importedVersion,
      currentVersion: Settings.versionNumber,
    );
  }

  Future<void> _flushCurrentStrategyIfNeeded() async {
    final strategyState = ref.read(strategyProvider);
    final strategyId = strategyState.strategyId;
    if (strategyState.strategyName == null || strategyId == null) {
      return;
    }
    await ref.read(strategyProvider.notifier).forceSaveNow(strategyId);
  }

  Future<void> exportFolder(String folderID) async {
    final folder = Hive.box<Folder>(HiveBoxNames.foldersBox).get(folderID);
    if (folder == null) {
      log("Couldn't find folder to export");
      return;
    }

    await _flushCurrentStrategyIfNeeded();
    final stagingDirectory = await buildFolderExportDirectoryForTest(folderID);

    try {
      final outputFile = await FilePicker.platform.saveFile(
        type: FileType.custom,
        dialogTitle: 'Please select an output file:',
        fileName: '${sanitizeStrategyFileName(folder.name)}.zip',
        allowedExtensions: ['zip'],
      );

      if (outputFile == null) return;

      final encoder = ZipFileEncoder();
      encoder.create(outputFile);
      await encoder.addDirectory(stagingDirectory, includeDirName: false);
      await encoder.close();
    } finally {
      try {
        await stagingDirectory.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> exportLibrary() async {
    await _flushCurrentStrategyIfNeeded();
    final stagingDirectory = await buildLibraryExportDirectoryForTest();

    try {
      final outputFile = await FilePicker.platform.saveFile(
        type: FileType.custom,
        dialogTitle: 'Please select an output file:',
        fileName: buildLibraryBackupFileName(DateTime.now()),
        allowedExtensions: ['zip'],
      );

      if (outputFile == null) return;

      final encoder = ZipFileEncoder();
      encoder.create(outputFile);
      await encoder.addDirectory(stagingDirectory, includeDirName: false);
      await encoder.close();
    } finally {
      try {
        await stagingDirectory.delete(recursive: true);
      } catch (_) {}
    }
  }

  @visibleForTesting
  Future<Directory> buildFolderExportDirectoryForTest(String folderID) async {
    final folder = Hive.box<Folder>(HiveBoxNames.foldersBox).get(folderID);
    if (folder == null) {
      throw StateError("Couldn't find folder to export");
    }

    final stagingDirectory =
        await Directory.systemTemp.createTemp('icarus-folder-export');
    final rootDirectory = await _createUniqueChildDirectory(
      parentDirectory: stagingDirectory,
      desiredName: folder.name,
    );
    final exportState = _ArchiveExportState(rootDirectory: rootDirectory);
    await _writeFolderArchive(
      folderID: folderID,
      exportDirectory: rootDirectory,
      exportState: exportState,
      parentManifestId: null,
      currentArchivePath: '',
    );
    await _writeArchiveManifest(
      exportState: exportState,
      archiveType: ArchiveType.folderTree,
    );
    return stagingDirectory;
  }

  @visibleForTesting
  Future<Directory> buildLibraryExportDirectoryForTest() async {
    final stagingDirectory =
        await Directory.systemTemp.createTemp('icarus-library-export');
    final rootDirectory = Directory(
      path.join(stagingDirectory.path, libraryBackupRootDirectoryName),
    );
    await rootDirectory.create(recursive: true);
    final rootStrategiesDirectory =
        Directory(path.join(rootDirectory.path, 'root_strategies'))
          ..createSync(recursive: true);
    final foldersDirectory = Directory(path.join(rootDirectory.path, 'folders'))
      ..createSync(recursive: true);

    final exportState = _ArchiveExportState(rootDirectory: rootDirectory);

    for (final strategy in _sortedStrategiesForFolder(null)) {
      final strategyArchivePath = await zipStrategy(
        id: strategy.id,
        saveDir: rootStrategiesDirectory,
      );
      exportState.strategies.add(
        ArchiveStrategyEntry(
          name: strategy.name,
          archivePath: normalizeArchivePath(path.posix.join(
            'root_strategies',
            path.basename(strategyArchivePath),
          )),
          folderManifestId: null,
        ),
      );
    }

    for (final rootFolder in _sortedFoldersForParent(null)) {
      final rootFolderDirectory = await _createUniqueChildDirectory(
        parentDirectory: foldersDirectory,
        desiredName: rootFolder.name,
      );
      final rootArchivePath = normalizeArchivePath(path.posix.join(
        'folders',
        path.basename(rootFolderDirectory.path),
      ));
      await _writeFolderArchive(
        folderID: rootFolder.id,
        exportDirectory: rootFolderDirectory,
        exportState: exportState,
        parentManifestId: null,
        currentArchivePath: rootArchivePath,
      );
    }

    await _writeArchiveManifest(
      exportState: exportState,
      archiveType: ArchiveType.libraryBackup,
      globals: _buildLibraryGlobals(),
    );
    return stagingDirectory;
  }

  Future<Directory> _createUniqueChildDirectory({
    required Directory parentDirectory,
    required String desiredName,
  }) async {
    final sanitizedName = sanitizeStrategyFileName(desiredName);
    var candidate = sanitizedName;
    var counter = 1;
    var directory = Directory(path.join(parentDirectory.path, candidate));
    while (await directory.exists()) {
      candidate = '${sanitizedName}_$counter';
      counter++;
      directory = Directory(path.join(parentDirectory.path, candidate));
    }
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _writeFolderArchive({
    required String folderID,
    required Directory exportDirectory,
    required _ArchiveExportState exportState,
    required String? parentManifestId,
    required String currentArchivePath,
  }) async {
    final currentFolder =
        ref.read(folderProvider.notifier).findFolderByID(folderID);
    if (currentFolder == null) {
      return;
    }

    final manifestId = const Uuid().v4();
    exportState.folders.add(
      ArchiveFolderEntry(
        manifestId: manifestId,
        name: currentFolder.name,
        parentManifestId: parentManifestId,
        archivePath: normalizeArchivePath(currentArchivePath),
        icon: ArchiveIconDescriptor.fromIconData(currentFolder.icon),
        color: currentFolder.color,
        customColorValue: currentFolder.customColor?.toARGB32(),
      ),
    );

    for (final strategy in _sortedStrategiesForFolder(folderID)) {
      final strategyArchivePath = await zipStrategy(
        id: strategy.id,
        saveDir: exportDirectory,
      );
      exportState.strategies.add(
        ArchiveStrategyEntry(
          name: strategy.name,
          archivePath: normalizeArchivePath(path.posix.join(
            currentArchivePath,
            path.basename(strategyArchivePath),
          )),
          folderManifestId: manifestId,
        ),
      );
    }

    for (final subFolder in _sortedFoldersForParent(folderID)) {
      final childDirectory = await _createUniqueChildDirectory(
        parentDirectory: exportDirectory,
        desiredName: subFolder.name,
      );
      final childArchivePath = normalizeArchivePath(path.posix.join(
        currentArchivePath,
        path.basename(childDirectory.path),
      ));
      await _writeFolderArchive(
        folderID: subFolder.id,
        exportDirectory: childDirectory,
        exportState: exportState,
        parentManifestId: manifestId,
        currentArchivePath: childArchivePath,
      );
    }
  }

  List<StrategyData> _sortedStrategiesForFolder(String? folderID) {
    final strategies = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .values
        .where((strategy) => strategy.folderID == folderID)
        .toList();
    strategies.sort((a, b) {
      final nameCompare = a.name.compareTo(b.name);
      if (nameCompare != 0) {
        return nameCompare;
      }
      return a.id.compareTo(b.id);
    });
    return strategies;
  }

  List<Folder> _sortedFoldersForParent(String? parentID) {
    final folders = Hive.box<Folder>(HiveBoxNames.foldersBox)
        .values
        .where((folder) => folder.parentID == parentID)
        .toList();
    folders.sort((a, b) {
      final nameCompare = a.name.compareTo(b.name);
      if (nameCompare != 0) {
        return nameCompare;
      }
      return a.id.compareTo(b.id);
    });
    return folders;
  }

  ArchiveGlobals _buildLibraryGlobals() {
    final profiles = Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox)
        .values
        .map(
          (profile) => ArchiveThemeProfileEntry(
            id: profile.id,
            name: profile.name,
            palette: profile.palette,
            isBuiltIn: profile.isBuiltIn,
          ),
        )
        .toList(growable: false);
    final appPreferences =
        Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox)
            .get(MapThemeProfilesProvider.appPreferencesSingletonKey);
    final favoriteAgents = Hive.box<bool>(HiveBoxNames.favoriteAgentsBox)
        .keys
        .whereType<String>()
        .toList()
      ..sort();

    return ArchiveGlobals(
      themeProfiles: profiles,
      defaultThemeProfileIdForNewStrategies:
          appPreferences?.defaultThemeProfileIdForNewStrategies,
      favoriteAgents: favoriteAgents,
    );
  }

  Future<void> _writeArchiveManifest({
    required _ArchiveExportState exportState,
    required ArchiveType archiveType,
    ArchiveGlobals? globals,
  }) async {
    final manifest = ArchiveManifest(
      schemaVersion: archiveManifestSchemaVersion,
      archiveType: archiveType,
      exportedAt: DateTime.now().toUtc(),
      appVersionNumber: Settings.versionNumber,
      folders: exportState.folders,
      strategies: exportState.strategies,
      globals: globals,
    );

    final manifestFile = File(
      path.join(exportState.rootDirectory.path, archiveMetadataFileName),
    );
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
    );
  }

  MapThemePalette _resolveThemePaletteForExport(StrategyData strategy) {
    if (strategy.themeOverridePalette != null) {
      return strategy.themeOverridePalette!;
    }

    final profiles =
        Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    final assignedProfile = strategy.themeProfileId == null
        ? null
        : profiles.get(strategy.themeProfileId!);
    if (assignedProfile != null) {
      return assignedProfile.palette;
    }

    return MapThemeProfilesProvider.immutableDefaultPalette;
  }

  Future<String> zipStrategy({
    required String id,
    Directory? saveDir,
    String? outputFilePath,
  }) async {
    final strategy = Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(id);
    if (strategy == null) {
      log("Couldn't find strategy to export");
      throw StateError("Couldn't find strategy to export");
    }
    return zipStrategyData(
      strategy: strategy,
      saveDir: saveDir,
      outputFilePath: outputFilePath,
    );
  }

  Future<String> zipStrategyData({
    required StrategyData strategy,
    Directory? saveDir,
    String? outputFilePath,
  }) async {

    final payload = {
      'versionNumber': '${Settings.versionNumber}',
      'mapData': '${Maps.mapNames[strategy.mapData]}',
      'themePalette': _resolveThemePaletteForExport(strategy).toJson(),
      if (strategy.themeProfileId != null)
        'themeProfileId': strategy.themeProfileId,
      'pages': strategy.pages.map((page) => page.toJson(strategy.id)).toList(),
    };
    final data = jsonEncode(payload);

    final sanitizedStrategyName = sanitizeStrategyFileName(strategy.name);

    late final String outPath;
    late final String archiveBase;
    if (outputFilePath != null) {
      outPath = outputFilePath;
      archiveBase = path.basenameWithoutExtension(outPath);
    } else {
      final base = sanitizedStrategyName;
      var candidate = base;
      var index = 1;
      while (File(path.join(saveDir!.path, '$candidate.ica')).existsSync()) {
        candidate = '${base}_$index';
        index++;
      }
      archiveBase = candidate;
      outPath = path.join(saveDir.path, '$archiveBase.ica');
    }

    final jsonArchiveFile =
        ArchiveFile.bytes('$archiveBase.json', utf8.encode(data));

    final zipEncoder = ZipFileEncoder()..create(outPath);

    final supportDirectory =
        await _getApplicationSupportDirectoryOrSystemTemp();
    final customDirectory =
        Directory(path.join(supportDirectory.path, strategy.id));
    final imagesDirectory =
        Directory(path.join(customDirectory.path, 'images'));
    await imagesDirectory.create(recursive: true);

    await for (final entity in imagesDirectory.list()) {
      if (entity is File) {
        await zipEncoder.addFile(entity);
      }
    }

    zipEncoder.addArchiveFile(jsonArchiveFile);
    await zipEncoder.close();
    return outPath;
  }

  Future<void> exportCloudStrategy(String strategyId) async {
    final snapshot =
        await ref.read(convexStrategyRepositoryProvider).fetchSnapshot(strategyId);
    final strategy = _strategyDataFromRemoteSnapshot(snapshot);
    final outputFile = await FilePicker.platform.saveFile(
      type: FileType.custom,
      dialogTitle: 'Please select an output file:',
      fileName: '${sanitizeStrategyFileName(strategy.name)}.ica',
      allowedExtensions: ['ica'],
    );
    if (outputFile == null) return;
    await zipStrategyData(strategy: strategy, outputFilePath: outputFile);
  }

  Future<void> exportFile(String id) async {
    await ref.read(strategyProvider.notifier).forceSaveNow(id);

    final outputFile = await FilePicker.platform.saveFile(
      type: FileType.custom,
      dialogTitle: 'Please select an output file:',
      fileName:
          '${sanitizeStrategyFileName(ref.read(strategyProvider).strategyName ?? "new strategy")}.ica',
      allowedExtensions: ['ica'],
    );

    if (outputFile == null) return;
    await zipStrategy(id: id, outputFilePath: outputFile);
  }

  StrategyData _strategyDataFromRemoteSnapshot(RemoteStrategySnapshot snapshot) {
    final pages = <StrategyPage>[];
    final mapValue = Maps.mapNames.entries
        .where((entry) => entry.value == snapshot.header.mapData)
        .map((entry) => entry.key)
        .first;

    for (final remotePage in snapshot.pages..sort((a, b) => a.sortIndex.compareTo(b.sortIndex))) {
      final elements = snapshot.elementsByPage[remotePage.publicId] ?? const [];
      final lineups = snapshot.lineupsByPage[remotePage.publicId] ?? const [];
      final drawingData = <DrawingElement>[];
      final agentData = <PlacedAgentNode>[];
      final abilityData = <PlacedAbility>[];
      final textData = <PlacedText>[];
      final imageData = <PlacedImage>[];
      final utilityData = <PlacedUtility>[];

      for (final element in elements) {
        if (element.deleted) continue;
        final payload = element.decodedPayload();
        try {
          switch (element.elementType) {
            case 'drawing':
              final decoded = DrawingProvider.fromJson(jsonEncode([payload]));
              if (decoded.isNotEmpty) drawingData.add(decoded.first);
              break;
            case 'agent':
              agentData.add(PlacedAgentNode.fromJson(payload));
              break;
            case 'ability':
              abilityData.add(PlacedAbility.fromJson(payload));
              break;
            case 'text':
              textData.add(PlacedText.fromJson(payload));
              break;
            case 'image':
              imageData.add(PlacedImage.fromJson(payload));
              break;
            case 'utility':
              utilityData.add(PlacedUtility.fromJson(payload));
              break;
          }
        } catch (_) {}
      }

      final parsedLineups = <LineUp>[];
      for (final lineup in lineups) {
        if (lineup.deleted) continue;
        try {
          final decoded = jsonDecode(lineup.payload);
          if (decoded is Map<String, dynamic>) {
            parsedLineups.add(LineUp.fromJson(decoded));
          } else if (decoded is Map) {
            parsedLineups.add(LineUp.fromJson(Map<String, dynamic>.from(decoded)));
          }
        } catch (_) {}
      }

      StrategySettings settings = StrategySettings();
      if (remotePage.settings != null && remotePage.settings!.isNotEmpty) {
        try {
          settings = StrategySettings.fromJson(jsonDecode(remotePage.settings!));
        } catch (_) {}
      }

      pages.add(
        StrategyPage(
          id: remotePage.publicId,
          name: remotePage.name,
          drawingData: drawingData,
          agentData: agentData,
          abilityData: abilityData,
          textData: textData,
          imageData: imageData,
          utilityData: utilityData,
          sortIndex: remotePage.sortIndex,
          isAttack: remotePage.isAttack,
          settings: settings,
          lineUps: parsedLineups,
        ),
      );
    }

    MapThemePalette? overridePalette;
    final rawPalette = snapshot.header.themeOverridePalette;
    if (rawPalette != null && rawPalette.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawPalette);
        if (decoded is Map<String, dynamic>) {
          overridePalette = MapThemePalette.fromJson(decoded);
        } else if (decoded is Map) {
          overridePalette = MapThemePalette.fromJson(
            Map<String, dynamic>.from(decoded),
          );
        }
      } catch (_) {}
    }

    return StrategyData(
      id: snapshot.header.publicId,
      name: snapshot.header.name,
      mapData: mapValue,
      versionNumber: Settings.versionNumber,
      lastEdited: snapshot.header.updatedAt,
      createdAt: snapshot.header.createdAt,
      folderID: null,
      themeProfileId: snapshot.header.themeProfileId,
      themeOverridePalette: overridePalette,
      pages: pages,
    );
  }
}
