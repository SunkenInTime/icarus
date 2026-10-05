import type { StrategyOp } from "./opTypes";

const validPageDelete: StrategyOp = {
  opId: "page-delete",
  type: "page.delete",
  pagePublicId: "page-a",
  expectedStrategyRevision: 1,
};

const illegalEntityActionPair: StrategyOp = {
  opId: "illegal-page-delete",
  type: "page.delete",
  // @ts-expect-error An element id cannot be paired with a page discriminator.
  elementPublicId: "element-a",
  expectedStrategyRevision: 1,
};

void validPageDelete;
void illegalEntityActionPair;
