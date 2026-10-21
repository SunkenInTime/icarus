import { invalidPayloadError } from "./errors";
import { expectedMimeTypeForExtension } from "./r2";

/// The desktop app saves a cloud strategy's images on the user's disk as
/// `<strategy publicId>/<image publicId><extension>`, so these ids become
/// file and folder names. An id that could name a path outside that folder
/// (a separator, a drive colon, "..") would let whoever shares a strategy
/// write files anywhere on the computers that open it. Characters Windows
/// refuses in a file name are refused too, and so is a trailing dot or space,
/// which Windows drops: "<id>." would be the same folder as "<id>". Every id
/// a shipped build makes is a UUID or a copy id built from one, and none is
/// refused.
export function isSafeFileNameId(id: string): boolean {
  return (
    id.length > 0 &&
    id.length <= 200 &&
    id !== "." &&
    id !== ".." &&
    !id.endsWith(".") &&
    !id.endsWith(" ") &&
    !/[\\/:<>"|?*\u0000-\u001f\u007f]/.test(id)
  );
}

/// Whether the desktop app may save a downloaded image as
/// `<id><extension>`: a safe id, and an image extension. Rows from before
/// extensions were recorded have none; their file is the bare id, so that id
/// must not carry an extension of its own ("payload.bat").
export function isSavableImageFileName(id: string, extension: string): boolean {
  if (!isSafeFileNameId(id)) return false;
  return extension === ""
    ? !id.includes(".")
    : expectedMimeTypeForExtension(extension) !== null;
}

export function assertSafeFileNameId(what: string, id: string): void {
  if (!isSafeFileNameId(id)) {
    throw invalidPayloadError(
      `${what} can't be used as a file name: ${JSON.stringify(id)}`,
    );
  }
}
