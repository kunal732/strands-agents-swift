import Foundation

/// Session storage backed by AWS S3 using pre-signed URLs.
///
/// Uses URLSession for HTTP requests -- no AWS SDK dependency. Requires
/// pre-signed URLs or a signing function for authentication.
///
/// ```swift
/// let storage = S3SessionStorage(
///     bucket: "my-sessions",
///     prefix: "agents/",
///     signer: myS3Signer
/// )
/// ```
///
/// For use with the AWS SDK, implement `S3RequestSigner` to sign requests
/// using the SDK's credential chain.
public struct S3SessionStorage: SessionStorage {
    private let bucket: String
    private let prefix: String
    private let region: String
    private let signer: (any S3RequestSigner)?
    private let session: URLSession

    public init(
        bucket: String,
        prefix: String = "sessions/",
        region: String = "us-east-1",
        signer: (any S3RequestSigner)? = nil
    ) {
        self.bucket = bucket
        self.prefix = prefix
        self.region = region
        self.signer = signer
        self.session = URLSession(configuration: .default)
    }

    private func key(for sessionId: String) -> String {
        "\(prefix)\(sessionId).json"
    }

    private func url(for sessionId: String) -> URL {
        URL(string: "https://\(bucket).s3.\(region).amazonaws.com/\(key(for: sessionId))")!
    }

    public func save(sessionId: String, data: Data) async throws {
        var request = URLRequest(url: url(for: sessionId))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        if let signer {
            request = try await signer.sign(request)
        }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StrandsError.serializationFailed(
                underlying: NSError(domain: "S3SessionStorage", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "S3 PUT failed"])
            )
        }
    }

    public func load(sessionId: String) async throws -> Data? {
        var request = URLRequest(url: url(for: sessionId))
        request.httpMethod = "GET"

        if let signer {
            request = try await signer.sign(request)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }

        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    public func delete(sessionId: String) async throws {
        var request = URLRequest(url: url(for: sessionId))
        request.httpMethod = "DELETE"

        if let signer {
            request = try await signer.sign(request)
        }

        let (_, _) = try await session.data(for: request)
    }

    public func list() async throws -> [String] {
        // S3 list requires XML parsing; simplified version
        var request = URLRequest(url: URL(
            string: "https://\(bucket).s3.\(region).amazonaws.com/?prefix=\(prefix)&delimiter=/"
        )!)
        request.httpMethod = "GET"

        if let signer {
            request = try await signer.sign(request)
        }

        let (data, _) = try await session.data(for: request)
        // Parse XML for <Key> elements -- simplified
        let xml = String(data: data, encoding: .utf8) ?? ""
        let keys = xml.components(separatedBy: "<Key>")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "</Key>").first }
            .map { $0.replacingOccurrences(of: prefix, with: "").replacingOccurrences(of: ".json", with: "") }
        return keys
    }
}

/// Protocol for signing S3 requests with AWS credentials.
public protocol S3RequestSigner: Sendable {
    func sign(_ request: URLRequest) async throws -> URLRequest
}
