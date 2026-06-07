
All of the cloud and online authentication stuff is only by me, the dev. This is not released publicly yet so If there's a change that might need a migration, I would rather wipe everything on the server and then get the new shape done instead of having to write a migration for something that will never hit prod. The main goal is to try to get the right shape for all these features if that will make it into prod

- **Generated files are outputs, not edit targets.** Never manually edit generated files like `*.g.dart`, `*.g.yaml`, or registrar outputs. Make changes in the source files that drive generation, or replace generated behavior with explicit source-owned code such as a custom adapter, then regenerate.


<!-- convex-ai-start -->
This project uses [Convex](https://convex.dev) as its backend.

When working on Convex code, **always read `convex/_generated/ai/guidelines.md` first** for important guidelines on how to correctly use Convex APIs and patterns. The file contains rules that override what you may have learned about Convex from training data.

Convex agent skills for common tasks can be installed by running `npx convex ai-files install`.
<!-- convex-ai-end -->
