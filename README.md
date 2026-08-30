# SiloSwift — Geekapps Silo SDK for Swift

A native Swift SDK for the **Geekapps Silo** media platform API. SiloSwift wraps the Silo REST API with idiomatic Swift: `async/await`, `actor`-based thread safety, `Codable` models, chunked multipart upload with progress callbacks, and zero external dependencies.

---

## Requirements

| Platform | Minimum Version |
|----------|----------------|
| macOS    | 12.0+          |
| iOS      | 15.0+          |
| tvOS     | 15.0+          |
| Swift    | 5.9+           |

---

## Installation

### Swift Package Manager

Add SiloSwift as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/victorfrei/geekapps-silo-swift", from: "1.0.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: ["SiloSwift"]),
]
```

Or add it via Xcode: **File › Add Package Dependencies…** and paste:

```
https://github.com/victorfrei/geekapps-silo-swift
```

---

## Quick Start

```swift
import SiloSwift

let client = SiloClient(options: .init(
    baseUrl: "https://api.silo.geekapps.io",
    appUrl: "https://silo.geekapps.io",
    token: "YOUR_API_TOKEN",
    defaultBucket: "my-bucket"
))

// Upload a file
let data = try Data(contentsOf: URL(fileURLWithPath: "video.mp4"))
let result = try await client.upload(
    data: data,
    fileName: "video.mp4",
    mimeType: "video/mp4"
)
print("Uploaded:", result.id, result.url ?? "")
```

---

## Authentication

Set the bearer token when initialising the client or update it at runtime:

```swift
// At init time
let client = SiloClient(options: .init(
    baseUrl: "https://api.silo.geekapps.io",
    token: "YOUR_API_TOKEN"
))

// At runtime (e.g. after user logs in)
await client.setToken(newToken)
```

All API calls attach the token as `Authorization: Bearer <token>`.

---

## Examples

### Upload a file

```swift
let data = try Data(contentsOf: fileURL)
let result = try await client.upload(
    data: data,
    fileName: "photo.jpg",
    mimeType: "image/jpeg",
    bucket: "photos"
)
print(result.id)
```

### Upload a raw video (no server-side transcoding)

```swift
let data = try Data(contentsOf: rawVideoURL)

// Start the multipart session manually to pass video options
let session = try await client.startMultipartUpload(opts: .init(
    fileName: "master.mp4",
    mimeType: "video/mp4",
    size: data.count,
    bucket: "raw-videos"
))

let chunks = UploadManager.split(data: data)
var parts: [MultipartPart] = []

for (index, chunk) in chunks.enumerated() {
    let partNumber = index + 1
    let partUrl = try await client.getUploadPartUrl(
        fileId: session.fileId,
        uploadId: session.uploadId,
        partNumber: partNumber
    )
    let etag = try await UploadManager.uploadPart(
        url: URL(string: partUrl.url)!,
        data: chunk,
        mimeType: "video/mp4"
    )
    parts.append(MultipartPart(partNumber: partNumber, eTag: etag))
}

let result = try await client.completeMultipartUpload(
    fileId: session.fileId,
    uploadId: session.uploadId,
    parts: parts,
    video: VideoUploadOptions(raw: true)
)
print("Raw video uploaded:", result.id)
```

### Upload with progress

```swift
let result = try await client.upload(
    data: videoData,
    fileName: "movie.mp4",
    mimeType: "video/mp4",
    onProgress: { fraction in
        print(String(format: "Upload progress: %.0f%%", fraction * 100))
    }
)
```

### List files in a bucket

```swift
let page = try await client.listFiles(bucket: "my-bucket", limit: 20)
for file in page.files {
    print(file.id, file.mimeType ?? "unknown")
}

// Next page
if let cursor = page.cursor {
    let nextPage = try await client.listFiles(bucket: "my-bucket", cursor: cursor, limit: 20)
}
```

### Get a signed URL (time-limited access)

```swift
let signed = try await client.getSignedUrl(fileId: "abc123", ttl: 3600)
print(signed.url) // valid for 1 hour
```

### HLS playback URL

```swift
// Returns a URL string with the token embedded — pass it directly to AVPlayer.
let hlsUrl = await client.getHlsStreamUrl(fileId: "abc123")

import AVKit
let player = AVPlayer(url: URL(string: hlsUrl)!)
```

### Batch upload

```swift
let batch = try await client.startBatch(opts: .init(
    files: [
        .init(fileName: "clip1.mp4", mimeType: "video/mp4"),
        .init(fileName: "clip2.mp4", mimeType: "video/mp4"),
    ],
    bucket: "clips",
    video: VideoUploadOptions(thumbnails: true, storyboard: true)
))

print("Batch ID:", batch.batchId)

// Poll until complete
var status = try await client.getBatchStatus(batchId: batch.batchId)
while status.status != "complete" && status.status != "error" {
    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 s
    status = try await client.getBatchStatus(batchId: batch.batchId)
}
```

---

## Full API Reference

### Authentication

| Method | Description |
|--------|-------------|
| `setToken(_ token: String)` | Update the bearer token at runtime |

### Files

| Method | Description |
|--------|-------------|
| `getFileMeta(fileId:)` | Fetch metadata for a private file |
| `getPublicFileMeta(fileId:query:)` | Fetch metadata for a public file |
| `updateFile(fileId:isPrivate:title:description:tags:)` | Update mutable fields on a file |
| `deleteFile(fileId:)` | Delete a file — returns `DeleteFileResult` (`.deleted`, `.queued`, or `.conflict`) instead of throwing on 409 |
| `markFileForDeletion(fileId:)` | Mark a file for deletion when it can't be deleted immediately (still processing) |
| `getSignedUrl(fileId:ttl:disposition:)` | Get a time-limited signed URL |
| `getFileUrl(fileId:ttl:)` | Convenience — returns the signed URL string |
| `getHlsStreamUrl(fileId:)` | Build the HLS master playlist URL (no network call) |
| `getThumbnailUrl(fileId:)` | Fetch the thumbnail URL for a video |
| `getStoryboardUrl(fileId:)` | Fetch the storyboard preview URL |
| `getCaptionsUrl(fileId:)` | Build the captions manifest URL (no network call) |
| `getChaptersUrl(fileId:)` | Build the chapters URL (no network call) |
| `getViewUrl(fileId:)` | Build the viewer app URL (no network call) |

### Simple Upload

| Method | Description |
|--------|-------------|
| `upload(data:fileName:mimeType:bucket:expiresIn:onProgress:)` | Upload data with automatic chunking and progress |

### Multipart Upload

| Method | Description |
|--------|-------------|
| `startMultipartUpload(opts:)` | Open a multipart session |
| `getUploadPartUrl(fileId:uploadId:partNumber:)` | Get a presigned URL for a single part |
| `completeMultipartUpload(fileId:uploadId:parts:image:video:)` | Finalise a multipart upload |
| `abortMultipartUpload(fileId:uploadId:)` | Cancel and clean up a multipart session |

### Batch Upload

| Method | Description |
|--------|-------------|
| `startBatch(opts:)` | Start a batch upload covering multiple files |
| `getBatchStatus(batchId:)` | Poll the status of a batch |
| `cancelBatch(batchId:)` | Cancel a pending batch |

### Buckets

| Method | Description |
|--------|-------------|
| `listBuckets()` | List all accessible buckets |
| `createBucket(name:slug:visibility:)` | Create a new bucket |
| `deleteBucket(bucket:)` | Delete a bucket by slug |
| `listFiles(bucket:cursor:limit:)` | List files with cursor-based pagination |

### Ratings

| Method | Description |
|--------|-------------|
| `setRating(fileId:userId:reaction:)` | Record or update a user reaction |
| `removeRating(fileId:userId:)` | Remove a user's reaction |
| `getAggregateRating(fileId:)` | Get aggregated reaction counts |

### Captions

| Method | Description |
|--------|-------------|
| `uploadCaption(fileId:language:label:vtt:)` | Attach a VTT caption track |
| `deleteCaption(fileId:captionId:)` | Remove a caption track |

### Age Ratings

| Method | Description |
|--------|-------------|
| `listAgeRatings(region:)` | List age rating classifications |

### Dashboard

| Method | Description |
|--------|-------------|
| `getDashboardData()` | Fetch quota, recent files, and bucket summaries |

---

## Error Handling

All throwing methods throw `SiloError`:

```swift
do {
    let file = try await client.getFileMeta(fileId: "missing")
} catch SiloError.httpError(let code, let body) {
    print("API error \(code):", body)
} catch SiloError.uploadFailed(let reason) {
    print("Upload failed:", reason)
} catch {
    print("Unexpected error:", error)
}
```

---

## License

MIT License. Copyright (c) 2024 Geekapps.
