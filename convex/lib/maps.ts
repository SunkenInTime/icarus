import { invalidPayloadError } from "./errors";

/// The maps' wire names, as `Maps.mapNames` in lib/const/maps.dart holds
/// them. Every build lists strategies by these names and cannot list one on
/// a map it does not know, so a new map is added here, and deployed, before
/// any build can make a strategy on it.
const knownMapNames = new Set([
  "ascent",
  "breeze",
  "lotus",
  "icebox",
  "sunset",
  "split",
  "haven",
  "fracture",
  "abyss",
  "pearl",
  "bind",
  "corrode",
  "summit",
]);

export function isKnownMapName(mapData: string): boolean {
  return knownMapNames.has(mapData);
}

/// Refuses a strategy write that would put it on [mapData] when that is not
/// a map's wire name. Only a change is checked: a row already on another
/// value keeps it, so clients that send the map back with other changes
/// still save.
export function assertKnownMapChange(
  mapData: string,
  current: string | undefined,
): void {
  if (mapData === current || isKnownMapName(mapData)) return;
  throw invalidPayloadError("Unknown map");
}
