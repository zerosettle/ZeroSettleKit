//
//  HTTPClient.swift
//  ZeroSettleCore
//
//  Clean async/await HTTP client with structured error handling.
//

import Foundation

public enum HTTPError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(statusCode: Int, body: Data?)
    case decodingFailed(Error)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .invalidResponse:
            return "Invalid HTTP response"
        case .httpError(let statusCode, _):
            return "HTTP error: \(statusCode)"
        case .decodingFailed(let error):
            return "Decoding failed: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

public final class HTTPClient: @unchecked Sendable {
    public static let shared = HTTPClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder()
    ) {
        self.session = session
        self.decoder = decoder
        self.encoder = encoder
    }

    // MARK: - GET

    public func get<T: Decodable>(
        _ url: URL,
        headers: [String: String] = [:],
        responseType: T.Type
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        return try await execute(request, responseType: responseType)
    }

    // MARK: - POST

    public func post<Request: Encodable, Response: Decodable>(
        _ url: URL,
        body: Request,
        headers: [String: String] = [:],
        responseType: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try encoder.encode(body)

        return try await execute(request, responseType: responseType)
    }

    public func post<Response: Decodable>(
        _ url: URL,
        headers: [String: String] = [:],
        responseType: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        return try await execute(request, responseType: responseType)
    }

    // MARK: - Raw Request

    public func execute<T: Decodable>(
        _ request: URLRequest,
        responseType: T.Type
    ) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HTTPError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            logAPIError(statusCode: httpResponse.statusCode, url: request.url, data: data)
            throw HTTPError.httpError(statusCode: httpResponse.statusCode, body: data)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Logger.error("Decoding failed: \(error)", category: .network)
            throw HTTPError.decodingFailed(error)
        }
    }

    // MARK: - Error Logging

    /// Parse and log API error responses with debug info for developers.
    private func logAPIError(statusCode: Int, url: URL?, data: Data) {
        let urlString = url?.absoluteString ?? "unknown"

        // Try to parse JSON error response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Logger.error("[ZeroSettle] HTTP \(statusCode) from \(urlString)", category: .network)
            return
        }

        let errorMessage = json["error"] as? String ?? "Unknown error"
        let errorCode = json["code"] as? String ?? "unknown"

        // Log the main error
        Logger.error(
            "[ZeroSettle] API Error: \(errorMessage) (code: \(errorCode), status: \(statusCode))",
            category: .network
        )

        // Log debug info if present - this helps developers troubleshoot
        if let debug = json["debug"] as? [String: Any] {
            Logger.error("[ZeroSettle] Debug Info:", category: .network)

            if let reason = debug["reason"] as? String {
                Logger.error("  → Reason: \(reason)", category: .network)
            }
            if let action = debug["action"] as? String {
                Logger.error("  → Action: \(action)", category: .network)
            }
            if let docs = debug["docs"] as? String {
                Logger.error("  → Docs: \(docs)", category: .network)
            }
            if let stripeError = debug["stripe_error"] as? String {
                Logger.error("  → Stripe Error: \(stripeError)", category: .network)
            }
            if let stripeCode = debug["stripe_error_code"] as? String {
                Logger.error("  → Stripe Code: \(stripeCode)", category: .network)
            }
            if let capabilities = debug["capabilities"] as? [String: Any] {
                let capsStr = capabilities.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                Logger.error("  → Capabilities: \(capsStr)", category: .network)
            }
        }
    }

    /// Execute request expecting empty response (204 No Content, etc.)
    public func executeVoid(_ request: URLRequest) async throws {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HTTPError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            logAPIError(statusCode: httpResponse.statusCode, url: request.url, data: data)
            throw HTTPError.httpError(statusCode: httpResponse.statusCode, body: data)
        }
    }
}
