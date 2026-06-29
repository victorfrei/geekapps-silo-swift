import Foundation

/// The default chunk size used when performing multipart uploads: 8 MB.
private let defaultChunkSize = 8 * 1024 * 1024

/// Thread-safe Silo API client implemented as a Swift `actor`.
///
/// All network calls use `async/await` and throw ``SiloError`` on failure.
///
/// ```swift
/// let client = SiloClient(options: .init(
///     baseUrl: "https://api.silo.geekapps.io",
///     token: "YOUR_TOKEN",
///     defaultBucket: "my-bucket"
/// ))
///
/// let result = try await client.upload(
///     data: fileData,
///     fileName: "video.mp4",
///     mimeType: "video/mp4"
/// )
/// print(result.id)
/// ```
public actor SiloClient {

    // MARK: - State

    private var options: SiloClientOptions
    private let session: URLSession

    // MARK: - Init

    /// Create a new SiloClient with the given options.
    public init(options: SiloClientOptions, session: URLSession = .shared) {
        self.options = options
        self.session = session
    }

    // MARK: - Auth

    /// Set or update the bearer token used for API authentication.
    public func setToken(_ token: String) {
        options.token = token
    }

    // MARK: - Files

    /// Fetch metadata for a private file (requires token).
    public func getFileMeta(fileId: String) async throws -> SiloFile {
        try await request("/files/\(fileId)")
    }

    /// Fetch metadata for a public file. Pass `query` to forward a viewer query string.
    public func getPublicFileMeta(fileId: String, query: String? = nil) async throws -> SiloFile {
        var path = "/public/files/\(fileId)"
        if let query { path += "?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)" }
        return try await request(path)
    }

    /// Update mutable fields on a file. Pass `nil` to leave a field unchanged; pass `Optional<String>.none`
    /// wrapped in `Optional` to explicitly clear `title` or `description`.
    public func updateFile(
        fileId: String,
        isPrivate: Bool? = nil,
        title: String?? = nil,
        description: String?? = nil,
        tags: [String]? = nil
    ) async throws {
        var body: [String: Any] = [:]
        if let isPrivate { body["isPrivate"] = isPrivate }
        if let title = title { body["title"] = title as Any }
        if let description = description { body["description"] = description as Any }
        if let tags { body["tags"] = tags }
        let data = try JSONSerialization.data(withJSONObject: body)
        let _: EmptyResponse = try await request("/files/\(fileId)", method: "PATCH", body: data, contentType: "application/json")
    }

    /// Permanently delete a file.
    public func deleteFile(fileId: String) async throws {
        let _: EmptyResponse = try await request("/files/\(fileId)", method: "DELETE")
    }

    /// Obtain a time-limited signed URL for a private file.
    ///
    /// - Parameters:
    ///   - fileId: File identifier.
    ///   - ttl: Time-to-live in seconds (server default applies when `nil`).
    ///   - disposition: HTTP content disposition hint ("inline" or "attachment").
    public func getSignedUrl(
        fileId: String,
        ttl: Int? = nil,
        disposition: String? = nil
    ) async throws -> SignedUrlResult {
        var params: [String] = []
        if let ttl { params.append("ttl=\(ttl)") }
        if let disposition { params.append("disposition=\(disposition)") }
        let query = params.isEmpty ? "" : "?" + params.joined(separator: "&")
        return try await request("/files/\(fileId)/signed-url\(query)")
    }

    /// Returns the signed URL string for a file.
    public func getFileUrl(fileId: String, ttl: Int? = nil) async throws -> String {
        let result = try await getSignedUrl(fileId: fileId, ttl: ttl)
        return result.url
    }

    /// Builds the HLS stream URL for a video file (no network request).
    ///
    /// The token is appended as a query parameter so the player can authenticate.
    public func getHlsStreamUrl(fileId: String) -> String {
        var url = "\(options.baseUrl)/files/\(fileId)/hls/master.m3u8"
        if let token = options.token {
            url += "?token=\(token)"
        }
        return url
    }

    /// Returns the URL of the first generated thumbnail.
    public func getThumbnailUrl(fileId: String) async throws -> String {
        let file: SiloFile = try await request("/files/\(fileId)/thumbnail")
        return file.thumbnailUrl ?? file.url ?? ""
    }

    /// Returns the URL of the storyboard preview sprite.
    public func getStoryboardUrl(fileId: String) async throws -> String {
        let file: SiloFile = try await request("/files/\(fileId)/storyboard")
        return file.storyboardUrl ?? file.url ?? ""
    }

    /// Builds the captions manifest URL (no network request).
    public func getCaptionsUrl(fileId: String) -> String {
        var url = "\(options.baseUrl)/files/\(fileId)/captions"
        if let token = options.token {
            url += "?token=\(token)"
        }
        return url
    }

    /// Builds the chapters URL (no network request).
    public func getChaptersUrl(fileId: String) -> String {
        "\(options.baseUrl)/files/\(fileId)/chapters"
    }

    /// Builds the viewer app URL for a file (no network request).
    ///
    /// Requires ``SiloClientOptions/appUrl`` to be set.
    public func getViewUrl(fileId: String) -> String {
        let base = options.appUrl ?? options.baseUrl
        return "\(base)/view/\(fileId)"
    }

    // MARK: - Simple Upload (wraps multipart)

    /// Upload arbitrary data to Silo with optional progress reporting.
    ///
    /// For large files this automatically performs a multipart (chunked) upload.
    /// Small files (≤ ``defaultChunkSize``) are uploaded in a single request.
    ///
    /// - Parameters:
    ///   - data: File bytes to upload.
    ///   - fileName: Original file name (used as a hint for processing).
    ///   - mimeType: MIME type (e.g. `"video/mp4"`, `"image/jpeg"`).
    ///   - bucket: Target bucket slug. Falls back to ``SiloClientOptions/defaultBucket``.
    ///   - expiresIn: Optional TTL in seconds after which the file is deleted.
    ///   - onProgress: Optional closure called with overall upload progress in `[0, 1]`.
    /// - Returns: ``UploadResult`` with the file id and access URL.
    public func upload(
        data: Data,
        fileName: String,
        mimeType: String,
        bucket: String? = nil,
        expiresIn: Int? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> UploadResult {
        let targetBucket = bucket ?? options.defaultBucket
        let chunks = UploadManager.split(data: data, chunkSize: defaultChunkSize)

        let startOpts = MultipartStartOptions(
            fileName: fileName,
            mimeType: mimeType,
            size: data.count,
            bucket: targetBucket,
            expiresIn: expiresIn
        )
        let session = try await startMultipartUpload(opts: startOpts)
        let totalParts = chunks.count
        var parts: [MultipartPart] = []

        for (index, chunk) in chunks.enumerated() {
            let partNumber = index + 1
            let partUrl = try await getUploadPartUrl(
                fileId: session.fileId,
                uploadId: session.uploadId,
                partNumber: partNumber
            )
            guard let url = URL(string: partUrl.url) else {
                throw SiloError.invalidURL(partUrl.url)
            }

            // Report per-part progress scaled across [0, 1].
            let partOnProgress: (@Sendable (Double) -> Void)? = onProgress.map { callback in
                { partFraction in
                    let overall = (Double(index) + partFraction) / Double(totalParts)
                    callback(overall)
                }
            }

            let etag = try await UploadManager.uploadPart(
                url: url,
                data: chunk,
                mimeType: mimeType,
                onProgress: partOnProgress
            )
            parts.append(MultipartPart(partNumber: partNumber, eTag: etag))
        }

        onProgress?(1.0)
        return try await completeMultipartUpload(
            fileId: session.fileId,
            uploadId: session.uploadId,
            parts: parts
        )
    }

    // MARK: - Multipart Upload

    /// Start a multipart upload session and receive the upload session identifiers.
    public func startMultipartUpload(opts: MultipartStartOptions) async throws -> MultipartStartResult {
        let body = try jsonEncoder().encode(opts)
        return try await request("/upload/multipart/start", method: "POST", body: body, contentType: "application/json")
    }

    /// Retrieve a presigned URL for uploading a specific part number.
    public func getUploadPartUrl(
        fileId: String,
        uploadId: String,
        partNumber: Int
    ) async throws -> MultipartPartUrl {
        try await request(
            "/upload/multipart/\(fileId)/part-url?uploadId=\(uploadId)&partNumber=\(partNumber)"
        )
    }

    /// Notify the server that all parts have been uploaded and finalise the file.
    public func completeMultipartUpload(
        fileId: String,
        uploadId: String,
        parts: [MultipartPart],
        image: ImageUploadOptions? = nil,
        video: VideoUploadOptions? = nil
    ) async throws -> UploadResult {
        var payload: [String: Any] = [
            "uploadId": uploadId,
            "parts": parts.map { ["PartNumber": $0.partNumber, "ETag": $0.eTag] }
        ]
        if let image { payload["image"] = try jsonObject(from: image) }
        if let video { payload["video"] = try jsonObject(from: video) }
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try await request(
            "/upload/multipart/\(fileId)/complete",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
    }

    /// Abort an in-progress multipart upload and free reserved resources.
    public func abortMultipartUpload(fileId: String, uploadId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["uploadId": uploadId])
        let _: EmptyResponse = try await request(
            "/upload/multipart/\(fileId)/abort",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
    }

    // MARK: - Batch Upload

    /// Start a batch upload session covering multiple files.
    public func startBatch(opts: BatchStartOptions) async throws -> BatchStartResult {
        let body = try jsonEncoder().encode(opts)
        return try await request("/upload/batch/start", method: "POST", body: body, contentType: "application/json")
    }

    /// Poll the status of an ongoing batch upload.
    public func getBatchStatus(batchId: String) async throws -> BatchStatus {
        try await request("/upload/batch/\(batchId)/status")
    }

    /// Cancel a pending or in-progress batch upload.
    public func cancelBatch(batchId: String) async throws {
        let _: EmptyResponse = try await request("/upload/batch/\(batchId)/cancel", method: "POST")
    }

    // MARK: - Buckets

    /// List all buckets accessible with the current token.
    public func listBuckets() async throws -> ListBucketsResult {
        try await request("/buckets")
    }

    /// Create a new bucket.
    public func createBucket(
        name: String,
        slug: String? = nil,
        visibility: String? = nil
    ) async throws -> SiloBucket {
        var payload: [String: Any] = ["name": name]
        if let slug { payload["slug"] = slug }
        if let visibility { payload["visibility"] = visibility }
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try await request("/buckets", method: "POST", body: body, contentType: "application/json")
    }

    /// Delete a bucket by its slug.
    public func deleteBucket(bucket: String) async throws {
        let _: EmptyResponse = try await request("/buckets/\(bucket)", method: "DELETE")
    }

    /// List files, optionally filtered by bucket with cursor-based pagination.
    public func listFiles(
        bucket: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> ListFilesResult {
        var params: [String] = []
        if let bucket { params.append("bucket=\(bucket)") }
        if let cursor { params.append("cursor=\(cursor)") }
        if let limit { params.append("limit=\(limit)") }
        let query = params.isEmpty ? "" : "?" + params.joined(separator: "&")
        return try await request("/files\(query)")
    }

    // MARK: - Ratings

    /// Record or update a reaction (e.g. "LOVE", "LIKE", "DISLIKE") from a user.
    public func setRating(fileId: String, userId: String, reaction: String) async throws {
        let payload: [String: Any] = ["userId": userId, "reaction": reaction]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let _: EmptyResponse = try await request(
            "/files/\(fileId)/ratings",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
    }

    /// Remove a user's reaction from a file.
    public func removeRating(fileId: String, userId: String) async throws {
        let _: EmptyResponse = try await request(
            "/files/\(fileId)/ratings/\(userId)",
            method: "DELETE"
        )
    }

    /// Retrieve aggregated reaction counts for a file.
    public func getAggregateRating(fileId: String) async throws -> AggregateRating {
        try await request("/files/\(fileId)/ratings/aggregate")
    }

    // MARK: - Captions

    /// Upload a VTT caption file for a specific language.
    ///
    /// - Parameters:
    ///   - fileId: The video file to attach captions to.
    ///   - language: BCP-47 language code (e.g. "en", "pt-BR").
    ///   - label: Human-readable label shown in player UI.
    ///   - vtt: Raw WebVTT string content.
    public func uploadCaption(
        fileId: String,
        language: String,
        label: String? = nil,
        vtt: String
    ) async throws {
        var payload: [String: Any] = ["language": language, "vtt": vtt]
        if let label { payload["label"] = label }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let _: EmptyResponse = try await request(
            "/files/\(fileId)/captions",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
    }

    /// Delete a caption track by its identifier.
    public func deleteCaption(fileId: String, captionId: String) async throws {
        let _: EmptyResponse = try await request(
            "/files/\(fileId)/captions/\(captionId)",
            method: "DELETE"
        )
    }

    // MARK: - Age Ratings

    /// Retrieve available age rating classifications, optionally filtered by region.
    public func listAgeRatings(region: String? = nil) async throws -> [SiloAgeRating] {
        var path = "/age-ratings"
        if let region { path += "?region=\(region)" }
        return try await request(path)
    }

    // MARK: - Dashboard

    /// Fetch dashboard data including quota, recent files, and bucket summaries.
    public func getDashboardData() async throws -> DashboardData {
        try await request("/dashboard")
    }

    // MARK: - Internal Request Helper

    /// Perform an authenticated HTTP request and decode the JSON response.
    ///
    /// - Parameters:
    ///   - path: API path starting with `/` (appended to ``SiloClientOptions/baseUrl``).
    ///   - method: HTTP method (default `"GET"`).
    ///   - body: Optional request body data.
    ///   - contentType: Value for the `Content-Type` header when sending a body.
    /// - Returns: Decoded `T`.
    /// - Throws: ``SiloError`` on HTTP or decoding failures.
    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> T {
        let urlString = options.baseUrl + path
        guard let url = URL(string: urlString) else {
            throw SiloError.invalidURL(urlString)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method

        if let token = options.token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = body

        let (data, response) = try await session.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw SiloError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SiloError.httpError(statusCode: http.statusCode, body: body)
        }

        // Handle empty-body responses (e.g. 204 No Content) for EmptyResponse.
        if T.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! T
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Encoding Helpers

    private func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    /// Encode an `Encodable` value to a JSON-compatible `Any` dictionary.
    private func jsonObject<E: Encodable>(from value: E) throws -> Any {
        let data = try jsonEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}

// MARK: - EmptyResponse

/// Placeholder type used for API calls that return no meaningful body (e.g. 204 No Content).
private struct EmptyResponse: Decodable {}
