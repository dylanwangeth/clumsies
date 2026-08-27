import AppKit
import SwiftUI
import XCTest
@testable import Clumsies

@MainActor
final class SettingsWindowLayoutTests: XCTestCase {
    func testNormalizeRepairsHostingControllerCollapsedContentSize() {
        let controller = NSHostingController(rootView: Text("Settings"))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowLayout.defaultContentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = controller
        XCTAssertLessThan(
            window.contentLayoutRect.width,
            SettingsWindowLayout.minimumContentSize.width
        )

        SettingsWindowLayout.normalize(window, pane: .general)

        XCTAssertEqual(window.contentLayoutRect.size, SettingsWindowLayout.defaultContentSize)
        XCTAssertEqual(window.contentMinSize, SettingsWindowLayout.minimumContentSize)
    }

    func testNormalizePreservesAValidUserSelectedSize() {
        let selectedSize = NSSize(width: 760, height: 620)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: selectedSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        SettingsWindowLayout.normalize(window, pane: .advanced)

        XCTAssertEqual(window.contentLayoutRect.size, selectedSize)
        XCTAssertEqual(window.contentMinSize, SettingsWindowLayout.minimumContentSize)
        XCTAssertEqual(window.title, "Advanced")
        XCTAssertFalse(window.styleMask.contains(.miniaturizable))
        XCTAssertFalse(window.styleMask.contains(.resizable))
    }

    func testPaneRestorationDefaultsToGeneralAndRejectsUnknownValues() {
        let suite = "SettingsWindowLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(SettingsPane.restored(from: defaults), .general)
        SettingsPane.agent.persist(in: defaults)
        XCTAssertEqual(SettingsPane.restored(from: defaults), .agent)
        defaults.set("unknown", forKey: SettingsPane.defaultsKey)
        XCTAssertEqual(SettingsPane.restored(from: defaults), .general)
    }

    func testNativePreferenceToolbarSelectsAndPersistsPane() {
        let suite = "SettingsWindowLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SettingsTabViewController(
            items: SettingsPane.allCases.map { ($0, NSViewController()) },
            selectedPane: .agent,
            defaults: defaults
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowLayout.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = controller
        SettingsWindowLayout.configure(window, pane: controller.selectedPane)

        XCTAssertEqual(controller.tabStyle, .toolbar)
        XCTAssertEqual(window.toolbarStyle, .preference)
        XCTAssertEqual(window.toolbar?.allowsUserCustomization, false)
        XCTAssertEqual(window.title, "Agent")
        XCTAssertFalse(window.styleMask.contains(.miniaturizable))
        XCTAssertFalse(window.styleMask.contains(.resizable))

        controller.selectedTabViewItemIndex = 2
        XCTAssertEqual(controller.selectedPane, .advanced)
        XCTAssertEqual(window.title, "Advanced")
        XCTAssertEqual(SettingsPane.restored(from: defaults), .advanced)
    }
}
