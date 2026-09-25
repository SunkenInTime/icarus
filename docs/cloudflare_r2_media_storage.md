# Cloudflare R2 Media Storage

Icarus stores image ownership, strategy access, references, cleanup state, and URL generation in Convex. Cloudflare R2 stores only image bytes.

## Required Convex Environment

- `R2_ACCOUNT_ID`: Cloudflare account ID for the R2 S3 API endpoint.
- `R2_BUCKET`: bucket name.
- `R2_ACCESS_KEY_ID`: R2 S3 API token access key.
- `R2_SECRET_ACCESS_KEY`: R2 S3 API token secret.
- `R2_PUBLIC_BASE_URL`: public custom-domain base URL used for active R2-backed reads, for example `https://media.example.com`.
- `R2_S3_ENDPOINT`: optional override for the S3 endpoint. Defaults to `https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com`.
- `R2_UPLOAD_URL_EXPIRES_SECONDS`: optional signed PUT URL lifetime. Defaults to 900 seconds.
- `R2_MAX_IMAGE_BYTES`: optional max image size. Defaults to 15728640 bytes.

New uploads fail with an actionable Convex error if the required R2 env vars are missing. Legacy Convex-storage assets remain readable through `ctx.storage.getUrl(storageId)`.

## Runtime Flow

1. The client calls `images:generateUploadUrl` with strategy ID, asset ID, MIME type, extension, and byte size.
2. Convex checks editor access, inserts a pending `imageAssets` row, creates a high-entropy immutable R2 object key, and returns a short-lived signed PUT URL.
3. The client uploads bytes directly to R2 with the signed `Content-Type` header.
4. The client calls `images:completeUpload` with the upload intent metadata.
5. Convex verifies the R2 object exists, checks size and MIME metadata, and marks the row active. Replaced objects become durable deletion tombstones and are removed by the cleanup worker.

Strategy/page/lineup payloads store image IDs and local metadata only. Public render URLs are returned from `images:listForStrategy` and `images:getAssetUrl`; they are not persisted in strategy payloads.

## Edge Cases

- Expired upload URL: the client does not persist the signed URL. A retry requests a fresh pending upload intent.
- MIME mismatch: `Content-Type` is signed for PUT and completion verifies R2 metadata against the file extension.
- Oversized image: completion rejects and deletes the uploaded R2 object if it exceeds `R2_MAX_IMAGE_BYTES`.
- PUT succeeds but completion fails: the pending row and object key remain available for retry. The hourly `mark-stale-image-uploads-deleted` job reclaims old pending and failed uploads without user authentication.
- Content lands before its upload: a placed image or lineup image and its upload reach Convex independently. When `ops:applyBatch` accepts content that newly shows an image with no asset row, it inserts a pending placeholder row (no object key). Readers then see the image as on its way rather than missing, and a duplicate waits for it. `images:generateUploadUrl` adopts the placeholder instead of adding a second row. Deleting the image element drops its placeholder unless other content (a lineup) still shows that image. Restoring a deleted element (undo) expects its image again only if the element was first placed within the stale-upload window (24h); an older one would have uploaded or been swept by then. A placeholder whose upload never comes is swept with other stale pending rows, after which the image shows as unavailable. Moving the image later does not bring the placeholder back.
- Pending upload never completed: pending/failed rows are indexed by `uploadStatus` and `updatedAt`. The cron job marks them for cleanup after 24 hours.
- Replacing an asset: the new immutable R2 object is activated before older active rows for the same strategy asset ID are marked deleted.
- Page and Strategy deletion: page cleanup only marks strategy-owned assets that no remaining Page or Lineup references. Strategy cleanup marks every asset with that Strategy's exact Convex ID and leaves legacy rows without a `strategyId` alone.
- Strategy duplication: `strategies:duplicate` gives the copy its own active `imageAssets` row for each image it shows, pointing at the same R2 object key (or Convex storage file) as the original's. Each row is one reference: the cleanup worker removes a row whose bytes another row still points at without touching the object, and deletes the object only with the last row. Deleting either strategy leaves the other's images intact. A duplicate is refused while one of its images is still pending upload, so the copy never permanently lacks an image that was about to land.
- R2 deletion fails: the deleted `imageAssets` row keeps its object key. The worker retries after one minute, and the hourly sweep provides a second recovery path. A 404 counts as success, so retries are safe.
- Duplicate upload attempts: each upload intent gets a unique object key; completion is tied to its `uploadId`.
- Legacy dev data: rows with `storageId` and no R2 provider are treated as active Convex-storage assets.
- Strategy access revoked: Convex stops returning URLs to unauthorized viewers, but already-copied public custom-domain URLs can remain reachable until the object is deleted or Cloudflare access controls/cache expire.
- Custom domain disabled or misconfigured: R2-backed reads require `R2_PUBLIC_BASE_URL` to point at an enabled public bucket custom domain.
- CDN stale copies: object keys are immutable, so replacements use fresh URLs. Deleted old URLs may remain in Cloudflare cache until normal invalidation/expiry unless purged separately.
- Flutter web: the bucket needs the CORS rule under "Web beta" below, or browser uploads and reads fail.

## Web beta

**Required dashboard step. Applied on the `icarus-media` bucket; any new bucket needs it too.** The web beta adds images and lineups from the browser, so the browser talks to R2 directly: it PUTs bytes to the presigned S3 URL (`https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com/...`) and GETs them from `R2_PUBLIC_BASE_URL` to paint them. Both are cross-origin, so the bucket must allow the web beta origins. Without this rule the upload's preflight fails, the media job retries and stays unsynced, and images the browser cannot fetch fall back to a plain `<img>` element.

In the Cloudflare dashboard: R2 > the media bucket > Settings > CORS Policy > Add CORS policy, and paste:

```json
[
  {
    "AllowedOrigins": [
      "https://beta.icarusstrats.com",
      "https://icarus-web-a50.pages.dev",
      "http://localhost:8765",
      "http://127.0.0.1:8765"
    ],
    "AllowedMethods": ["PUT", "GET", "HEAD"],
    "AllowedHeaders": ["Content-Type"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3600
  }
]
```

- `PUT` with `Content-Type` is the presigned upload; `Content-Type` is the only header the client sends and the only one signed besides `host`.
- `GET`/`HEAD` let the web app fetch images from the public custom domain to paint them.
- `ETag` is exposed so the client can pass it to `images:completeUpload`. Completion reads the ETag from R2 itself first, so this is informational.
- Desktop is not a browser and ignores CORS; this rule changes nothing for it.
- Local web builds must run on port 8765 to upload images: `flutter run -d chrome --web-port 8765`, or serve `build/web` on 8765. R2 rejects a port wildcard such as `http://localhost:*`, so the rule lists `localhost` and `127.0.0.1` on that one port. Any other local port has no image uploads.

While an upload is pending, the browser keeps the image bytes in IndexedDB (Hive box `pending_media_bytes_box`) so a refresh does not lose them. Records are scoped to account, strategy and asset, like the upload job, and are dropped once the upload is attached. Images over 15 MB (the `R2_MAX_IMAGE_BYTES` default) are refused before anything is stored. Bytes picked for a lineup that was never saved are dropped when the image is removed or the dialog is closed, and the dialog cannot be closed while Save is queuing them. Drafts older than 7 days with no upload job are removed at launch; a lineup dialog left open that long in another tab loses its picked images.

Known limits:
- Records written by the unreleased first version of this box (raw bytes keyed by asset ID, commit `d191ffe`) are unreadable by the current decoder and are left in place, never pruned. That version never shipped, so only development browsers can hold them; clear the site's IndexedDB to remove them.
- Desktop refuses an image over 15 MB at pick in a cloud strategy, as web does. A local strategy takes any size, since it never uploads.
- A duplicate made after a placeholder was swept copies no image. If the source's upload lands later, the copy never gets it.
- Completion retry window: if `images:completeUpload` keeps failing after the PUT succeeded, the image stays pending (a spinner everywhere) until a retry completes it. After 24h the stale sweep can reclaim the row and its object even while the client is still retrying; the retry then fails, and the image reads as unavailable.

Cloudflare references:

- https://developers.cloudflare.com/r2/api/s3/presigned-urls/
- https://developers.cloudflare.com/r2/api/s3/api/
- https://developers.cloudflare.com/r2/data-access/public-buckets/
