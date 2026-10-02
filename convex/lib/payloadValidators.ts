import { v, type GenericValidator } from "convex/values";

const jsonPrimitiveValidator: GenericValidator = v.union(
  v.null(),
  v.boolean(),
  v.number(),
  v.string(),
);

const jsonValueValidator1: GenericValidator = v.union(
  jsonPrimitiveValidator,
  v.array(jsonPrimitiveValidator),
  v.record(v.string(), jsonPrimitiveValidator),
);
const jsonValueValidator2: GenericValidator = v.union(
  jsonPrimitiveValidator,
  v.array(jsonValueValidator1),
  v.record(v.string(), jsonValueValidator1),
);
const jsonValueValidator3: GenericValidator = v.union(
  jsonPrimitiveValidator,
  v.array(jsonValueValidator2),
  v.record(v.string(), jsonValueValidator2),
);
const jsonValueValidator4: GenericValidator = v.union(
  jsonPrimitiveValidator,
  v.array(jsonValueValidator3),
  v.record(v.string(), jsonValueValidator3),
);
const jsonValueValidator5: GenericValidator = v.union(
  jsonPrimitiveValidator,
  v.array(jsonValueValidator4),
  v.record(v.string(), jsonValueValidator4),
);
const jsonValueValidator6: GenericValidator = v.union(
  jsonPrimitiveValidator,
  v.array(jsonValueValidator5),
  v.record(v.string(), jsonValueValidator5),
);

export const cloudJsonValueValidator = jsonValueValidator6;
export const cloudJsonObjectValidator = v.record(
  v.string(),
  cloudJsonValueValidator,
);

export const strategySettingsValidator = v.object({
  agentSize: v.number(),
  abilitySize: v.number(),
  useNeutralTeamColors: v.boolean(),
});

export const mapThemePaletteValidator = v.object({
  base: v.string(),
  detail: v.string(),
  highlight: v.string(),
});

export const strategyPatchPayloadValidator = v.object({
  name: v.optional(v.string()),
  mapData: v.optional(v.string()),
  themeProfileId: v.optional(v.string()),
  clearThemeProfileId: v.optional(v.boolean()),
  themeOverridePalette: v.optional(mapThemePaletteValidator),
  clearThemeOverridePalette: v.optional(v.boolean()),
});

export const pagePayloadValidator = v.object({
  name: v.optional(v.string()),
  isAutoNamed: v.optional(v.boolean()),
  settings: v.optional(strategySettingsValidator),
  isAttack: v.optional(v.boolean()),
});

export const elementPayloadKindValidator = v.union(
  v.literal("agent"),
  v.literal("ability"),
  v.literal("drawing"),
  v.literal("text"),
  v.literal("image"),
  v.literal("utility"),
);

export const elementPayloadValidator = v.union(
  v.object({
    kind: v.literal("agent"),
    payloadVersion: v.number(),
    data: cloudJsonObjectValidator,
  }),
  v.object({
    kind: v.literal("ability"),
    payloadVersion: v.number(),
    data: cloudJsonObjectValidator,
  }),
  v.object({
    kind: v.literal("drawing"),
    payloadVersion: v.number(),
    data: cloudJsonObjectValidator,
  }),
  v.object({
    kind: v.literal("text"),
    payloadVersion: v.number(),
    data: cloudJsonObjectValidator,
  }),
  v.object({
    kind: v.literal("image"),
    payloadVersion: v.number(),
    data: cloudJsonObjectValidator,
  }),
  v.object({
    kind: v.literal("utility"),
    payloadVersion: v.number(),
    data: cloudJsonObjectValidator,
  }),
);

// A lineup group is one row: the lineups on one page joined through shared
// spots, with each spot stored once. data holds the group's id (the row's
// key) and its origins (each placing an agent), landings (each placing an
// ability) and links (one per lineup: which origin to which landing, and its
// name, video, notes and images). See assertLineupPayload in ops.ts for the
// rules a row must meet.
export const lineupPayloadKindValidator = v.literal("lineups");
export const LINEUPS_PAYLOAD_VERSION = 1;

export const lineupPayloadValidator = v.object({
  kind: v.literal("lineups"),
  payloadVersion: v.number(),
  data: cloudJsonObjectValidator,
});

// What a lineup op may carry as an argument: a lineup group, or a row of the
// graph clients on protocol 4 wrote. Convex checks arguments before
// the handler runs, so refusing the old kinds here would answer an old
// client with a validation error instead of CLIENT_UPGRADE_REQUIRED from the
// protocol gate. The handler refuses them (see assertLineupPayload in
// ops.ts) and storage takes only lineup groups.
export const lineupOpPayloadValidator = v.union(
  lineupPayloadValidator,
  v.object({
    kind: v.literal("lineupOrigin"),
    payloadVersion: v.number(),
    data: cloudJsonObjectValidator,
  }),
  v.object({
    kind: v.literal("lineupLanding"),
    payloadVersion: v.number(),
    data: cloudJsonObjectValidator,
  }),
  v.object({
    kind: v.literal("lineupLink"),
    payloadVersion: v.number(),
    data: cloudJsonObjectValidator,
  }),
);
