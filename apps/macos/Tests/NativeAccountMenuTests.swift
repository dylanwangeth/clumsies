import AppKit
import XCTest
@testable import Clumsies

@MainActor
final class NativeAccountMenuTests: XCTestCase {
    func testDiagnosticsIsANativeSubmenuOfTheAccountMenu() {
        var openedDestination: DiagnosticsDestination?
        var didShowLogs = false
        let coordinator = NativeAccountMenu.Coordinator(
            configuration: .init(
                account: nil,
                displayName: "Dylan",
                onOpenSettings: {},
                onOpenDiagnostics: { openedDestination = $0 },
                onShowLogs: { didShowLogs = true },
                onRefresh: {},
                onSignOut: {}
            )
        )

        let menu = coordinator.makeMenu()
        let diagnostics = menu.item(withTitle: "Diagnostics")
        let submenu = diagnostics?.submenu

        XCTAssertNotNil(submenu)
        XCTAssertTrue(submenu?.supermenu === menu)
        XCTAssertEqual(
            submenu?.items.map(\.title),
            ["Runtime Status", "Retrieval Runs", "", "Show Logs in Finder"]
        )

        submenu?.performActionForItem(at: 0)
        XCTAssertEqual(openedDestination?.rawValue, DiagnosticsDestination.runtime.rawValue)

        submenu?.performActionForItem(at: 3)
        XCTAssertTrue(didShowLogs)
    }
}
