import 'package:icarus/const/maps.dart';

// Migrations through version 97 must reconstruct the scale used at the time.
// Reading Sunset's live scale would apply the version 98 correction twice.
double mapScaleBeforeVersion98(MapValue map) =>
    map == MapValue.sunset ? 0.9502102049421427 : Maps.mapScale[map] ?? 1.0;
