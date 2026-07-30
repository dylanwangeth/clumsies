import AppKit
import SwiftUI
import XCTest
@testable import Clumsies

@MainActor
final class DiagnosticsWindowLayoutTests: XCTestCase {
    func testConfigureExtendsSidebarMaterialIntoWindowChrome() {
        let window = makeWindow(size: DiagnosticsDestination.retrieval.defaultContentSize)

        DiagnosticsWindowLayout.configure(window, destination: .retrieval)

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(window.title, DiagnosticsDestination.retrieval.title)
        XCTAssertEqual(
            window.contentMinSize,
            DiagnosticsDestination.retrieval.minimumContentSize
        )
    }

    func testNormalizeRepairsCollapsedDiagnosticsWindow() {
        let window = makeWindow(size: NSSize(width: 320, height: 240))

        DiagnosticsWindowLayout.normalize(window, destination: .retrieval)

        XCTAssertEqual(
            window.contentView?.frame.size,
            DiagnosticsDestination.retrieval.defaultContentSize
        )
    }

    func testRetrievalMinimumWidthFitsRunListAndCandidateTrace() {
        let requiredWidth =
            RetrievalDiagnosticsLayout.runListMinimumWidth
            + RetrievalDiagnosticsLayout.mainPaneMinimumWidth

        XCTAssertGreaterThanOrEqual(
            DiagnosticsDestination.retrieval.minimumContentSize.width,
            requiredWidth
        )
    }

    func testRetrievalDefaultWidthCanUseIdealRunListWidth() {
        let requiredWidth =
            RetrievalDiagnosticsLayout.runListIdealWidth
            + RetrievalDiagnosticsLayout.mainPaneMinimumWidth

        XCTAssertGreaterThanOrEqual(
            DiagnosticsDestination.retrieval.defaultContentSize.width,
            requiredWidth
        )
    }

    func testReadableRunListWidthIsAHardMinimum() {
        XCTAssertEqual(
            RetrievalDiagnosticsLayout.runListMinimumWidth,
            RetrievalDiagnosticsLayout.runListIdealWidth
        )
        XCTAssertGreaterThanOrEqual(RetrievalDiagnosticsLayout.runListMinimumWidth, 360)
    }

    func testEvidenceReviewExposesOnlyOneContextualPrimaryAction() {
        XCTAssertEqual(
            RetrievalEvidenceReviewAction(
                hasSelection: false,
                canRecordNoMatch: true
            ),
            .noMatch
        )
        XCTAssertEqual(
            RetrievalEvidenceReviewAction(
                hasSelection: false,
                canRecordNoMatch: true
            ).title,
            "No Match"
        )
        XCTAssertEqual(
            RetrievalEvidenceReviewAction(
                hasSelection: true,
                canRecordNoMatch: true
            ),
            .confirm
        )
        XCTAssertEqual(
            RetrievalEvidenceReviewAction(
                hasSelection: true,
                canRecordNoMatch: false
            ).title,
            "Confirm"
        )
        XCTAssertEqual(
            RetrievalEvidenceReviewAction(
                hasSelection: false,
                canRecordNoMatch: false
            ),
            .done
        )
    }

    private func makeWindow(size: NSSize) -> NSWindow {
        NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }
}
