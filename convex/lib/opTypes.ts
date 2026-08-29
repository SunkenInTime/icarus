import { v, type Infer } from "convex/values";
import {
  elementPayloadValidator,
  lineupGroupPayloadValidator,
  mapThemePaletteValidator,
  pagePayloadValidator,
  strategyPatchPayloadValidator,
  strategySettingsValidator,
} from "./payloadValidators";

const strategyPatchOpValidator = v.object({
  opId: v.string(),
  type: v.literal("strategy.patch"),
  payload: strategyPatchPayloadValidator,
  expectedStrategyRevision: v.number(),
});

const pageAddOpValidator = v.object({
  opId: v.string(),
  type: v.literal("page.add"),
  pagePublicId: v.string(),
  payload: pagePayloadValidator,
  sortIndex: v.number(),
  expectedStrategyRevision: v.number(),
});

const pagePatchOpValidator = v.object({
  opId: v.string(),
  type: v.literal("page.patch"),
  pagePublicId: v.string(),
  payload: pagePayloadValidator,
  expectedPageRevision: v.number(),
});

const pageDeleteOpValidator = v.object({
  opId: v.string(),
  type: v.literal("page.delete"),
  pagePublicId: v.string(),
  expectedStrategyRevision: v.number(),
});

const pageReorderOpValidator = v.object({
  opId: v.string(),
  type: v.literal("page.reorder"),
  pagePublicId: v.string(),
  sortIndex: v.number(),
  expectedStrategyRevision: v.number(),
});

const pageContentPatchOpValidator = v.object({
  opId: v.string(),
  type: v.literal("pageContent.patch"),
  pagePublicId: v.string(),
  settings: strategySettingsValidator,
  expectedPageContentRevision: v.number(),
});

const elementAddOpValidator = v.object({
  opId: v.string(),
  type: v.literal("element.add"),
  elementPublicId: v.string(),
  pagePublicId: v.string(),
  payload: elementPayloadValidator,
  sortIndex: v.number(),
  expectedElementRevision: v.optional(v.number()),
});

const elementPatchOpValidator = v.object({
  opId: v.string(),
  type: v.literal("element.patch"),
  elementPublicId: v.string(),
  pagePublicId: v.optional(v.string()),
  payload: v.optional(elementPayloadValidator),
  sortIndex: v.optional(v.number()),
  expectedElementRevision: v.number(),
});

const elementDeleteOpValidator = v.object({
  opId: v.string(),
  type: v.literal("element.delete"),
  elementPublicId: v.string(),
  pagePublicId: v.string(),
  expectedElementRevision: v.number(),
});

const elementReorderOpValidator = v.object({
  opId: v.string(),
  type: v.literal("element.reorder"),
  elementPublicId: v.string(),
  pagePublicId: v.string(),
  sortIndex: v.number(),
  expectedElementRevision: v.number(),
});

const lineupAddOpValidator = v.object({
  opId: v.string(),
  type: v.literal("lineup.add"),
  lineupPublicId: v.string(),
  pagePublicId: v.string(),
  payload: lineupGroupPayloadValidator,
  sortIndex: v.number(),
  expectedLineupRevision: v.optional(v.number()),
});

const lineupPatchOpValidator = v.object({
  opId: v.string(),
  type: v.literal("lineup.patch"),
  lineupPublicId: v.string(),
  pagePublicId: v.optional(v.string()),
  payload: v.optional(lineupGroupPayloadValidator),
  sortIndex: v.optional(v.number()),
  expectedLineupRevision: v.number(),
});

const lineupDeleteOpValidator = v.object({
  opId: v.string(),
  type: v.literal("lineup.delete"),
  lineupPublicId: v.string(),
  pagePublicId: v.string(),
  expectedLineupRevision: v.number(),
});

const lineupReorderOpValidator = v.object({
  opId: v.string(),
  type: v.literal("lineup.reorder"),
  lineupPublicId: v.string(),
  pagePublicId: v.string(),
  sortIndex: v.number(),
  expectedLineupRevision: v.number(),
});

export const strategyOpValidator = v.union(
  strategyPatchOpValidator,
  pageAddOpValidator,
  pagePatchOpValidator,
  pageDeleteOpValidator,
  pageReorderOpValidator,
  pageContentPatchOpValidator,
  elementAddOpValidator,
  elementPatchOpValidator,
  elementDeleteOpValidator,
  elementReorderOpValidator,
  lineupAddOpValidator,
  lineupPatchOpValidator,
  lineupDeleteOpValidator,
  lineupReorderOpValidator,
);

export type StrategyOp = Infer<typeof strategyOpValidator>;

export const opRejectionReasonValidator = v.union(
  v.literal("already_exists"),
  v.literal("element_strategy_mismatch"),
  v.literal("lineup_strategy_mismatch"),
  v.literal("missing_expected_revision"),
  v.literal("not_found"),
  v.literal("page_strategy_mismatch"),
  v.literal("revision_mismatch"),
);

const strategyCurrentValidator = v.object({
  type: v.literal("strategy"),
  revision: v.number(),
  value: v.object({
    name: v.string(),
    mapData: v.string(),
    themeProfileId: v.union(v.string(), v.null()),
    themeOverridePalette: v.union(mapThemePaletteValidator, v.null()),
  }),
});

const pageCurrentValidator = v.object({
  type: v.literal("page"),
  revision: v.number(),
  value: v.object({
    name: v.string(),
    isAttack: v.boolean(),
    sortIndex: v.number(),
  }),
});

const pageContentCurrentValidator = v.object({
  type: v.literal("pageContent"),
  revision: v.number(),
  value: v.object({
    settings: v.union(strategySettingsValidator, v.null()),
  }),
});

const elementCurrentValidator = v.object({
  type: v.literal("element"),
  revision: v.number(),
  value: elementPayloadValidator,
});

const lineupCurrentValidator = v.object({
  type: v.literal("lineup"),
  revision: v.number(),
  value: lineupGroupPayloadValidator,
});

export const currentOpSnapshotValidator = v.union(
  strategyCurrentValidator,
  pageCurrentValidator,
  pageContentCurrentValidator,
  elementCurrentValidator,
  lineupCurrentValidator,
);

export const operationResultValidator = v.union(
  v.object({
    opId: v.string(),
    status: v.literal("applied"),
    appliedRevision: v.number(),
  }),
  v.object({
    opId: v.string(),
    status: v.literal("noop"),
    currentRevision: v.optional(v.number()),
  }),
  v.object({
    opId: v.string(),
    status: v.literal("rejected"),
    reason: opRejectionReasonValidator,
    current: v.optional(currentOpSnapshotValidator),
  }),
  v.object({
    opId: v.string(),
    status: v.literal("failed"),
    code: v.string(),
    rawCode: v.string(),
    message: v.string(),
  }),
);

export const applyBatchResultValidator = v.object({
  strategyPublicId: v.string(),
  results: v.array(operationResultValidator),
});
