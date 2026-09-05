import { cronJobs } from "convex/server";
import {
  purgeOldOperationEventsRef,
  purgeOldTombstonesRef,
} from "./maintenance";
import {
  markStaleImageUploadsDeletedRef,
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
  "mark-stale-image-uploads-deleted",
  { hours: 1 },
  markStaleImageUploadsDeletedRef,
  {},
);
crons.interval(
  "sweep-deleted-image-assets",
  { hours: 1 },
  sweepDeletedImageAssetsRef,
  {},
);

export default crons;
