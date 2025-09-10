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
      id: fields[7] as String,
      name: fields[8] as String,
      drawingData: (fields[1] as List).cast<DrawingElement>(),
      agentData: (fields[2] as List).cast<PlacedAgent>(),
      abilityData: (fields[3] as List).cast<PlacedAbility>(),
      textData: (fields[4] as List).cast<PlacedText>(),
      imageData: (fields[5] as List).cast<PlacedImage>(),
      mapData: fields[6] as MapValue,
      versionNumber: (fields[0] as num).toInt(),
      lastEdited: fields[9] as DateTime,
      folderID: fields[13] as String?,
      utilityData: fields[12] == null
          ? const []
          : (fields[12] as List).cast<PlacedUtility>(),
      strategySettings: fields[11] as StrategySettings?,
    );
  }

  @override
  void write(BinaryWriter writer, StrategyData obj) {
    writer
      ..writeByte(14)
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
      ..write(obj.folderID);
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
    )..isDeleted = fields[3] as bool;
  }

  @override
  void write(BinaryWriter writer, PlacedAgent obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.type)
      ..writeByte(1)
      ..write(obj.isAlly)
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
    )
      ..rotation = (fields[2] as num).toDouble()
      ..isDeleted = fields[4] as bool;
  }

  @override
  void write(BinaryWriter writer, PlacedAbility obj) {
    writer
      ..writeByte(7)
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
      ..write(obj.length);
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
    )
      ..rotation = (fields[1] as num).toDouble()
      ..length = (fields[2] as num).toDouble()
      ..isDeleted = fields[4] as bool;
  }

  @override
  void write(BinaryWriter writer, PlacedUtility obj) {
    writer
      ..writeByte(6)
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
      ..write(obj.position);
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
      default:
        return UtilityType.spike;
    }
  }

  @override
  void write(BinaryWriter writer, UtilityType obj) {
    switch (obj) {
      case UtilityType.spike:
        writer.writeByte(0);
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
