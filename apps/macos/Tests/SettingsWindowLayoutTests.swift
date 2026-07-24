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

        SettingsWindowLayout.normalize(window)

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

        SettingsWindowLayout.normalize(window)

        XCTAssertEqual(window.contentLayoutRect.size, selectedSize)
        XCTAssertEqual(window.contentMinSize, SettingsWindowLayout.minimumContentSize)
    }
}
