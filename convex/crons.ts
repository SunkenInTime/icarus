import { cronJobs } from "convex/server";
import {
  purgeOldOperationEventsRef,
  purgeOldTombstonesRef,
} from "./maintenance";

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

export default crons;
