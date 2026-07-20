import CryptoKit
import Darwin
import Foundation

struct DaemonBootstrapState: Equatable, Sendable {
    let installed: Bool
    let running: Bool
    let pid: Int?
    let error: String?
}

enum DaemonBootstrapError: LocalizedError, Sendable {
    case daemonBinaryMissing
    case launchctl(String)

    var errorDescription: String? {
        switch self {
        case .daemonBinaryMissing:
            return "The Clumsies daemon is missing from the application bundle."
        case .launchctl(let message):
            return message
        }
    }
}

struct DaemonBootstrapController: Sendable {
    static let label = ClumsiesIdentifiers.daemon

    private var fileManager: FileManager { .default }

    func ensureRunning() async throws -> DaemonBootstrapState {
        try await Task.detached(priority: .userInitiated) {
            try ensureRunningSynchronously()
        }.value
    }

    func status() async -> DaemonBootstrapState {
        await Task.detached {
            readStatus()
        }.value
    }

    private func ensureRunningSynchronously() throws -> DaemonBootstrapState {
        let daemonURL = try daemonBinaryURL()
        let plistURL = try launchAgentPlistURL()
        let expected = try plistContents(daemonURL: daemonURL)
        let current = try? String(contentsOf: plistURL, encoding: .utf8)

        if current != expected {
            _ = try? runLaunchctl(["bootout", serviceTarget], allowFailure: true)
            try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            try expected.write(to: plistURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
        }

        let currentStatus = readStatus()
        if !currentStatus.running {
            if currentStatus.installed && currentStatus.error == nil {
                _ = try runLaunchctl(["kickstart", "-k", serviceTarget])
            } else {
                let result = try runLaunchctl(["bootstrap", launchDomain, plistURL.path], allowFailure: true)
                if result.status != 0 && !result.output.localizedCaseInsensitiveContains("already bootstrapped") {
                    throw DaemonBootstrapError.launchctl(result.output)
                }
                _ = try runLaunchctl(["kickstart", "-k", serviceTarget])
            }
        }
        return readStatus()
    }

    private var homeDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
    }

    private var runtimeRoot: URL {
        homeDirectory.appending(path: "Library/Application Support/\(ClumsiesIdentifiers.namespace)", directoryHint: .isDirectory)
    }

    private var cacheDirectory: URL {
        homeDirectory.appending(path: "Library/Caches/\(ClumsiesIdentifiers.namespace)", directoryHint: .isDirectory)
    }

    private var logDirectory: URL {
        homeDirectory.appending(path: "Library/Logs/\(ClumsiesIdentifiers.namespace)", directoryHint: .isDirectory)
    }

    private var launchDomain: String { "gui/\(getuid())" }
    private var serviceTarget: String { "\(launchDomain)/\(Self.label)" }

    private func daemonBinaryURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["CLUMSIES_DAEMON_PROGRAM"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard let url = Bundle.main.resourceURL?.appending(path: "clumsiesd"),
              fileManager.isExecutableFile(atPath: url.path) else {
            throw DaemonBootstrapError.daemonBinaryMissing
        }
        return url
    }

    private func launchAgentPlistURL() throws -> URL {
        homeDirectory
            .appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
            .appending(path: "\(Self.label).plist")
    }

    private func plistContents(daemonURL: URL) throws -> String {
        let daemonDigest = SHA256.hash(data: try Data(contentsOf: daemonURL))
            .map { String(format: "%02x", $0) }
            .joined()
        let values: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [daemonURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "MachServices": [Self.label: true],
            "EnvironmentVariables": [
                "CLUMSIES_DAEMON_ROOT": runtimeRoot.path,
                "CLUMSIES_DAEMON_CACHE_DIR": cacheDirectory.path,
                "CLUMSIES_DAEMON_LOG_DIR": logDirectory.path,
                "CLUMSIES_DAEMON_BINARY_SHA256": daemonDigest,
            ],
            "StandardOutPath": logDirectory.appending(path: "clumsiesd.out.log").path,
            "StandardErrorPath": logDirectory.appending(path: "clumsiesd.err.log").path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        guard let value = String(data: data, encoding: .utf8) else {
            throw DaemonBootstrapError.launchctl("Could not encode the daemon LaunchAgent property list.")
        }
        return value
    }

    private func readStatus() -> DaemonBootstrapState {
        let plist = try? launchAgentPlistURL()
        let installed = plist.map { fileManager.fileExists(atPath: $0.path) } ?? false
        let result = (try? runLaunchctl(["print", serviceTarget], allowFailure: true))
            ?? ProcessResult(status: -1, output: "Could not inspect the daemon LaunchAgent.")
        guard result.status == 0 else {
            return .init(installed: installed, running: false, pid: nil, error: result.output)
        }
        let pid = result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("pid =") }
            .flatMap { Int($0.dropFirst("pid =".count).trimmingCharacters(in: .whitespaces)) }
        let running = pid != nil || result.output.contains("state = running")
        return .init(installed: installed, running: running, pid: pid, error: nil)
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String], allowFailure: Bool = false) throws -> ProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let result = ProcessResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if result.status != 0 && !allowFailure {
            throw DaemonBootstrapError.launchctl(
                result.output.isEmpty ? "launchctl exited with status \(result.status)." : result.output
            )
        }
        return result
    }
}
