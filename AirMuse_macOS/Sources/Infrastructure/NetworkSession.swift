// Sources/Infrastructure/NetworkSession.swift
// AirMuse macOS – URLSession wrapper with timeout, retry, and cancellation

import Foundation

// MARK: - Errors

public enum NetworkError: Error, Sendable {
    case badStatusCode(Int)
    case decodingFailed(String)
    case timeout
    case cancelled
    case underlying(String)
}

// MARK: - NetworkSession Actor

public actor NetworkSession {

    public static let shared = NetworkSession()

    private let session: URLSession
    private let decoder: JSONDecoder

    public init(timeoutSeconds: Double = 30, maxRetries: Int = 3) {
        self.maxRetries = maxRetries
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds * 3
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
    }

    private let maxRetries: Int

    // MARK: - Public API

    /// Fetch raw data from a URL with automatic retry on transient errors.
    public func data(from url: URL) async throws -> Data {
        try await withRetry {
            let (data, response) = try await self.session.data(from: url)
            try Self.validate(response: response)
            return data
        }
    }

    /// Fetch and decode a Decodable type.
    public func fetch<T: Decodable & Sendable>(_ type: T.Type, from url: URL) async throws -> T {
        let data = try await self.data(from: url)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw NetworkError.decodingFailed(error.localizedDescription)
        }
    }

    /// POST JSON body, return decoded response.
    public func post<Body: Encodable, Response: Decodable & Sendable>(
        url: URL,
        body: Body,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in additionalHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONEncoder().encode(body)
        let finalRequest = request
        return try await withRetry {
            let (data, response) = try await self.session.data(for: finalRequest)
            try Self.validate(response: response)
            do {
                return try self.decoder.decode(Response.self, from: data)
            } catch {
                throw NetworkError.decodingFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private static func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw NetworkError.badStatusCode(http.statusCode)
        }
    }

    private func withRetry<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                return try await operation()
            } catch let error as URLError where isTransient(error) {
                lastError = error
                if attempt < maxRetries - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 500_000_000  // exponential backoff
                    try await Task.sleep(nanoseconds: delay)
                }
            } catch let error as NetworkError {
                // 5xx are retriable
                if case .badStatusCode(let code) = error, (500..<600).contains(code) {
                    lastError = error
                    if attempt < maxRetries - 1 {
                        let delay = UInt64(pow(2.0, Double(attempt))) * 500_000_000
                        try await Task.sleep(nanoseconds: delay)
                    }
                } else {
                    throw error
                }
            }
        }
        throw lastError ?? NetworkError.underlying("max retries exceeded")
    }

    private func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost:
            return true
        default:
            return false
        }
    }
}
