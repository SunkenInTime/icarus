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
5. Convex verifies the R2 object exists, checks size and MIME metadata, marks the row active, and deletes replaced objects after the new row is active.

Strategy/page/lineup payloads store image IDs and local metadata only. Public render URLs are returned from `images:listForStrategy` and `images:getAssetUrl`; they are not persisted in strategy payloads.

## Edge Cases

- Expired upload URL: the client does not persist the signed URL. A retry requests a fresh pending upload intent.
- MIME mismatch: `Content-Type` is signed for PUT and completion verifies R2 metadata against the file extension.
- Oversized image: completion rejects and deletes the uploaded R2 object if it exceeds `R2_MAX_IMAGE_BYTES`.
- PUT succeeds but completion fails: the pending row and object key remain available for retry. `images:sweepStaleUploadsForStrategy` can delete old pending/failed objects later.
- Pending upload never completed: pending/failed rows are indexed by `uploadStatus` and `updatedAt` for sweep.
- Replacing an asset: the new immutable R2 object is activated before older active rows for the same strategy asset ID are marked deleted.
- Duplicate upload attempts: each upload intent gets a unique object key; completion is tied to its `uploadId`.
- Legacy dev data: rows with `storageId` and no R2 provider are treated as active Convex-storage assets.
- Strategy access revoked: Convex stops returning URLs to unauthorized viewers, but already-copied public custom-domain URLs can remain reachable until the object is deleted or Cloudflare access controls/cache expire.
- Custom domain disabled or misconfigured: R2-backed reads require `R2_PUBLIC_BASE_URL` to point at an enabled public bucket custom domain.
- CDN stale copies: object keys are immutable, so replacements use fresh URLs. Deleted old URLs may remain in Cloudflare cache until normal invalidation/expiry unless purged separately.
- Future Flutter web support: configure R2 bucket CORS for the app origins before browser uploads are enabled.

Cloudflare references:

- https://developers.cloudflare.com/r2/api/s3/presigned-urls/
- https://developers.cloudflare.com/r2/api/s3/api/
- https://developers.cloudflare.com/r2/data-access/public-buckets/
