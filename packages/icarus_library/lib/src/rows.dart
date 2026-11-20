import 'dart:convert';

import 'json.dart';
import 'ops.dart';
import 'payloads.dart';
import 'wire.dart';

sealed class RowKey {
  const RowKey(this.id);

  final String id;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType && other is RowKey && other.id == id;

  @override
  int get hashCode => Object.hash(runtimeType, id);

  @override
  String toString() => '$runtimeType($id)';
}

final class StrategyKey extends RowKey {
  const StrategyKey(super.id);
}

final class FolderKey extends RowKey {
  const FolderKey(super.id);
}

final class PageKey extends RowKey {
  const PageKey(super.id);
}

final class PageSettingsKey extends RowKey {
  const PageSettingsKey(super.id);
}

final class ElementKey extends RowKey {
  const ElementKey(super.id);
}

final class LineupGroupKey extends RowKey {
  const LineupGroupKey(this.strategyPublicId, super.id);

  final String strategyPublicId;

  @override
  bool operator ==(Object other) =>
      other is LineupGroupKey &&
      other.strategyPublicId == strategyPublicId &&
      other.id == id;

  @override
  int get hashCode => Object.hash(LineupGroupKey, strategyPublicId, id);
}

sealed class Row {
  const Row();

  RowKey get key;

  Object? toJson();

  @override
  bool operator ==(Object other) =>
      other is Row &&
      other.runtimeType == runtimeType &&
      sameJson(other.toJson(), toJson());

  @override
  int get hashCode => canonicalJson(toJson()).hashCode;
}

sealed class _Parsed {
  const _Parsed();
}

final class _Json extends _Parsed {
  const _Json(this.value);

  final Object? value;
}

final class _NotJson extends _Parsed {
  const _NotJson(this.problem);

  final String problem;
}

_Parsed _parse(String text) {
  try {
    return _Json(frozenJson(jsonDecode(text)));
  } on FormatException catch (error) {
    return _NotJson('not JSON: ${error.message}');
  }
}

T _fromText<T>(
  String text,
  T Function(Object? json) read,
  T Function(Object? stored, String problem) unreadable,
) => switch (_parse(text)) {
  _Json(:final value) => read(value),
  _NotJson(:final problem) => unreadable(text, problem),
};

Map<String, Object?>? _object(Object? json) => switch (json) {
  final Map<String, Object?> map => map,
  _ => null,
};

int? _wholeAt(Object? json, String key) => switch (_object(json)?[key]) {
  final num value when value.isFinite && value == value.truncate() =>
    value.toInt(),
  _ => null,
};

bool? _booleanAt(Object? json, String key) => switch (_object(json)?[key]) {
  final bool value => value,
  _ => null,
};

const _misplaced = 'stored under the key of another row';

sealed class StrategyRow extends Row {
  const StrategyRow._(this.publicId);

  final String publicId;

  @override
  StrategyKey get key => StrategyKey(publicId);

  static const _known = {
    'publicId',
    'folderPublicId',
    'name',
    'mapData',
    'themeProfileId',
    'themeOverridePalette',
    'revision',
    'createdAt',
    'updatedAt',
  };

  static Decoded<ReadableStrategy> decode(Object? json) =>
      JsonFields.read(json, 'strategy row', (fields) {
        final publicId = fields.string('publicId');
        final folderPublicId = fields.optionalString('folderPublicId');
        final name = fields.string('name');
        final mapData = fields.string('mapData');
        final themeProfileId = fields.optionalString('themeProfileId');
        final palette = fields.optionalDecoded(
          'themeOverridePalette',
          ThemePalette.decode,
        );
        final revision = fields.whole('revision');
        final createdAt = fields.time('createdAt');
        final updatedAt = fields.time('updatedAt');
        final unknown = fields.rest(_known);
        return () => ReadableStrategy(
          publicId: publicId,
          folderPublicId: folderPublicId,
          name: name,
          mapData: mapData,
          themeProfileId: themeProfileId,
          themeOverridePalette: palette,
          revision: revision,
          createdAt: createdAt,
          updatedAt: updatedAt,
          unknownFields: unknown,
        );
      });

  static StrategyRow parse(String text, {required String publicId}) =>
      _fromText(
        text,
        (json) => switch (decode(json)) {
          Read(:final value) when value.publicId == publicId => value,
          Read() => UnreadableStrategy(
            publicId: publicId,
            stored: json,
            problem: _misplaced,
          ),
          CouldNotRead(:final problem) => UnreadableStrategy(
            publicId: publicId,
            stored: json,
            problem: problem,
          ),
        },
        (stored, problem) => UnreadableStrategy(
          publicId: publicId,
          stored: stored,
          problem: problem,
        ),
      );
}

final class ReadableStrategy extends StrategyRow {
  ReadableStrategy({
    required String publicId,
    required this.name,
    required this.mapData,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.folderPublicId,
    this.themeProfileId,
    this.themeOverridePalette,
    Map<String, Object?> unknownFields = const {},
  }) : unknownFields = frozenJsonObject(unknownFields),
       super._(publicId);

  final String? folderPublicId;
  final String name;
  final String mapData;
  final String? themeProfileId;
  final ThemePalette? themeOverridePalette;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, Object?> unknownFields;

  ReadableStrategy rewritten({
    String? name,
    String? mapData,
    ValueEdit<String> folder = const KeepValue(),
    ValueEdit<String> themeProfileId = const KeepValue(),
    ValueEdit<ThemePalette> themeOverridePalette = const KeepValue(),
    int? revision,
    DateTime? updatedAt,
  }) => ReadableStrategy(
    publicId: publicId,
    folderPublicId: edited(folder, folderPublicId),
    name: name ?? this.name,
    mapData: mapData ?? this.mapData,
    themeProfileId: edited(themeProfileId, this.themeProfileId),
    themeOverridePalette: edited(
      themeOverridePalette,
      this.themeOverridePalette,
    ),
    revision: revision ?? this.revision,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    unknownFields: unknownFields,
  );

  @override
  Map<String, Object?> toJson() => {
    ...unknownFields,
    'publicId': publicId,
    if (folderPublicId != null) 'folderPublicId': folderPublicId,
    'name': name,
    'mapData': mapData,
    if (themeProfileId != null) 'themeProfileId': themeProfileId,
    if (themeOverridePalette case final palette?)
      'themeOverridePalette': palette.toJson(),
    'revision': revision,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };
}

final class UnreadableStrategy extends StrategyRow {
  UnreadableStrategy({
    required String publicId,
    required Object? stored,
    required this.problem,
  }) : stored = frozenJson(stored),
       super._(publicId);

  final Object? stored;
  final String problem;

  @override
  Object? toJson() => stored;
}

sealed class FolderRow extends Row {
  const FolderRow._(this.publicId);

  final String publicId;

  @override
  FolderKey get key => FolderKey(publicId);

  static const _known = {
    'publicId',
    'name',
    'parentFolderPublicId',
    'iconId',
    'iconCodePoint',
    'iconFontFamily',
    'iconFontPackage',
    'color',
    'customColorValue',
  };

  static Decoded<ReadableFolder> decode(Object? json) =>
      JsonFields.read(json, 'folder row', (fields) {
        final publicId = fields.string('publicId');
        final name = fields.string('name');
        final parent = fields.optionalString('parentFolderPublicId');
        final iconId = fields.optionalWhole('iconId');
        final iconCodePoint = fields.optionalWhole('iconCodePoint');
        final iconFontFamily = fields.optionalString('iconFontFamily');
        final iconFontPackage = fields.optionalString('iconFontPackage');
        final color = fields.optionalString('color');
        final customColorValue = fields.optionalWhole('customColorValue');
        final unknown = fields.rest(_known);
        return () => ReadableFolder(
          publicId: publicId,
          name: name,
          parentFolderPublicId: parent,
          iconId: iconId,
          iconCodePoint: iconCodePoint,
          iconFontFamily: iconFontFamily,
          iconFontPackage: iconFontPackage,
          color: color,
          customColorValue: customColorValue,
          unknownFields: unknown,
        );
      });

  static FolderRow parse(String text, {required String publicId}) => _fromText(
    text,
    (json) => switch (decode(json)) {
      Read(:final value) when value.publicId == publicId => value,
      Read() => UnreadableFolder(
        publicId: publicId,
        stored: json,
        problem: _misplaced,
      ),
      CouldNotRead(:final problem) => UnreadableFolder(
        publicId: publicId,
        stored: json,
        problem: problem,
      ),
    },
    (stored, problem) =>
        UnreadableFolder(publicId: publicId, stored: stored, problem: problem),
  );
}

final class ReadableFolder extends FolderRow {
  ReadableFolder({
    required String publicId,
    required this.name,
    this.parentFolderPublicId,
    this.iconId,
    this.iconCodePoint,
    this.iconFontFamily,
    this.iconFontPackage,
    this.color,
    this.customColorValue,
    Map<String, Object?> unknownFields = const {},
  }) : unknownFields = frozenJsonObject(unknownFields),
       super._(publicId);

  final String name;
  final String? parentFolderPublicId;
  final int? iconId;
  final int? iconCodePoint;
  final String? iconFontFamily;
  final String? iconFontPackage;
  final String? color;
  final int? customColorValue;
  final Map<String, Object?> unknownFields;

  @override
  Map<String, Object?> toJson() => {
    ...unknownFields,
    'publicId': publicId,
    'name': name,
    if (parentFolderPublicId != null)
      'parentFolderPublicId': parentFolderPublicId,
    if (iconId != null) 'iconId': iconId,
    if (iconCodePoint != null) 'iconCodePoint': iconCodePoint,
    if (iconFontFamily != null) 'iconFontFamily': iconFontFamily,
    if (iconFontPackage != null) 'iconFontPackage': iconFontPackage,
    if (color != null) 'color': color,
    if (customColorValue != null) 'customColorValue': customColorValue,
  };
}

final class UnreadableFolder extends FolderRow {
  UnreadableFolder({
    required String publicId,
    required Object? stored,
    required this.problem,
  }) : stored = frozenJson(stored),
       super._(publicId);

  final Object? stored;
  final String problem;

  @override
  Object? toJson() => stored;
}

sealed class PageRow extends Row {
  const PageRow._({required this.publicId, required this.strategyPublicId});

  final String publicId;
  final String strategyPublicId;

  @override
  PageKey get key => PageKey(publicId);

  static const _known = {
    'publicId',
    'strategyPublicId',
    'name',
    'isAutoNamed',
    'sortIndex',
    'isAttack',
    'revision',
    'deleted',
    'deletedAt',
    'deletedBy',
  };

  static Decoded<ReadablePageRow> decode(Object? json) =>
      JsonFields.read(json, 'page row', (fields) {
        final publicId = fields.string('publicId');
        final strategyPublicId = fields.string('strategyPublicId');
        final name = fields.string('name');
        final isAutoNamed = fields.optionalBoolean('isAutoNamed');
        final sortIndex = fields.whole('sortIndex');
        final isAttack = fields.boolean('isAttack');
        final revision = fields.whole('revision');
        final deleted = fields.boolean('deleted');
        final deletedAt = fields.optionalTime('deletedAt');
        final deletedBy = deletedAt == null
            ? null
            : fields.decoded('deletedBy', PageDeleter.decode);
        if (!deleted && deletedAt != null) {
          fields.reject('a live page has no deletion time');
        }
        if (deletedAt == null && fields.has('deletedBy')) {
          fields.reject('who deleted a page comes with when');
        }
        final unknown = fields.rest(_known);
        return () => switch ((deleted, deletedAt)) {
          (false, _) => LivePage(
            publicId: publicId,
            strategyPublicId: strategyPublicId,
            name: name,
            isAutoNamed: isAutoNamed,
            sortIndex: sortIndex,
            isAttack: isAttack,
            revision: revision,
            unknownFields: unknown,
          ),
          (true, null) => PendingTrashedPage(
            publicId: publicId,
            strategyPublicId: strategyPublicId,
            name: name,
            isAutoNamed: isAutoNamed,
            sortIndex: sortIndex,
            isAttack: isAttack,
            revision: revision,
            unknownFields: unknown,
          ),
          (true, final DateTime deletedAt) => ConfirmedTrashedPage(
            publicId: publicId,
            strategyPublicId: strategyPublicId,
            name: name,
            isAutoNamed: isAutoNamed,
            sortIndex: sortIndex,
            isAttack: isAttack,
            revision: revision,
            deletedAt: deletedAt,
            deletedBy: deletedBy!,
            unknownFields: unknown,
          ),
        };
      });

  static PageRow parse(
    String text, {
    required String publicId,
    required String strategyPublicId,
  }) {
    UnreadablePage unreadable(Object? stored, String problem) => UnreadablePage(
      publicId: publicId,
      strategyPublicId: strategyPublicId,
      sortIndex: _wholeAt(stored, 'sortIndex'),
      trashed: _booleanAt(stored, 'deleted'),
      stored: stored,
      problem: problem,
    );
    return _fromText(
      text,
      (json) => switch (decode(json)) {
        Read(:final value)
            when value.publicId == publicId &&
                value.strategyPublicId == strategyPublicId =>
          value,
        Read() => unreadable(json, _misplaced),
        CouldNotRead(:final problem) => unreadable(json, problem),
      },
      unreadable,
    );
  }
}

sealed class ReadablePageRow extends PageRow {
  ReadablePageRow._({
    required super.publicId,
    required super.strategyPublicId,
    required this.name,
    required this.sortIndex,
    required this.isAttack,
    required this.revision,
    required this.isAutoNamed,
    required Map<String, Object?> unknownFields,
  }) : unknownFields = frozenJsonObject(unknownFields),
       super._();

  final String name;
  final bool? isAutoNamed;
  final int sortIndex;
  final bool isAttack;
  final int revision;
  final Map<String, Object?> unknownFields;

  @override
  Map<String, Object?> toJson() => {
    ...unknownFields,
    'publicId': publicId,
    'strategyPublicId': strategyPublicId,
    'name': name,
    if (isAutoNamed != null) 'isAutoNamed': isAutoNamed,
    'sortIndex': sortIndex,
    'isAttack': isAttack,
    'revision': revision,
    'deleted': this is TrashedPage,
    if (this case ConfirmedTrashedPage(:final deletedAt, :final deletedBy)) ...{
      'deletedAt': deletedAt.millisecondsSinceEpoch,
      'deletedBy': deletedBy.toJson(),
    },
  };
}

final class LivePage extends ReadablePageRow {
  LivePage({
    required super.publicId,
    required super.strategyPublicId,
    required super.name,
    required super.sortIndex,
    required super.isAttack,
    required super.revision,
    super.isAutoNamed,
    super.unknownFields = const {},
  }) : super._();

  LivePage placed({required String name, required int sortIndex}) => LivePage(
    publicId: publicId,
    strategyPublicId: strategyPublicId,
    name: name,
    isAutoNamed: isAutoNamed,
    sortIndex: sortIndex,
    isAttack: isAttack,
    revision: revision + 1,
    unknownFields: unknownFields,
  );

  LivePage patched({String? name, bool? isAutoNamed, bool? isAttack}) =>
      LivePage(
        publicId: publicId,
        strategyPublicId: strategyPublicId,
        name: name ?? this.name,
        isAutoNamed: isAutoNamed ?? this.isAutoNamed,
        sortIndex: sortIndex,
        isAttack: isAttack ?? this.isAttack,
        revision: revision + 1,
        unknownFields: unknownFields,
      );

  PendingTrashedPage trashed() => PendingTrashedPage(
    publicId: publicId,
    strategyPublicId: strategyPublicId,
    name: name,
    isAutoNamed: isAutoNamed,
    sortIndex: sortIndex,
    isAttack: isAttack,
    revision: revision,
    unknownFields: unknownFields,
  );
}

sealed class TrashedPage extends ReadablePageRow {
  TrashedPage._({
    required super.publicId,
    required super.strategyPublicId,
    required super.name,
    required super.sortIndex,
    required super.isAttack,
    required super.revision,
    required super.isAutoNamed,
    required super.unknownFields,
  }) : super._();
}

final class PendingTrashedPage extends TrashedPage {
  PendingTrashedPage({
    required super.publicId,
    required super.strategyPublicId,
    required super.name,
    required super.sortIndex,
    required super.isAttack,
    required super.revision,
    super.isAutoNamed,
    super.unknownFields = const {},
  }) : super._();
}

final class ConfirmedTrashedPage extends TrashedPage {
  ConfirmedTrashedPage({
    required super.publicId,
    required super.strategyPublicId,
    required super.name,
    required super.sortIndex,
    required super.isAttack,
    required super.revision,
    required this.deletedAt,
    required this.deletedBy,
    super.isAutoNamed,
    super.unknownFields = const {},
  }) : super._();

  final DateTime deletedAt;
  final PageDeleter deletedBy;
}

final class UnreadablePage extends PageRow {
  UnreadablePage({
    required super.publicId,
    required super.strategyPublicId,
    required this.sortIndex,
    required this.trashed,
    required Object? stored,
    required this.problem,
  }) : stored = frozenJson(stored),
       super._();

  final int? sortIndex;
  final bool? trashed;
  final Object? stored;
  final String problem;

  @override
  Object? toJson() => stored;
}

sealed class PageDeleter {
  const PageDeleter();

  static Decoded<PageDeleter> decode(Object? json) => switch (json) {
    'you' => const Read(DeletedByYou()),
    'unknown' => const Read(DeleterUnknown()),
    {'name': final String name} => Read(DeletedByName(name)),
    _ => CouldNotRead(json, 'Expected who deleted the page'),
  };

  Object toJson();

  @override
  bool operator ==(Object other) =>
      other is PageDeleter && sameJson(other.toJson(), toJson());

  @override
  int get hashCode => canonicalJson(toJson()).hashCode;
}

final class DeletedByYou extends PageDeleter {
  const DeletedByYou();

  @override
  Object toJson() => 'you';
}

final class DeletedByName extends PageDeleter {
  const DeletedByName(this.name);

  final String name;

  @override
  Object toJson() => {'name': name};
}

final class DeleterUnknown extends PageDeleter {
  const DeleterUnknown();

  @override
  Object toJson() => 'unknown';
}

sealed class PageSettingsRow extends Row {
  const PageSettingsRow._(this.pagePublicId);

  final String pagePublicId;

  @override
  PageSettingsKey get key => PageSettingsKey(pagePublicId);

  static Decoded<ReadablePageSettings> decode(
    Object? json,
  ) => JsonFields.read(json, 'page settings row', (fields) {
    final pagePublicId = fields.string('pagePublicId');
    final settings = fields.optionalDecoded('settings', PageSettings.decode);
    final revision = fields.whole('revision');
    final unknown = fields.rest(const {'pagePublicId', 'settings', 'revision'});
    return () => ReadablePageSettings(
      pagePublicId: pagePublicId,
      settings: settings,
      revision: revision,
      unknownFields: unknown,
    );
  });

  static PageSettingsRow parse(String text, {required String pagePublicId}) =>
      _fromText(
        text,
        (json) => switch (decode(json)) {
          Read(:final value) when value.pagePublicId == pagePublicId => value,
          Read() => UnreadablePageSettings(
            pagePublicId: pagePublicId,
            stored: json,
            problem: _misplaced,
          ),
          CouldNotRead(:final problem) => UnreadablePageSettings(
            pagePublicId: pagePublicId,
            stored: json,
            problem: problem,
          ),
        },
        (stored, problem) => UnreadablePageSettings(
          pagePublicId: pagePublicId,
          stored: stored,
          problem: problem,
        ),
      );
}

final class ReadablePageSettings extends PageSettingsRow {
  ReadablePageSettings({
    required String pagePublicId,
    required this.revision,
    this.settings,
    Map<String, Object?> unknownFields = const {},
  }) : unknownFields = frozenJsonObject(unknownFields),
       super._(pagePublicId);

  final PageSettings? settings;
  final int revision;
  final Map<String, Object?> unknownFields;

  ReadablePageSettings withSettings(PageSettings settings) =>
      ReadablePageSettings(
        pagePublicId: pagePublicId,
        settings: settings,
        revision: revision + 1,
        unknownFields: unknownFields,
      );

  @override
  Map<String, Object?> toJson() => {
    ...unknownFields,
    'pagePublicId': pagePublicId,
    if (settings case final settings?) 'settings': settings.toJson(),
    'revision': revision,
  };
}

final class UnreadablePageSettings extends PageSettingsRow {
  UnreadablePageSettings({
    required String pagePublicId,
    required Object? stored,
    required this.problem,
  }) : stored = frozenJson(stored),
       super._(pagePublicId);

  final Object? stored;
  final String problem;

  @override
  Object? toJson() => stored;
}

sealed class ElementRow extends Row {
  const ElementRow._({required this.publicId, required this.pagePublicId});

  static const _known = {
    'publicId',
    'pagePublicId',
    'payload',
    'sortIndex',
    'revision',
    'deleted',
  };

  static Decoded<ElementRow> decode(
    Object? json, {
    required bool Function(ElementPayload payload) canRead,
  }) {
    final frozen = frozenJsonObjectOrNull(json);
    if (frozen == null) {
      return CouldNotRead(json, 'Expected element row to be a JSON object');
    }
    final ids = JsonFields.read(frozen, 'element row', (fields) {
      final publicId = fields.string('publicId');
      final pagePublicId = fields.string('pagePublicId');
      return () => (publicId, pagePublicId);
    });
    final (publicId, pagePublicId) = switch (ids) {
      Read(:final value) => value,
      CouldNotRead(:final problem) => (null, problem),
    };
    if (publicId == null) return CouldNotRead(json, pagePublicId);
    return Read(_readable(frozen, publicId, pagePublicId, canRead));
  }

  static ElementRow _readable(
    Map<String, Object?> frozen,
    String publicId,
    String pagePublicId,
    bool Function(ElementPayload payload) canRead,
  ) {
    final readable = JsonFields.read(frozen, 'element row', (fields) {
      final payload = fields.decoded('payload', ElementPayload.decode);
      if (payload != null && (!payload.isReadable || !canRead(payload))) {
        fields.reject('this build cannot read its payload');
      }
      final sortIndex = fields.whole('sortIndex');
      final revision = fields.whole('revision');
      final deleted = fields.boolean('deleted');
      final unknown = fields.rest(_known);
      return () => deleted
          ? DeletedElement(
              publicId: publicId,
              pagePublicId: pagePublicId,
              payload: payload!,
              sortIndex: sortIndex,
              revision: revision,
              unknownFields: unknown,
            )
          : LiveElement(
              publicId: publicId,
              pagePublicId: pagePublicId,
              payload: payload!,
              sortIndex: sortIndex,
              revision: revision,
              unknownFields: unknown,
            );
    });
    return switch (readable) {
      Read(:final value) => value,
      CouldNotRead(:final problem) => UnreadableElement(
        publicId: publicId,
        pagePublicId: pagePublicId,
        stored: frozen,
        problem: problem,
      ),
    };
  }

  static ElementRow parse(
    String text, {
    required String publicId,
    required String pagePublicId,
    required bool Function(ElementPayload payload) canRead,
  }) => _fromText(
    text,
    (json) => switch (decode(json, canRead: canRead)) {
      Read(:final value)
          when value.publicId == publicId &&
              value.pagePublicId == pagePublicId =>
        value,
      Read() => UnreadableElement(
        publicId: publicId,
        pagePublicId: pagePublicId,
        stored: json,
        problem: _misplaced,
      ),
      CouldNotRead(:final problem) => UnreadableElement(
        publicId: publicId,
        pagePublicId: pagePublicId,
        stored: json,
        problem: problem,
      ),
    },
    (stored, problem) => UnreadableElement(
      publicId: publicId,
      pagePublicId: pagePublicId,
      stored: stored,
      problem: problem,
    ),
  );

  final String publicId;
  final String pagePublicId;

  @override
  ElementKey get key => ElementKey(publicId);
}

sealed class ReadableElementRow extends ElementRow {
  ReadableElementRow._({
    required super.publicId,
    required super.pagePublicId,
    required this.payload,
    required this.sortIndex,
    required this.revision,
    required Map<String, Object?> unknownFields,
  }) : unknownFields = frozenJsonObject(unknownFields),
       super._() {
    if (!payload.isReadable) {
      throw ArgumentError.value(
        payload.payloadVersion,
        'payload',
        'is from a newer build; keep it as an UnreadableElement',
      );
    }
  }

  final ElementPayload payload;
  final int sortIndex;
  final int revision;
  final Map<String, Object?> unknownFields;

  @override
  Map<String, Object?> toJson() => {
    ...unknownFields,
    'publicId': publicId,
    'pagePublicId': pagePublicId,
    'payload': payload.toJson(),
    'sortIndex': sortIndex,
    'revision': revision,
    'deleted': this is DeletedElement,
  };
}

final class LiveElement extends ReadableElementRow {
  LiveElement({
    required super.publicId,
    required super.pagePublicId,
    required super.payload,
    required super.sortIndex,
    required super.revision,
    super.unknownFields = const {},
  }) : super._();
}

final class DeletedElement extends ReadableElementRow {
  DeletedElement({
    required super.publicId,
    required super.pagePublicId,
    required super.payload,
    required super.sortIndex,
    required super.revision,
    super.unknownFields = const {},
  }) : super._();
}

final class UnreadableElement extends ElementRow {
  UnreadableElement({
    required super.publicId,
    required super.pagePublicId,
    required Object? stored,
    required this.problem,
  }) : stored = frozenJson(stored),
       super._();

  final Object? stored;
  final String problem;

  @override
  Object? toJson() => stored;

  bool? get deleted => _booleanAt(stored, 'deleted');
}

sealed class LineupGroupRow extends Row {
  const LineupGroupRow._({
    required this.publicId,
    required this.strategyPublicId,
    required this.pagePublicId,
  });

  static const _known = {
    'publicId',
    'strategyPublicId',
    'pagePublicId',
    'payload',
    'sortIndex',
    'revision',
    'deleted',
  };

  static Decoded<ReadableLineupGroupRow> decode(Object? json) =>
      JsonFields.read(json, 'lineup group row', (fields) {
        final publicId = fields.string('publicId');
        final strategyPublicId = fields.string('strategyPublicId');
        final pagePublicId = fields.string('pagePublicId');
        final payload = fields.decoded('payload', LineupGroupPayload.decode);
        final sortIndex = fields.whole('sortIndex');
        final revision = fields.whole('revision');
        final deleted = fields.boolean('deleted');
        final unknown = fields.rest(_known);
        return () => deleted
            ? DeletedLineupGroup(
                publicId: publicId,
                strategyPublicId: strategyPublicId,
                pagePublicId: pagePublicId,
                payload: payload!,
                sortIndex: sortIndex,
                revision: revision,
                unknownFields: unknown,
              )
            : LiveLineupGroup(
                publicId: publicId,
                strategyPublicId: strategyPublicId,
                pagePublicId: pagePublicId,
                payload: payload!,
                sortIndex: sortIndex,
                revision: revision,
                unknownFields: unknown,
              );
      });

  static LineupGroupRow parse(
    String text, {
    required String publicId,
    required String strategyPublicId,
    required String pagePublicId,
  }) {
    UnreadableLineupGroup unreadable(Object? stored, String problem) =>
        UnreadableLineupGroup(
          publicId: publicId,
          strategyPublicId: strategyPublicId,
          pagePublicId: pagePublicId,
          stored: stored,
          problem: problem,
        );
    return _fromText(
      text,
      (json) => switch (decode(json)) {
        Read(:final value)
            when value.publicId == publicId &&
                value.strategyPublicId == strategyPublicId &&
                value.pagePublicId == pagePublicId =>
          value,
        Read() => unreadable(json, _misplaced),
        CouldNotRead(:final problem) => unreadable(json, problem),
      },
      unreadable,
    );
  }

  final String publicId;
  final String strategyPublicId;
  final String pagePublicId;

  @override
  LineupGroupKey get key => LineupGroupKey(strategyPublicId, publicId);
}

sealed class ReadableLineupGroupRow extends LineupGroupRow {
  ReadableLineupGroupRow._({
    required super.publicId,
    required super.strategyPublicId,
    required super.pagePublicId,
    required this.payload,
    required this.sortIndex,
    required this.revision,
    required Map<String, Object?> unknownFields,
  }) : unknownFields = frozenJsonObject(unknownFields),
       super._();

  final LineupGroupPayload payload;
  final int sortIndex;
  final int revision;
  final Map<String, Object?> unknownFields;

  @override
  Map<String, Object?> toJson() => {
    ...unknownFields,
    'publicId': publicId,
    'strategyPublicId': strategyPublicId,
    'pagePublicId': pagePublicId,
    'payload': payload.toJson(),
    'sortIndex': sortIndex,
    'revision': revision,
    'deleted': this is DeletedLineupGroup,
  };
}

final class LiveLineupGroup extends ReadableLineupGroupRow {
  LiveLineupGroup({
    required super.publicId,
    required super.strategyPublicId,
    required super.pagePublicId,
    required super.payload,
    required super.sortIndex,
    required super.revision,
    super.unknownFields = const {},
  }) : super._();
}

final class DeletedLineupGroup extends ReadableLineupGroupRow {
  DeletedLineupGroup({
    required super.publicId,
    required super.strategyPublicId,
    required super.pagePublicId,
    required super.payload,
    required super.sortIndex,
    required super.revision,
    super.unknownFields = const {},
  }) : super._();
}

final class UnreadableLineupGroup extends LineupGroupRow {
  UnreadableLineupGroup({
    required super.publicId,
    required super.strategyPublicId,
    required super.pagePublicId,
    required Object? stored,
    required this.problem,
  }) : stored = frozenJson(stored),
       super._();

  final Object? stored;
  final String problem;

  @override
  Object? toJson() => stored;
}
