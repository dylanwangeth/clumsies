import Foundation

enum AppBundleRuntimeLocationError: LocalizedError, Sendable {
    case translocated

    var errorDescription: String? {
        switch self {
        case .translocated:
            "Clumsies is running from a temporary macOS App Translocation path. Quit the App, move Clumsies.app to /Applications or ~/Applications, then open it again. No daemon or Coding Agent integration was changed."
        }
    }
}

enum AppBundleRuntimeLocation {
    static var defaultLogDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(components: "Library", "Logs", "ai.clumsies")
    }

    static func requireStable(_ bundleURL: URL) throws {
        let components = bundleURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        if components.contains("AppTranslocation") {
            throw AppBundleRuntimeLocationError.translocated
        }
    }
}
