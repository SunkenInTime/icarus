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

export const lineupGroupPayloadValidator = v.object({
  kind: v.literal("lineupGroup"),
  payloadVersion: v.number(),
  data: cloudJsonObjectValidator,
});
