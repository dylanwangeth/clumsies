import AppKit
import CryptoKit
import Darwin
import Foundation

enum AuthenticationError: LocalizedError, Sendable {
    case callbackServer(String)
    case invalidAuthorizationURL
    case browserLaunchFailed
    case callbackTimedOut
    case invalidCallback
    case stateMismatch
    case provider(String)
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .callbackServer(let message): message
        case .invalidAuthorizationURL: "Could not create the organization sign-in URL."
        case .browserLaunchFailed: "Could not open the system browser."
        case .callbackTimedOut: "Organization sign-in timed out."
        case .invalidCallback: "The organization sign-in callback is invalid."
        case .stateMismatch: "The organization sign-in state did not match."
        case .provider(let message): "Organization sign-in failed: \(message)"
        case .server(let status, let message): "Server authentication failed (\(status)): \(message)"
        }
    }
}

struct AuthenticationClient: Sendable {
    static let serverURL = URL(string: "https://app.clumsies.ai")!

    let daemon: DaemonXPCClient

    func signIn() async throws -> DaemonProjectConfig {
        let callback = try LoopbackCallbackServer.open()
        let redirectURI = "http://127.0.0.1:\(callback.port)/callback"
        let verifier = Self.randomSecret()
        let state = Self.randomSecret()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let authorizationURL = try Self.authorizationURL(
            redirectURI: redirectURI,
            challenge: challenge,
            state: state
        )

        let didOpen = await MainActor.run { NSWorkspace.shared.open(authorizationURL) }
        guard didOpen else {
            callback.close()
            throw AuthenticationError.browserLaunchFailed
        }

        let code = try await callback.waitForCode(expectedState: state)
        let tokens = try await exchangeCode(code, redirectURI: redirectURI, verifier: verifier)
        let currentUser = try await loadCurrentUser(accessToken: tokens.accessToken)
        return try await daemon.replaceProjectConfig(
            .init(
                serverUrl: Self.serverURL.absoluteString,
                projectId: currentUser.defaultProjectId ?? currentUser.projects.first?.projectId,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken
            )
        )
    }

    private func exchangeCode(_ code: String, redirectURI: String, verifier: String) async throws -> TokenResponse {
        var request = URLRequest(url: Self.serverURL.appending(path: "/api/v1/auth/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONCoding.encoder().encode(
            TokenExchangeRequest(code: code, redirectUri: redirectURI, codeVerifier: verifier)
        )
        return try await send(request)
    }

    private func loadCurrentUser(accessToken: String) async throws -> CurrentUserResponse {
        var request = URLRequest(url: Self.serverURL.appending(path: "/api/v1/me"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        return try await send(request)
    }

    private func send<Response: Decodable & Sendable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthenticationError.server(status: 0, message: "No HTTP response was returned.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(decoding: data, as: UTF8.self)
            throw AuthenticationError.server(status: http.statusCode, message: message)
        }
        return try JSONCoding.decoder().decode(Response.self, from: data)
    }

    private static func authorizationURL(
        redirectURI: String,
        challenge: String,
        state: String
    ) throws -> URL {
        var components = URLComponents(
            url: serverURL.appending(path: "/oauth2/authorization/oidc"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            .init(name: "client_kind", value: "desktop"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        guard let url = components?.url else {
            throw AuthenticationError.invalidAuthorizationURL
        }
        return url
    }

    private static func randomSecret() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct LoopbackCallbackServer: Sendable {
    let descriptor: Int32
    let port: UInt16

    static func open() throws -> Self {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AuthenticationError.callbackServer("Could not create the local callback socket.")
        }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                Darwin.bind(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw AuthenticationError.callbackServer("Could not bind the local callback socket.")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                getsockname(descriptor, addressPointer, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            throw AuthenticationError.callbackServer("Could not read the local callback port.")
        }
        return .init(descriptor: descriptor, port: UInt16(bigEndian: boundAddress.sin_port))
    }

    func close() {
        Darwin.close(descriptor)
    }

    func waitForCode(expectedState: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            defer { Darwin.close(descriptor) }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, 300_000) > 0 else {
                throw AuthenticationError.callbackTimedOut
            }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                throw AuthenticationError.invalidCallback
            }
            defer { Darwin.close(client) }

            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0,
                  let request = String(bytes: buffer.prefix(count), encoding: .utf8),
                  let requestLine = request.split(separator: "\r\n", maxSplits: 1).first else {
                Self.respond(to: client, success: false)
                throw AuthenticationError.invalidCallback
            }
            let components = requestLine.split(separator: " ")
            guard components.count >= 2,
                  components[0] == "GET",
                  let callback = URLComponents(string: "http://127.0.0.1\(components[1])"),
                  callback.path == "/callback" else {
                Self.respond(to: client, success: false)
                throw AuthenticationError.invalidCallback
            }
            let values = Dictionary(
                callback.queryItems?.compactMap { item in item.value.map { (item.name, $0) } } ?? [],
                uniquingKeysWith: { first, _ in first }
            )
            guard values["state"] == expectedState else {
                Self.respond(to: client, success: false)
                throw AuthenticationError.stateMismatch
            }
            if let providerError = values["error"] {
                Self.respond(to: client, success: false)
                throw AuthenticationError.provider(values["error_description"] ?? providerError)
            }
            guard let code = values["code"] else {
                Self.respond(to: client, success: false)
                throw AuthenticationError.invalidCallback
            }
            Self.respond(to: client, success: true)
            return code
        }.value
    }

    private static func respond(to descriptor: Int32, success: Bool) {
        let status = success ? "200 OK" : "400 Bad Request"
        let title = success ? "Signed in to Clumsies" : "Sign-in failed"
        let message = success
            ? "You can close this window and return to the Clumsies app."
            : "Return to the Clumsies app to review the error."
        let body = "<!doctype html><meta charset=\"utf-8\"><title>\(title)</title><h1>\(title)</h1><p>\(message)</p>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(body)"
        _ = response.withCString { pointer in
            Darwin.send(descriptor, pointer, strlen(pointer), 0)
        }
    }
}
