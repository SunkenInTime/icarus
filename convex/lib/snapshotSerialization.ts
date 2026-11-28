import type { Doc } from "../_generated/dataModel";
import { withoutLaterFields } from "./elementFields";
import { withoutPictureId } from "./imageAssets";

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

export function serializeTrashedPageEntry(
  strategyPublicId: string,
  page: Doc<"pages">,
  deletedBy: "you" | "unknown" | { name: string },
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
    deletedAt: page.deletedAt!,
    deletedBy,
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

/// [payload] as a client holds it: without the picture id unless it
/// [acceptsPictureIds] (see withoutPictureId), and without the fields past its
/// [elementFieldLevel] (see withoutLaterFields).
export function elementPayloadForClient(
  payload: Doc<"elements">["payload"],
  acceptsPictureIds: boolean,
  elementFieldLevel: number | undefined,
): Doc<"elements">["payload"] {
  const known = withoutLaterFields(payload, elementFieldLevel);
  return acceptsPictureIds ? known : withoutPictureId(known);
}

export function serializeElement(
  strategyPublicId: string,
  pagePublicId: string,
  element: Doc<"elements">,
  acceptsPictureIds: boolean,
  elementFieldLevel: number | undefined,
) {
  return {
    publicId: element.publicId,
    strategyPublicId,
    pagePublicId,
    elementType: element.elementType,
    payload: elementPayloadForClient(
      element.payload,
      acceptsPictureIds,
      elementFieldLevel,
    ),
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
