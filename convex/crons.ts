import { cronJobs } from "convex/server";
import {
  purgeOldOperationEventsRef,
  purgeOldTombstonesRef,
  purgeTrashedPagesRef,
} from "./maintenance";
import {
  markStaleImageUploadsDeletedRef,
  processAssetReclaimCandidatesRef,
  sweepDeletedImageAssetsRef,
} from "./images";

const crons = cronJobs();

crons.interval(
  "purge-operation-events",
  { hours: 24 },
  purgeOldOperationEventsRef,
  {},
);
crons.interval(
  "purge-tombstones",
  { hours: 24 },
  purgeOldTombstonesRef,
  {},
);
crons.interval(
  "purge-trashed-pages",
  { hours: 24 },
  purgeTrashedPagesRef,
  {},
);
crons.interval(
  "mark-stale-image-uploads-deleted",
  { hours: 1 },
  markStaleImageUploadsDeletedRef,
  {},
);
// Purges start the reclaim worker themselves; this picks up any batch a
// failed run left queued.
crons.interval(
  "process-asset-reclaim-candidates",
  { hours: 1 },
  processAssetReclaimCandidatesRef,
  {},
);
crons.interval(
  "sweep-deleted-image-assets",
  { hours: 1 },
  sweepDeletedImageAssetsRef,
  {},
);

export default crons;
