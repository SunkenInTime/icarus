import { invalidPayloadError } from "./errors";

/// The desktop app saves a cloud strategy's images on the user's disk as
/// `<strategy publicId>/<image publicId><extension>`, so these ids become
/// file and folder names. An id that could name a path outside that folder
/// (a separator, a drive colon, "..") would let whoever shares a strategy
/// write files anywhere on the computers that open it. Every id a shipped
/// build makes is a UUID or a copy id built from one, and none is refused.
export function isSafeFileNameId(id: string): boolean {
  return (
    id.length > 0 &&
    id.length <= 200 &&
    id !== "." &&
    id !== ".." &&
    !/[\\/:\u0000-\u001f\u007f]/.test(id)
  );
}

export function assertSafeFileNameId(what: string, id: string): void {
  if (!isSafeFileNameId(id)) {
    throw invalidPayloadError(
      `${what} can't be used as a file name: ${JSON.stringify(id)}`,
    );
  }
}
