import type { Doc } from "../_generated/dataModel";

export function serializeStrategyHeader(
  strategy: Doc<"strategies">,
  role: "owner" | "editor" | "viewer",
) {
  return {
    publicId: strategy.publicId,
    name: strategy.name,
    mapData: strategy.mapData,
    revision: strategy.revision,
    createdAt: strategy.createdAt,
    updatedAt: strategy.updatedAt,
    themeProfileId: strategy.themeProfileId ?? null,
    themeOverridePalette: strategy.themeOverridePalette ?? null,
    role,
  };
}

export function serializePageDescriptor(
  strategyPublicId: string,
  page: Doc<"pages">,
) {
  return {
    publicId: page.publicId,
    strategyPublicId,
    name: page.name,
    ...(page.isAutoNamed === undefined
      ? {}
      : { isAutoNamed: page.isAutoNamed }),
    sortIndex: page.sortIndex,
    isAttack: page.isAttack,
    revision: page.revision,
    createdAt: page.createdAt,
    updatedAt: page.updatedAt,
  };
}

export function serializePageContent(pageContent: Doc<"pageContents">) {
  return {
    settings: pageContent.settings ?? null,
    revision: pageContent.revision,
    createdAt: pageContent.createdAt,
    updatedAt: pageContent.updatedAt,
  };
}

export function serializeElement(
  strategyPublicId: string,
  pagePublicId: string,
  element: Doc<"elements">,
) {
  return {
    publicId: element.publicId,
    strategyPublicId,
    pagePublicId,
    elementType: element.elementType,
    payload: element.payload,
    sortIndex: element.sortIndex,
    revision: element.revision,
    deleted: element.deleted,
    createdAt: element.createdAt,
    updatedAt: element.updatedAt,
  };
}

export function serializeLineup(
  strategyPublicId: string,
  pagePublicId: string,
  lineup: Doc<"lineups">,
) {
  return {
    publicId: lineup.publicId,
    strategyPublicId,
    pagePublicId,
    payload: lineup.payload,
    sortIndex: lineup.sortIndex,
    revision: lineup.revision,
    deleted: lineup.deleted,
    createdAt: lineup.createdAt,
    updatedAt: lineup.updatedAt,
  };
}
