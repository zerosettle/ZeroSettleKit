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
            Logger.error(
                "HTTP \(httpResponse.statusCode) from \(request.url?.absoluteString ?? "unknown")",
                category: .network
            )
            throw HTTPError.httpError(statusCode: httpResponse.statusCode, body: data)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Logger.error("Decoding failed: \(error)", category: .network)
            throw HTTPError.decodingFailed(error)
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
            Logger.error(
                "HTTP \(httpResponse.statusCode) from \(request.url?.absoluteString ?? "unknown")",
                category: .network
            )
            throw HTTPError.httpError(statusCode: httpResponse.statusCode, body: data)
        }
    }
}
