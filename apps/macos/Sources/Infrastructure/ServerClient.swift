import Foundation

enum ServerClientError: LocalizedError, Sendable {
    case invalidPath
    case forbidden(String)
    case response(status: Int, message: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "The Server request path is invalid."
        case .forbidden(let message):
            return message
        case .response(let status, let message):
            return "Server request failed (\(status)): \(message)"
        case .invalidResponse(let message):
            return "The Server returned invalid data: \(message)"
        }
    }
}

struct ServerClient: Sendable {
    let daemon: DaemonXPCClient
    private let dataSourceTracker = ServerDataSourceTracker()
    private let requestLimiter = ServerRequestLimiter(limit: 12)

    var dataSource: String { dataSourceTracker.value }

    func resetDataSource() {
        dataSourceTracker.reset()
    }

    func get<Response: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:]
    ) async throws -> Response {
        try await request(method: "GET", path: path, query: query, headers: headers, body: nil)
    }

    func getWithMetadata<Response: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:]
    ) async throws -> (value: Response, response: DaemonServerResponse) {
        let response = try await raw(method: "GET", path: path, query: query, headers: headers)
        let value: Response = try decode(response)
        return (value, response)
    }

    func send<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Body
    ) async throws -> Response {
        let data = try JSONCoding.encoder().encode(body)
        guard let bodyString = String(data: data, encoding: .utf8) else {
            throw ServerClientError.invalidResponse("Could not encode the request body.")
        }
        return try await request(
            method: method,
            path: path,
            query: query,
            headers: headers.merging(["content-type": "application/json"], uniquingKeysWith: { current, _ in current }),
            body: bodyString
        )
    }

    func raw(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: String? = nil
    ) async throws -> DaemonServerResponse {
        let requestPath = try buildPath(path, query: query)
        let response = try await requestLimiter.run {
            try await daemon.serverRequest(
                .init(method: method, path: requestPath, headers: headers, body: body)
            )
        }
        if response.headers.contains(where: {
            $0.key.caseInsensitiveCompare("x-clumsies-cache") == .orderedSame
                && $0.value.caseInsensitiveCompare("stale") == .orderedSame
        }) {
            dataSourceTracker.markStale()
        }
        return response
    }

    private func request<Response: Decodable & Sendable>(
        method: String,
        path: String,
        query: [URLQueryItem],
        headers: [String: String],
        body: String?
    ) async throws -> Response {
        let response = try await raw(method: method, path: path, query: query, headers: headers, body: body)
        return try decode(response)
    }

    private func decode<Response: Decodable & Sendable>(_ response: DaemonServerResponse) throws -> Response {
        guard (200..<300).contains(response.status) else {
            let message = Self.errorMessage(from: response.body)
            throw ServerClientError.response(status: response.status, message: message)
        }
        guard let data = response.body.data(using: .utf8) else {
            throw ServerClientError.invalidResponse("Response body is not UTF-8.")
        }
        do {
            return try JSONCoding.decoder().decode(Response.self, from: data)
        } catch {
            throw ServerClientError.invalidResponse(error.localizedDescription)
        }
    }

    private func buildPath(_ path: String, query: [URLQueryItem]) throws -> String {
        guard path.hasPrefix("/"), var components = URLComponents(string: path) else {
            throw ServerClientError.invalidPath
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let value = components.string else {
            throw ServerClientError.invalidPath
        }
        return value
    }

    private static func errorMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return body.isEmpty ? "No error details were returned." : body
        }
        return message
    }
}

private actor ServerRequestLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = max(1, limit)
    }

    func run<Output: Sendable>(
        _ operation: @Sendable () async throws -> Output
    ) async throws -> Output {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private final class ServerDataSourceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var stale = false

    var value: String {
        lock.withLock { stale ? "stale" : "live" }
    }

    func markStale() {
        lock.withLock { stale = true }
    }

    func reset() {
        lock.withLock { stale = false }
    }
}
