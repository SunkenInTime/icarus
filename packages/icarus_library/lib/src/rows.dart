import 'json.dart';
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

  Map<String, Object?> toJson();

  @override
  bool operator ==(Object other) =>
      other is Row &&
      other.runtimeType == runtimeType &&
      sameJson(other.toJson(), toJson());

  @override
  int get hashCode => canonicalJson(toJson()).hashCode;
}

final class StrategyRow extends Row {
  const StrategyRow({
    required this.publicId,
    required this.name,
    required this.mapData,
    required this.revision,
    this.folderPublicId,
    this.themeProfileId,
    this.themeOverridePalette,
  });

  static Decoded<StrategyRow> decode(Object? json) =>
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
        return () => StrategyRow(
          publicId: publicId,
          folderPublicId: folderPublicId,
          name: name,
          mapData: mapData,
          themeProfileId: themeProfileId,
          themeOverridePalette: palette,
          revision: revision,
        );
      });

  final String publicId;
  final String? folderPublicId;
  final String name;
  final String mapData;
  final String? themeProfileId;
  final ThemePalette? themeOverridePalette;
  final int revision;

  @override
  StrategyKey get key => StrategyKey(publicId);

  @override
  Map<String, Object?> toJson() => {
    'publicId': publicId,
    if (folderPublicId != null) 'folderPublicId': folderPublicId,
    'name': name,
    'mapData': mapData,
    if (themeProfileId != null) 'themeProfileId': themeProfileId,
    if (themeOverridePalette case final palette?)
      'themeOverridePalette': palette.toJson(),
    'revision': revision,
  };
}

final class FolderRow extends Row {
  const FolderRow({
    required this.publicId,
    required this.name,
    this.parentFolderPublicId,
    this.iconId,
    this.iconCodePoint,
    this.iconFontFamily,
    this.iconFontPackage,
    this.color,
    this.customColorValue,
  });

  static Decoded<FolderRow> decode(Object? json) =>
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
        return () => FolderRow(
          publicId: publicId,
          name: name,
          parentFolderPublicId: parent,
          iconId: iconId,
          iconCodePoint: iconCodePoint,
          iconFontFamily: iconFontFamily,
          iconFontPackage: iconFontPackage,
          color: color,
          customColorValue: customColorValue,
        );
      });

  final String publicId;
  final String name;
  final String? parentFolderPublicId;
  final int? iconId;
  final int? iconCodePoint;
  final String? iconFontFamily;
  final String? iconFontPackage;
  final String? color;
  final int? customColorValue;

  @override
  FolderKey get key => FolderKey(publicId);

  @override
  Map<String, Object?> toJson() => {
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

sealed class PageRow extends Row {
  const PageRow._({
    required this.publicId,
    required this.strategyPublicId,
    required this.name,
    required this.sortIndex,
    required this.isAttack,
    required this.revision,
    required this.isAutoNamed,
  });

  static Decoded<PageRow> decode(Object? json) =>
      JsonFields.read(json, 'page row', (fields) {
        final publicId = fields.string('publicId');
        final strategyPublicId = fields.string('strategyPublicId');
        final name = fields.string('name');
        final isAutoNamed = fields.optionalBoolean('isAutoNamed');
        final sortIndex = fields.whole('sortIndex');
        final isAttack = fields.boolean('isAttack');
        final revision = fields.whole('revision');
        final deleted = fields.boolean('deleted');
        return () => deleted
            ? TrashedPage(
                publicId: publicId,
                strategyPublicId: strategyPublicId,
                name: name,
                isAutoNamed: isAutoNamed,
                sortIndex: sortIndex,
                isAttack: isAttack,
                revision: revision,
              )
            : LivePage(
                publicId: publicId,
                strategyPublicId: strategyPublicId,
                name: name,
                isAutoNamed: isAutoNamed,
                sortIndex: sortIndex,
                isAttack: isAttack,
                revision: revision,
              );
      });

  final String publicId;
  final String strategyPublicId;
  final String name;
  final bool? isAutoNamed;
  final int sortIndex;
  final bool isAttack;
  final int revision;

  @override
  PageKey get key => PageKey(publicId);

  @override
  Map<String, Object?> toJson() => {
    'publicId': publicId,
    'strategyPublicId': strategyPublicId,
    'name': name,
    if (isAutoNamed != null) 'isAutoNamed': isAutoNamed,
    'sortIndex': sortIndex,
    'isAttack': isAttack,
    'revision': revision,
    'deleted': this is TrashedPage,
  };
}

final class LivePage extends PageRow {
  const LivePage({
    required super.publicId,
    required super.strategyPublicId,
    required super.name,
    required super.sortIndex,
    required super.isAttack,
    required super.revision,
    super.isAutoNamed,
  }) : super._();

  LivePage placed({required String name, required int sortIndex}) => LivePage(
    publicId: publicId,
    strategyPublicId: strategyPublicId,
    name: name,
    isAutoNamed: isAutoNamed,
    sortIndex: sortIndex,
    isAttack: isAttack,
    revision: revision + 1,
  );

  TrashedPage trashed() => TrashedPage(
    publicId: publicId,
    strategyPublicId: strategyPublicId,
    name: name,
    isAutoNamed: isAutoNamed,
    sortIndex: sortIndex,
    isAttack: isAttack,
    revision: revision,
  );
}

final class TrashedPage extends PageRow {
  const TrashedPage({
    required super.publicId,
    required super.strategyPublicId,
    required super.name,
    required super.sortIndex,
    required super.isAttack,
    required super.revision,
    super.isAutoNamed,
  }) : super._();
}

final class PageSettingsRow extends Row {
  const PageSettingsRow({
    required this.pagePublicId,
    required this.revision,
    this.settings,
  });

  static Decoded<PageSettingsRow> decode(Object? json) => JsonFields.read(
    json,
    'page settings row',
    (fields) {
      final pagePublicId = fields.string('pagePublicId');
      final settings = fields.optionalDecoded('settings', PageSettings.decode);
      final revision = fields.whole('revision');
      return () => PageSettingsRow(
        pagePublicId: pagePublicId,
        settings: settings,
        revision: revision,
      );
    },
  );

  final String pagePublicId;
  final PageSettings? settings;
  final int revision;

  @override
  PageSettingsKey get key => PageSettingsKey(pagePublicId);

  @override
  Map<String, Object?> toJson() => {
    'pagePublicId': pagePublicId,
    if (settings case final settings?) 'settings': settings.toJson(),
    'revision': revision,
  };
}

sealed class ElementRow extends Row {
  const ElementRow._({required this.publicId, required this.pagePublicId});

  static Decoded<ElementRow> decode(
    Object? json, {
    required bool Function(ElementPayload payload) canRead,
  }) {
    final ids = JsonFields.read(json, 'element row', (fields) {
      final publicId = fields.string('publicId');
      final pagePublicId = fields.string('pagePublicId');
      return () => (publicId, pagePublicId);
    });
    final (publicId, pagePublicId) = switch (ids) {
      Read(:final value) => value,
      CouldNotRead(:final problem) => (null, problem),
    };
    if (publicId == null) return CouldNotRead(json, pagePublicId);
    final readable = JsonFields.read(json, 'element row', (fields) {
      final payload = fields.decoded('payload', ElementPayload.decode);
      if (payload != null && (!payload.isReadable || !canRead(payload))) {
        fields.reject('this build cannot read its payload');
      }
      final sortIndex = fields.whole('sortIndex');
      final revision = fields.whole('revision');
      final deleted = fields.boolean('deleted');
      return () => deleted
          ? DeletedElement(
              publicId: publicId,
              pagePublicId: pagePublicId,
              payload: payload!,
              sortIndex: sortIndex,
              revision: revision,
            )
          : LiveElement(
              publicId: publicId,
              pagePublicId: pagePublicId,
              payload: payload!,
              sortIndex: sortIndex,
              revision: revision,
            );
    });
    return Read(switch (readable) {
      Read(:final value) => value,
      CouldNotRead() => UnreadableElement(
        publicId: publicId,
        pagePublicId: pagePublicId,
        json: json! as Map<Object?, Object?>,
      ),
    });
  }

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
  }) : super._() {
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

  @override
  Map<String, Object?> toJson() => {
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
  }) : super._();
}

final class DeletedElement extends ReadableElementRow {
  DeletedElement({
    required super.publicId,
    required super.pagePublicId,
    required super.payload,
    required super.sortIndex,
    required super.revision,
  }) : super._();
}

final class UnreadableElement extends ElementRow {
  UnreadableElement({
    required super.publicId,
    required super.pagePublicId,
    required Map<Object?, Object?> json,
  }) : json = frozenJsonObject(json),
       super._();

  final Map<String, Object?> json;

  @override
  Map<String, Object?> toJson() => json;
}

sealed class LineupGroupRow extends Row {
  const LineupGroupRow._({
    required this.publicId,
    required this.strategyPublicId,
    required this.pagePublicId,
    required this.payload,
    required this.sortIndex,
    required this.revision,
  });

  static Decoded<LineupGroupRow> decode(Object? json) =>
      JsonFields.read(json, 'lineup group row', (fields) {
        final publicId = fields.string('publicId');
        final strategyPublicId = fields.string('strategyPublicId');
        final pagePublicId = fields.string('pagePublicId');
        final payload = fields.decoded('payload', LineupGroupPayload.decode);
        final sortIndex = fields.whole('sortIndex');
        final revision = fields.whole('revision');
        final deleted = fields.boolean('deleted');
        return () => deleted
            ? DeletedLineupGroup(
                publicId: publicId,
                strategyPublicId: strategyPublicId,
                pagePublicId: pagePublicId,
                payload: payload!,
                sortIndex: sortIndex,
                revision: revision,
              )
            : LiveLineupGroup(
                publicId: publicId,
                strategyPublicId: strategyPublicId,
                pagePublicId: pagePublicId,
                payload: payload!,
                sortIndex: sortIndex,
                revision: revision,
              );
      });

  final String publicId;
  final String strategyPublicId;
  final String pagePublicId;
  final LineupGroupPayload payload;
  final int sortIndex;
  final int revision;

  @override
  LineupGroupKey get key => LineupGroupKey(strategyPublicId, publicId);

  @override
  Map<String, Object?> toJson() => {
    'publicId': publicId,
    'strategyPublicId': strategyPublicId,
    'pagePublicId': pagePublicId,
    'payload': payload.toJson(),
    'sortIndex': sortIndex,
    'revision': revision,
    'deleted': this is DeletedLineupGroup,
  };
}

final class LiveLineupGroup extends LineupGroupRow {
  const LiveLineupGroup({
    required super.publicId,
    required super.strategyPublicId,
    required super.pagePublicId,
    required super.payload,
    required super.sortIndex,
    required super.revision,
  }) : super._();
}

final class DeletedLineupGroup extends LineupGroupRow {
  const DeletedLineupGroup({
    required super.publicId,
    required super.strategyPublicId,
    required super.pagePublicId,
    required super.payload,
    required super.sortIndex,
    required super.revision,
  }) : super._();
}
