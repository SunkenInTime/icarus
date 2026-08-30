import 'package:hive_ce/hive.dart';
import 'package:hive_ce_flutter/adapters.dart'
    show ColorAdapter, TimeOfDayAdapter;
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/hive/hive_registrar.g.dart';

const int _folderAdapterTypeId = 17;
const int _colorAdapterTypeId = 200;
const int _timeOfDayAdapterTypeId = 201;

void registerIcarusAdapters(HiveInterface hive) {
  if (!hive.isAdapterRegistered(_colorAdapterTypeId)) {
    hive.registerAdapter(ColorAdapter(typeId: _colorAdapterTypeId));
  }
  if (!hive.isAdapterRegistered(_timeOfDayAdapterTypeId)) {
    hive.registerAdapter(
      const TimeOfDayAdapter(typeId: _timeOfDayAdapterTypeId),
    );
  }
  hive.registerAdapters();
  if (!hive.isAdapterRegistered(freeDrawingAdapterTypeId)) {
    hive.registerAdapter(FreeDrawingAdapter());
  }
  if (!hive.isAdapterRegistered(lineAdapterTypeId)) {
    hive.registerAdapter(LineAdapter());
  }
  if (!hive.isAdapterRegistered(rectangleDrawingAdapterTypeId)) {
    hive.registerAdapter(RectangleDrawingAdapter());
  }
  if (!hive.isAdapterRegistered(ellipseDrawingAdapterTypeId)) {
    hive.registerAdapter(EllipseDrawingAdapter());
  }
  if (!hive.isAdapterRegistered(_folderAdapterTypeId)) {
    hive.registerAdapter(FolderAdapter());
  }
}

void registerIcarusIsolatedAdapters(IsolatedHiveInterface hive) {
  if (!hive.isAdapterRegistered(_colorAdapterTypeId)) {
    hive.registerAdapter(ColorAdapter(typeId: _colorAdapterTypeId));
  }
  if (!hive.isAdapterRegistered(_timeOfDayAdapterTypeId)) {
    hive.registerAdapter(
      const TimeOfDayAdapter(typeId: _timeOfDayAdapterTypeId),
    );
  }
  hive.registerAdapters();
  if (!hive.isAdapterRegistered(freeDrawingAdapterTypeId)) {
    hive.registerAdapter(FreeDrawingAdapter());
  }
  if (!hive.isAdapterRegistered(lineAdapterTypeId)) {
    hive.registerAdapter(LineAdapter());
  }
  if (!hive.isAdapterRegistered(rectangleDrawingAdapterTypeId)) {
    hive.registerAdapter(RectangleDrawingAdapter());
  }
  if (!hive.isAdapterRegistered(ellipseDrawingAdapterTypeId)) {
    hive.registerAdapter(EllipseDrawingAdapter());
  }
  if (!hive.isAdapterRegistered(_folderAdapterTypeId)) {
    hive.registerAdapter(FolderAdapter());
  }
}
