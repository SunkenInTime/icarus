// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'hive_adapters.dart';

// **************************************************************************
// AdaptersGenerator
// **************************************************************************

class StrategyDataAdapter extends TypeAdapter<StrategyData> {
  @override
  final typeId = 0;

  @override
  StrategyData read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return StrategyData(
      isAttack: fields[10] == null ? true : fields[10] as bool,
      drawingData: fields[1] == null
          ? const []
          : (fields[1] as List).cast<DrawingElement>(),
      agentData: fields[2] == null
          ? const []
          : (fields[2] as List).cast<PlacedAgent>(),
      abilityData: fields[3] == null
          ? const []
          : (fields[3] as List).cast<PlacedAbility>(),
      textData:
          fields[4] == null ? const [] : (fields[4] as List).cast<PlacedText>(),
      imageData: fields[5] == null
          ? const []
          : (fields[5] as List).cast<PlacedImage>(),
      utilityData: fields[12] == null
          ? const []
          : (fields[12] as List).cast<PlacedUtility>(),
      id: fields[7] as String,
      name: fields[8] as String,
      mapData: fields[6] as MapValue,
      versionNumber: (fields[0] as num).toInt(),
      lastEdited: fields[9] as DateTime,
      folderID: fields[13] as String?,
      pages: fields[14] == null
          ? const []
          : (fields[14] as List).cast<StrategyPage>(),
      createdAt: fields[15] as DateTime?,
      strategySettings: fields[11] as StrategySettings?,
    );
  }

  @override
  void write(BinaryWriter writer, StrategyData obj) {
    writer
      ..writeByte(16)
      ..writeByte(0)
      ..write(obj.versionNumber)
      ..writeByte(1)
      ..write(obj.drawingData)
      ..writeByte(2)
      ..write(obj.agentData)
      ..writeByte(3)
      ..write(obj.abilityData)
      ..writeByte(4)
      ..write(obj.textData)
      ..writeByte(5)
      ..write(obj.imageData)
      ..writeByte(6)
      ..write(obj.mapData)
      ..writeByte(7)
      ..write(obj.id)
      ..writeByte(8)
      ..write(obj.name)
      ..writeByte(9)
      ..write(obj.lastEdited)
      ..writeByte(10)
      ..write(obj.isAttack)
      ..writeByte(11)
      ..write(obj.strategySettings)
      ..writeByte(12)
      ..write(obj.utilityData)
      ..writeByte(13)
      ..write(obj.folderID)
      ..writeByte(14)
      ..write(obj.pages)
      ..writeByte(15)
      ..write(obj.createdAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StrategyDataAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class PlacedWidgetAdapter extends TypeAdapter<PlacedWidget> {
  @override
  final typeId = 1;

  @override
  PlacedWidget read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PlacedWidget(
      position: fields[2] as Offset,
      id: fields[0] as String,
      isDeleted: fields[1] == null ? false : fields[1] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, PlacedWidget obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.isDeleted)
      ..writeByte(2)
      ..write(obj.position);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlacedWidgetAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class PlacedAgentAdapter extends TypeAdapter<PlacedAgent> {
  @override
  final typeId = 2;

  @override
  PlacedAgent read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PlacedAgent(
      type: fields[0] as AgentType,
      position: fields[4] as Offset,
      id: fields[2] as String,
      isAlly: fields[1] == null ? true : fields[1] as bool,
      lineUpID: fields[5] as String?,
      state: fields[6] == null ? AgentState.none : fields[6] as AgentState,
    )..isDeleted = fields[3] as bool;
  }

  @override
  void write(BinaryWriter writer, PlacedAgent obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.type)
      ..writeByte(1)
      ..write(obj.isAlly)
      ..writeByte(2)
      ..write(obj.id)
      ..writeByte(3)
      ..write(obj.isDeleted)
      ..writeByte(4)
      ..write(obj.position)
      ..writeByte(5)
      ..write(obj.lineUpID)
      ..writeByte(6)
      ..write(obj.state);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlacedAgentAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class PlacedAbilityAdapter extends TypeAdapter<PlacedAbility> {
  @override
  final typeId = 3;

  @override
  PlacedAbility read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PlacedAbility(
      data: fields[0] as AbilityInfo,
      position: fields[5] as Offset,
      id: fields[3] as String,
      isAlly: fields[1] == null ? true : fields[1] as bool,
      length: fields[6] == null ? 0 : (fields[6] as num).toDouble(),
      lineUpID: fields[7] as String?,
      rotation: fields[2] == null ? 0 : (fields[2] as num).toDouble(),
    )..isDeleted = fields[4] as bool;
  }

  @override
  void write(BinaryWriter writer, PlacedAbility obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.data)
      ..writeByte(1)
      ..write(obj.isAlly)
      ..writeByte(2)
      ..write(obj.rotation)
      ..writeByte(3)
      ..write(obj.id)
      ..writeByte(4)
      ..write(obj.isDeleted)
      ..writeByte(5)
      ..write(obj.position)
      ..writeByte(6)
      ..write(obj.length)
      ..writeByte(7)
      ..write(obj.lineUpID);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlacedAbilityAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class PlacedTextAdapter extends TypeAdapter<PlacedText> {
  @override
  final typeId = 4;

  @override
  PlacedText read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PlacedText(
      position: fields[4] as Offset,
      id: fields[2] as String,
      size: fields[1] == null ? 200 : (fields[1] as num).toDouble(),
    )
      ..text = fields[0] as String
      ..isDeleted = fields[3] as bool;
  }

  @override
  void write(BinaryWriter writer, PlacedText obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.text)
      ..writeByte(1)
      ..write(obj.size)
      ..writeByte(2)
      ..write(obj.id)
      ..writeByte(3)
      ..write(obj.isDeleted)
      ..writeByte(4)
      ..write(obj.position);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlacedTextAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class PlacedImageAdapter extends TypeAdapter<PlacedImage> {
  @override
  final typeId = 5;

  @override
  PlacedImage read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PlacedImage(
      position: fields[6] as Offset,
      id: fields[4] as String,
      aspectRatio: (fields[1] as num).toDouble(),
      scale: (fields[2] as num).toDouble(),
      fileExtension: fields[8] as String?,
    )
      ..link = fields[3] as String
      ..isDeleted = fields[5] as bool;
  }

  @override
  void write(BinaryWriter writer, PlacedImage obj) {
    writer
      ..writeByte(7)
      ..writeByte(1)
      ..write(obj.aspectRatio)
      ..writeByte(2)
      ..write(obj.scale)
      ..writeByte(3)
      ..write(obj.link)
      ..writeByte(4)
      ..write(obj.id)
      ..writeByte(5)
      ..write(obj.isDeleted)
      ..writeByte(6)
      ..write(obj.position)
      ..writeByte(8)
      ..write(obj.fileExtension);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlacedImageAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class MapValueAdapter extends TypeAdapter<MapValue> {
  @override
  final typeId = 6;

  @override
  MapValue read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return MapValue.ascent;
      case 1:
        return MapValue.breeze;
      case 2:
        return MapValue.lotus;
      case 3:
        return MapValue.icebox;
      case 4:
        return MapValue.sunset;
      case 5:
        return MapValue.split;
      case 6:
        return MapValue.haven;
      case 7:
        return MapValue.fracture;
      case 8:
        return MapValue.abyss;
      case 9:
        return MapValue.pearl;
      case 10:
        return MapValue.bind;
      case 11:
        return MapValue.corrode;
      default:
        return MapValue.ascent;
    }
  }

  @override
  void write(BinaryWriter writer, MapValue obj) {
    switch (obj) {
      case MapValue.ascent:
        writer.writeByte(0);
      case MapValue.breeze:
        writer.writeByte(1);
      case MapValue.lotus:
        writer.writeByte(2);
      case MapValue.icebox:
        writer.writeByte(3);
      case MapValue.sunset:
        writer.writeByte(4);
      case MapValue.split:
        writer.writeByte(5);
      case MapValue.haven:
        writer.writeByte(6);
      case MapValue.fracture:
        writer.writeByte(7);
      case MapValue.abyss:
        writer.writeByte(8);
      case MapValue.pearl:
        writer.writeByte(9);
      case MapValue.bind:
        writer.writeByte(10);
      case MapValue.corrode:
        writer.writeByte(11);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MapValueAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AgentTypeAdapter extends TypeAdapter<AgentType> {
  @override
  final typeId = 7;

  @override
  AgentType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return AgentType.jett;
      case 1:
        return AgentType.raze;
      case 2:
        return AgentType.pheonix;
      case 3:
        return AgentType.astra;
      case 4:
        return AgentType.clove;
      case 5:
        return AgentType.breach;
      case 6:
        return AgentType.iso;
      case 7:
        return AgentType.viper;
      case 8:
        return AgentType.deadlock;
      case 9:
        return AgentType.yoru;
      case 10:
        return AgentType.sova;
      case 11:
        return AgentType.skye;
      case 12:
        return AgentType.kayo;
      case 13:
        return AgentType.killjoy;
      case 14:
        return AgentType.brimstone;
      case 15:
        return AgentType.cypher;
      case 16:
        return AgentType.chamber;
      case 17:
        return AgentType.fade;
      case 18:
        return AgentType.gekko;
      case 19:
        return AgentType.harbor;
      case 20:
        return AgentType.neon;
      case 21:
        return AgentType.omen;
      case 22:
        return AgentType.reyna;
      case 23:
        return AgentType.sage;
      case 24:
        return AgentType.vyse;
      case 25:
        return AgentType.tejo;
      case 26:
        return AgentType.waylay;
      case 27:
        return AgentType.veto;
      default:
        return AgentType.jett;
    }
  }

  @override
  void write(BinaryWriter writer, AgentType obj) {
    switch (obj) {
      case AgentType.jett:
        writer.writeByte(0);
      case AgentType.raze:
        writer.writeByte(1);
      case AgentType.pheonix:
        writer.writeByte(2);
      case AgentType.astra:
        writer.writeByte(3);
      case AgentType.clove:
        writer.writeByte(4);
      case AgentType.breach:
        writer.writeByte(5);
      case AgentType.iso:
        writer.writeByte(6);
      case AgentType.viper:
        writer.writeByte(7);
      case AgentType.deadlock:
        writer.writeByte(8);
      case AgentType.yoru:
        writer.writeByte(9);
      case AgentType.sova:
        writer.writeByte(10);
      case AgentType.skye:
        writer.writeByte(11);
      case AgentType.kayo:
        writer.writeByte(12);
      case AgentType.killjoy:
        writer.writeByte(13);
      case AgentType.brimstone:
        writer.writeByte(14);
      case AgentType.cypher:
        writer.writeByte(15);
      case AgentType.chamber:
        writer.writeByte(16);
      case AgentType.fade:
        writer.writeByte(17);
      case AgentType.gekko:
        writer.writeByte(18);
      case AgentType.harbor:
        writer.writeByte(19);
      case AgentType.neon:
        writer.writeByte(20);
      case AgentType.omen:
        writer.writeByte(21);
      case AgentType.reyna:
        writer.writeByte(22);
      case AgentType.sage:
        writer.writeByte(23);
      case AgentType.vyse:
        writer.writeByte(24);
      case AgentType.tejo:
        writer.writeByte(25);
      case AgentType.waylay:
        writer.writeByte(26);
      case AgentType.veto:
        writer.writeByte(27);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class OffsetAdapter extends TypeAdapter<Offset> {
  @override
  final typeId = 8;

  @override
  Offset read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Offset(
      (fields[0] as num).toDouble(),
      (fields[1] as num).toDouble(),
    );
  }

  @override
  void write(BinaryWriter writer, Offset obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.dx)
      ..writeByte(1)
      ..write(obj.dy);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OffsetAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class FreeDrawingAdapter extends TypeAdapter<FreeDrawing> {
  @override
  final typeId = 11;

  @override
  FreeDrawing read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return FreeDrawing(
      listOfPoints: (fields[0] as List?)?.cast<Offset>(),
      color: fields[2] as Color,
      boundingBox: fields[6] as BoundingBox?,
      isDotted: fields[3] as bool,
      hasArrow: fields[4] as bool,
      id: fields[5] as String,
    );
  }

  @override
  void write(BinaryWriter writer, FreeDrawing obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.listOfPoints)
      ..writeByte(2)
      ..write(obj.color)
      ..writeByte(3)
      ..write(obj.isDotted)
      ..writeByte(4)
      ..write(obj.hasArrow)
      ..writeByte(5)
      ..write(obj.id)
      ..writeByte(6)
      ..write(obj.boundingBox);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FreeDrawingAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class LineAdapter extends TypeAdapter<Line> {
  @override
  final typeId = 12;

  @override
  Line read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Line(
      lineStart: fields[0] as Offset,
      lineEnd: fields[1] as Offset,
      color: fields[2] as Color,
      isDotted: fields[3] as bool,
      hasArrow: fields[4] as bool,
      id: fields[5] as String,
    )..boundingBox = fields[6] as BoundingBox?;
  }

  @override
  void write(BinaryWriter writer, Line obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.lineStart)
      ..writeByte(1)
      ..write(obj.lineEnd)
      ..writeByte(2)
      ..write(obj.color)
      ..writeByte(3)
      ..write(obj.isDotted)
      ..writeByte(4)
      ..write(obj.hasArrow)
      ..writeByte(5)
      ..write(obj.id)
      ..writeByte(6)
      ..write(obj.boundingBox);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LineAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class BoundingBoxAdapter extends TypeAdapter<BoundingBox> {
  @override
  final typeId = 13;

  @override
  BoundingBox read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return BoundingBox(
      min: fields[0] as Offset,
      max: fields[1] as Offset,
    );
  }

  @override
  void write(BinaryWriter writer, BoundingBox obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.min)
      ..writeByte(1)
      ..write(obj.max);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BoundingBoxAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class StrategySettingsAdapter extends TypeAdapter<StrategySettings> {
  @override
  final typeId = 14;

  @override
  StrategySettings read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return StrategySettings(
      agentSize: fields[0] == null
          ? Settings.agentSize
          : (fields[0] as num).toDouble(),
      abilitySize: fields[1] == null
          ? Settings.abilitySize
          : (fields[1] as num).toDouble(),
    );
  }

  @override
  void write(BinaryWriter writer, StrategySettings obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.agentSize)
      ..writeByte(1)
      ..write(obj.abilitySize);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StrategySettingsAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class PlacedUtilityAdapter extends TypeAdapter<PlacedUtility> {
  @override
  final typeId = 15;

  @override
  PlacedUtility read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PlacedUtility(
      type: fields[0] as UtilityType,
      position: fields[5] as Offset,
      id: fields[3] as String,
      angle: fields[6] == null ? 0.0 : (fields[6] as num).toDouble(),
      attachedAgentId: fields[7] as String?,
    )
      ..rotation = (fields[1] as num).toDouble()
      ..length = (fields[2] as num).toDouble()
      ..isDeleted = fields[4] as bool;
  }

  @override
  void write(BinaryWriter writer, PlacedUtility obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.type)
      ..writeByte(1)
      ..write(obj.rotation)
      ..writeByte(2)
      ..write(obj.length)
      ..writeByte(3)
      ..write(obj.id)
      ..writeByte(4)
      ..write(obj.isDeleted)
      ..writeByte(5)
      ..write(obj.position)
      ..writeByte(6)
      ..write(obj.angle)
      ..writeByte(7)
      ..write(obj.attachedAgentId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlacedUtilityAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class UtilityTypeAdapter extends TypeAdapter<UtilityType> {
  @override
  final typeId = 16;

  @override
  UtilityType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return UtilityType.spike;
      case 1:
        return UtilityType.viewCone180;
      case 2:
        return UtilityType.viewCone90;
      case 3:
        return UtilityType.viewCone40;
      default:
        return UtilityType.spike;
    }
  }

  @override
  void write(BinaryWriter writer, UtilityType obj) {
    switch (obj) {
      case UtilityType.spike:
        writer.writeByte(0);
      case UtilityType.viewCone180:
        writer.writeByte(1);
      case UtilityType.viewCone90:
        writer.writeByte(2);
      case UtilityType.viewCone40:
        writer.writeByte(3);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UtilityTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class FolderAdapter extends TypeAdapter<Folder> {
  @override
  final typeId = 17;

  @override
  Folder read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Folder(
      name: fields[0] as String,
      id: fields[1] as String,
      dateCreated: fields[3] as DateTime,
      icon: fields[4] as IconData,
      color: fields[5] == null ? FolderColor.red : fields[5] as FolderColor,
      parentID: fields[2] as String?,
      customColor: fields[6] as Color?,
    );
  }

  @override
  void write(BinaryWriter writer, Folder obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.name)
      ..writeByte(1)
      ..write(obj.id)
      ..writeByte(2)
      ..write(obj.parentID)
      ..writeByte(3)
      ..write(obj.dateCreated)
      ..writeByte(4)
      ..write(obj.icon)
      ..writeByte(5)
      ..write(obj.color)
      ..writeByte(6)
      ..write(obj.customColor);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FolderAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class IconDataAdapter extends TypeAdapter<IconData> {
  @override
  final typeId = 18;

  @override
  IconData read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return IconData(
      (fields[0] as num).toInt(),
      fontFamily: fields[1] as String?,
      fontPackage: fields[2] as String?,
      matchTextDirection: fields[3] == null ? false : fields[3] as bool,
      fontFamilyFallback: (fields[4] as List?)?.cast<String>(),
    );
  }

  @override
  void write(BinaryWriter writer, IconData obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.codePoint)
      ..writeByte(1)
      ..write(obj.fontFamily)
      ..writeByte(2)
      ..write(obj.fontPackage)
      ..writeByte(3)
      ..write(obj.matchTextDirection)
      ..writeByte(4)
      ..write(obj.fontFamilyFallback);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IconDataAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class FolderColorAdapter extends TypeAdapter<FolderColor> {
  @override
  final typeId = 19;

  @override
  FolderColor read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return FolderColor.generic;
      case 1:
        return FolderColor.red;
      case 2:
        return FolderColor.blue;
      case 3:
        return FolderColor.green;
      case 4:
        return FolderColor.orange;
      case 5:
        return FolderColor.purple;
      case 6:
        return FolderColor.custom;
      default:
        return FolderColor.generic;
    }
  }

  @override
  void write(BinaryWriter writer, FolderColor obj) {
    switch (obj) {
      case FolderColor.generic:
        writer.writeByte(0);
      case FolderColor.red:
        writer.writeByte(1);
      case FolderColor.blue:
        writer.writeByte(2);
      case FolderColor.green:
        writer.writeByte(3);
      case FolderColor.orange:
        writer.writeByte(4);
      case FolderColor.purple:
        writer.writeByte(5);
      case FolderColor.custom:
        writer.writeByte(6);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FolderColorAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class StrategyPageAdapter extends TypeAdapter<StrategyPage> {
  @override
  final typeId = 20;

  @override
  StrategyPage read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return StrategyPage(
      id: fields[0] as String,
      name: fields[2] as String,
      drawingData: (fields[3] as List).cast<DrawingElement>(),
      agentData: (fields[4] as List).cast<PlacedAgent>(),
      abilityData: (fields[5] as List).cast<PlacedAbility>(),
      textData: (fields[6] as List).cast<PlacedText>(),
      imageData: (fields[7] as List).cast<PlacedImage>(),
      utilityData: (fields[8] as List).cast<PlacedUtility>(),
      sortIndex: (fields[1] as num).toInt(),
      isAttack: fields[9] as bool,
      settings: fields[10] as StrategySettings,
      lineUps:
          fields[11] == null ? const [] : (fields[11] as List).cast<LineUp>(),
    );
  }

  @override
  void write(BinaryWriter writer, StrategyPage obj) {
    writer
      ..writeByte(12)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.sortIndex)
      ..writeByte(2)
      ..write(obj.name)
      ..writeByte(3)
      ..write(obj.drawingData)
      ..writeByte(4)
      ..write(obj.agentData)
      ..writeByte(5)
      ..write(obj.abilityData)
      ..writeByte(6)
      ..write(obj.textData)
      ..writeByte(7)
      ..write(obj.imageData)
      ..writeByte(8)
      ..write(obj.utilityData)
      ..writeByte(9)
      ..write(obj.isAttack)
      ..writeByte(10)
      ..write(obj.settings)
      ..writeByte(11)
      ..write(obj.lineUps);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StrategyPageAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class LineUpAdapter extends TypeAdapter<LineUp> {
  @override
  final typeId = 21;

  @override
  LineUp read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return LineUp(
      id: fields[0] as String,
      agent: fields[1] as PlacedAgent,
      ability: fields[2] as PlacedAbility,
      youtubeLink: fields[3] as String,
      images: (fields[5] as List).cast<SimpleImageData>(),
      notes: fields[4] as String,
    );
  }

  @override
  void write(BinaryWriter writer, LineUp obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.agent)
      ..writeByte(2)
      ..write(obj.ability)
      ..writeByte(3)
      ..write(obj.youtubeLink)
      ..writeByte(4)
      ..write(obj.notes)
      ..writeByte(5)
      ..write(obj.images);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LineUpAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class SimpleImageDataAdapter extends TypeAdapter<SimpleImageData> {
  @override
  final typeId = 22;

  @override
  SimpleImageData read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SimpleImageData(
      id: fields[0] as String,
      fileExtension: fields[1] as String,
    );
  }

  @override
  void write(BinaryWriter writer, SimpleImageData obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.fileExtension);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SimpleImageDataAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AgentStateAdapter extends TypeAdapter<AgentState> {
  @override
  final typeId = 23;

  @override
  AgentState read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return AgentState.dead;
      case 1:
        return AgentState.none;
      default:
        return AgentState.dead;
    }
  }

  @override
  void write(BinaryWriter writer, AgentState obj) {
    switch (obj) {
      case AgentState.dead:
        writer.writeByte(0);
      case AgentState.none:
        writer.writeByte(1);
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentStateAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
