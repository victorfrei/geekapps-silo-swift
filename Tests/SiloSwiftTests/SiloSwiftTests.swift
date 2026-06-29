import XCTest
@testable import SiloSwift

final class SiloSwiftTests: XCTestCase {

    func testClientInit() async {
        let client = SiloClient(options: .init(
            baseUrl: "https://api.silo.geekapps.io",
            token: "test-token",
            defaultBucket: "my-bucket"
        ))
        // Verify URL construction helpers (no network required).
        let hlsUrl = await client.getHlsStreamUrl(fileId: "abc123")
        XCTAssertTrue(hlsUrl.contains("abc123"))
        XCTAssertTrue(hlsUrl.contains("token=test-token"))

        let viewUrl = await client.getViewUrl(fileId: "abc123")
        XCTAssertTrue(viewUrl.contains("abc123"))
    }

    func testChunkSplit() {
        let data = Data(repeating: 0xFF, count: 20 * 1024 * 1024) // 20 MB
        let chunks = UploadManager.split(data: data, chunkSize: 8 * 1024 * 1024)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].count, 8 * 1024 * 1024)
        XCTAssertEqual(chunks[1].count, 8 * 1024 * 1024)
        XCTAssertEqual(chunks[2].count, 4 * 1024 * 1024)
    }

    func testChunkSplitSingleChunk() {
        let data = Data(repeating: 0xAB, count: 1024)
        let chunks = UploadManager.split(data: data, chunkSize: 8 * 1024 * 1024)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 1024)
    }

    func testMultipartPartCodingKeys() throws {
        let part = MultipartPart(partNumber: 1, eTag: "\"abc123\"")
        let encoder = JSONEncoder()
        let data = try encoder.encode(part)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["PartNumber"] as? Int, 1)
        XCTAssertEqual(json?["ETag"] as? String, "\"abc123\"")
    }

    func testSiloErrorDescriptions() {
        let httpErr = SiloError.httpError(statusCode: 403, body: "Forbidden")
        XCTAssertTrue(httpErr.errorDescription?.contains("403") == true)

        let uploadErr = SiloError.uploadFailed("no ETag")
        XCTAssertTrue(uploadErr.errorDescription?.contains("no ETag") == true)

        XCTAssertNotNil(SiloError.invalidResponse.errorDescription)
        XCTAssertNotNil(SiloError.missingToken.errorDescription)
    }
}
