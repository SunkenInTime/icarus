import { cronJobs } from "convex/server";
import {
  foldContentChangesRef,
  purgeOldOperationEventsRef,
  purgeOldTombstonesRef,
  purgeTrashedPagesRef,
} from "./maintenance";
import { foldCountChangesRef, refreshTrendingRef } from "./community";
import {
  markStaleImageUploadsDeletedRef,
  processAssetReclaimCandidatesRef,
  sweepDeletedImageAssetsRef,
} from "./images";

const crons = cronJobs();

crons.interval(
  "fold-content-changes",
  { hours: 1 },
  foldContentChangesRef,
  {},
);
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
// Community stars and copies reach their posts' counts in batches, so the
// feed's cached pages stay valid between runs.
crons.interval(
  "fold-community-counts",
  { hours: 1 },
  foldCountChangesRef,
  {},
);
crons.interval(
  "refresh-community-trending",
  { hours: 1 },
  refreshTrendingRef,
  {},
);
crons.interval(
  "sweep-deleted-image-assets",
  { hours: 1 },
  sweepDeletedImageAssetsRef,
  {},
);

export default crons;
