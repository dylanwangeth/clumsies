import AppKit
import XCTest
@testable import Clumsies

final class FileTreeSelectionTests: XCTestCase {
    func testPlainDirectoryClickSelectsAndTogglesDirectory() {
        let result = FileTreeSelectionInteraction.directoryClick(
            nodeId: "directory:design",
            visibleNodeIds: ["directory:design", "a", "b"],
            currentSelection: ["a"],
            anchorId: "a",
            modifierFlags: []
        )

        XCTAssertEqual(result.selection, ["directory:design"])
        XCTAssertEqual(result.anchorId, "directory:design")
        XCTAssertTrue(result.togglesDirectory)
    }

    func testShiftClickDirectorySelectsRangeWithoutTogglingDirectory() {
        let result = FileTreeSelectionInteraction.directoryClick(
            nodeId: "directory:other",
            visibleNodeIds: ["a", "b", "directory:other", "c"],
            currentSelection: ["a"],
            anchorId: "a",
            modifierFlags: .shift
        )

        XCTAssertEqual(result.selection, ["a", "b", "directory:other"])
        XCTAssertEqual(result.anchorId, "a")
        XCTAssertFalse(result.togglesDirectory)
    }

    func testCommandClickDirectoryTogglesSelectionWithoutTogglingDirectory() {
        let result = FileTreeSelectionInteraction.directoryClick(
            nodeId: "directory:design",
            visibleNodeIds: ["directory:design", "a"],
            currentSelection: ["a"],
            anchorId: "a",
            modifierFlags: .command
        )

        XCTAssertEqual(result.selection, ["a", "directory:design"])
        XCTAssertEqual(result.anchorId, "directory:design")
        XCTAssertFalse(result.togglesDirectory)
    }

    func testDirectorySelectionExpandsToEveryDescendantWithoutDuplicates() {
        let items = [
            memoryItem(id: "a", path: "design/a.md"),
            memoryItem(id: "b", path: "design/nested/b.md"),
            memoryItem(id: "c", path: "other/c.md"),
        ]
        let roots = FileTreeNode.build(items)

        let selected = FileTreeNode.items(
            in: roots,
            selectedNodeIds: ["directory:design", "a"]
        )

        XCTAssertEqual(selected.map(\.id), ["a", "b"])
    }

    func testFileSelectionDoesNotIncludeSiblingFiles() {
        let items = [
            memoryItem(id: "a", path: "design/a.md"),
            memoryItem(id: "b", path: "design/b.md"),
        ]
        let roots = FileTreeNode.build(items)

        let selected = FileTreeNode.items(
            in: roots,
            selectedNodeIds: ["b"]
        )

        XCTAssertEqual(selected.map(\.id), ["b"])
    }

    func testCurrentDraftDoesNotShowSharedUpdateAccessory() {
        XCTAssertNil(
            SharedUpdateStatusPresentation.resolve(
                freshness: .current,
                hasUpstreamResourceChanges: false,
                reconciliation: .unknown
            )
        )
    }

    func testBehindDraftShowsSharedUpdateAccessory() throws {
        let presentation = try XCTUnwrap(
            SharedUpdateStatusPresentation.resolve(
                freshness: .behind,
                hasUpstreamResourceChanges: true,
                reconciliation: .clean
            )
        )

        XCTAssertEqual(
            presentation.symbolName,
            "arrow.trianglehead.2.clockwise.rotate.90"
        )
        XCTAssertEqual(presentation.help, "The shared version of this file has changed")
    }

    func testBehindDraftWithoutResourceChangesDoesNotShowFileAccessory() {
        XCTAssertNil(
            SharedUpdateStatusPresentation.resolve(
                freshness: .behind,
                hasUpstreamResourceChanges: false,
                reconciliation: .clean
            )
        )
    }

    func testConflictedBehindDraftShowsConflictAccessory() throws {
        let presentation = try XCTUnwrap(
            SharedUpdateStatusPresentation.resolve(
                freshness: .behind,
                hasUpstreamResourceChanges: true,
                reconciliation: .conflicts
            )
        )

        XCTAssertEqual(presentation.symbolName, "exclamationmark.triangle")
        XCTAssertEqual(presentation.help, "Shared update has conflicts")
    }

    private func memoryItem(id: String, path: String) -> MemoryListItem {
        .init(
            id: id,
            resource: .init(
                id: id,
                scope: .org,
                projectId: nil,
                projectName: nil,
                kind: .context,
                contentHash: "sha256:\(id)",
                updatedAt: "2026-07-31T00:00:00Z",
                refCommitId: "commit",
                contentLoaded: true,
                document: .init(
                    title: URL(fileURLWithPath: path).lastPathComponent,
                    path: path,
                    body: ""
                )
            ),
            draft: nil,
            inherited: false
        )
    }
}
