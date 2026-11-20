# ADR 0010: Cloud items this build cannot draw stay on the page

**Status:** Accepted (2026-11-20)
**Feature:** Cloud page hydration and sync (`lib/strategy/strategy_page_source.dart`, `lib/strategy/cloud_element_decoding.dart`, `lib/providers/collab/active_page_live_sync_provider.dart`)

## Context

A cloud page can hold a row this build cannot draw: an element of a kind a newer version of Icarus added, or one whose data this build can't read as its kind. The server accepts any JSON object as an element's data, so such rows reach every client.

Sync works out what to send by comparing the canvas with the server's version of the page it was drawn from. Hydration used to leave those rows off the canvas without saying so. Their absence then looked like the user had deleted them, and the next edit of anything on the page sent a delete: a teammate's work, or work made in a newer version, was lost by someone who never touched it. Page settings that failed to read had the same problem: the canvas showed defaults, and the next edit wrote the defaults over them.

## Decision

The canvas carries what it cannot draw. `readCloudElement` reads each row as drawn, unreadable, or an unknown kind. Hydration keeps every row it did not draw, with its payload and place exactly as the server has them, in `unshownCloudContentProvider`, and sync counts those rows as part of the canvas. They therefore always match the server and are never sent. Unreadable settings are kept the same way and are sent only once the user changes a setting. The editor says, in a toast, that the page has items this version can't show.

## Consequences

- An item this build can't draw can't be removed from this build, not even by clearing the canvas. Only deleting the page, or a build that can draw the item, removes it. We chose this because removing something you can't see is the mistake this ADR exists to prevent.
- A copy of the page made on this computer ("+" while offline) includes these rows unchanged, so a copy is never smaller than the page.
- Unreadable page settings are replaced as soon as the user changes any setting on that page, because the change is made to the defaults on screen. Applying a setting to all pages does the same for every page.
