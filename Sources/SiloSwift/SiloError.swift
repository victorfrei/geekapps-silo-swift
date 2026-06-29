import Foundation

/// Errors thrown by the Silo SDK.
public enum SiloError: Error, LocalizedError {
    case httpError(statusCode: Int, body: String)
    case invalidResponse
    case uploadFailed(String)
    case missingToken
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            return "Silo API error \(code): \(body)"
        case .invalidResponse:
            return "Invalid response from Silo API"
        case .uploadFailed(let msg):
            return "Upload failed: \(msg)"
        case .missingToken:
            return "No authentication token provided. Call setToken(_:) first."
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        }
    }
}
