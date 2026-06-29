import Foundation

/// Manages individual multipart part uploads with progress reporting.
///
/// Use ``uploadPart(url:data:mimeType:onProgress:)`` to upload a single chunk to a
/// presigned S3 URL and retrieve the ETag required for completing the multipart upload.
public actor UploadManager {

    // MARK: - Public API

    /// Upload a single part to the given presigned S3 URL.
    ///
    /// - Parameters:
    ///   - url: Presigned S3 PUT URL obtained from ``SiloClient/getUploadPartUrl(fileId:uploadId:partNumber:)``.
    ///   - data: Raw bytes for this part (minimum 5 MB except for the last part).
    ///   - mimeType: MIME type of the file being uploaded (forwarded as `Content-Type`).
    ///   - onProgress: Optional closure called with upload progress as a fraction in `[0, 1]`.
    /// - Returns: The ETag value from the S3 response header.
    /// - Throws: ``SiloError/uploadFailed(_:)`` if the ETag header is missing,
    ///           or ``SiloError/httpError(statusCode:body:)`` for non-2xx responses.
    public static func uploadPart(
        url: URL,
        data: Data,
        mimeType: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")

        if let onProgress {
            return try await withCheckedThrowingContinuation { continuation in
                let delegate = UploadProgressDelegate(
                    totalBytes: Int64(data.count),
                    onProgress: onProgress,
                    completion: { result in
                        continuation.resume(with: result)
                    }
                )
                let session = URLSession(
                    configuration: .default,
                    delegate: delegate,
                    delegateQueue: nil
                )
                let task = session.uploadTask(with: request, from: data)
                task.resume()
            }
        } else {
            let (_, response) = try await URLSession.shared.upload(for: request, from: data)
            return try extractETag(from: response)
        }
    }

    // MARK: - Helpers

    /// Splits ``data`` into chunks of at most ``chunkSize`` bytes.
    ///
    /// Useful when manually orchestrating a multipart upload — pass each chunk to
    /// ``uploadPart(url:data:mimeType:onProgress:)`` in order.
    ///
    /// - Parameters:
    ///   - data: The full file data to split.
    ///   - chunkSize: Maximum size of each chunk in bytes (default: 8 MB).
    /// - Returns: An array of `Data` chunks.
    public static func split(data: Data, chunkSize: Int = 8 * 1024 * 1024) -> [Data] {
        var chunks: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            chunks.append(data[offset..<end])
            offset = end
        }
        return chunks
    }

    // MARK: - Private

    private static func extractETag(from response: URLResponse) throws -> String {
        guard let http = response as? HTTPURLResponse else {
            throw SiloError.invalidResponse
        }
        if !(200..<300).contains(http.statusCode) {
            throw SiloError.httpError(statusCode: http.statusCode, body: "Part upload failed")
        }
        // ETag may be returned with or without quotes — normalise it.
        let raw = http.value(forHTTPHeaderField: "ETag")
            ?? http.value(forHTTPHeaderField: "etag")
            ?? ""
        if raw.isEmpty {
            throw SiloError.uploadFailed("Missing ETag in S3 part response")
        }
        return raw
    }
}

// MARK: - URLSessionTaskDelegate for progress

private final class UploadProgressDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let totalBytes: Int64
    private let onProgress: @Sendable (Double) -> Void
    private let completion: (Result<String, Error>) -> Void
    private var responseData = Data()
    private var httpResponse: HTTPURLResponse?

    init(
        totalBytes: Int64,
        onProgress: @escaping @Sendable (Double) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        self.totalBytes = totalBytes
        self.onProgress = onProgress
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let expected = totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : totalBytes
        let progress = expected > 0 ? Double(totalBytesSent) / Double(expected) : 0
        onProgress(min(progress, 1.0))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        httpResponse = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completion(.failure(error))
            return
        }
        guard let http = httpResponse else {
            completion(.failure(SiloError.invalidResponse))
            return
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            completion(.failure(SiloError.httpError(statusCode: http.statusCode, body: body)))
            return
        }
        let raw = http.value(forHTTPHeaderField: "ETag")
            ?? http.value(forHTTPHeaderField: "etag")
            ?? ""
        if raw.isEmpty {
            completion(.failure(SiloError.uploadFailed("Missing ETag in S3 part response")))
        } else {
            completion(.success(raw))
        }
    }
}
