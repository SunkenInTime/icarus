import type { Env as WorkerEnv } from "../src/room";

declare global {
  namespace Cloudflare {
    interface Env extends WorkerEnv {}
  }
}
