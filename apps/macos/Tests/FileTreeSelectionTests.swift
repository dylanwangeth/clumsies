import AppKit
import XCTest
@testable import Clumsies

final class FileTreeSelectionTests: XCTestCase {
    func testSharedPathTreeBuildsDirectoriesForReviewAndMemoryNavigators() throws {
        let roots = PathTreeNode.build([
            PathTreeItem(id: "review-file", path: "context/guides/review.md"),
            PathTreeItem(id: "memory-file", path: "context/notes.md"),
        ])

        let context = try XCTUnwrap(roots.first)
        XCTAssertEqual(context.id, "directory:context")
        XCTAssertEqual(context.name, "context")
        XCTAssertEqual(PathTreeNode.firstItemId(in: roots), "review-file")
        XCTAssertEqual(
            PathTreeNode.directoryIds(in: roots),
            ["directory:context", "directory:context/guides"]
        )
        XCTAssertNotNil(PathTreeNode.node(withId: "review-file", in: roots)?.item)
    }

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

    func testBehindDraftWithoutResourceChangesShowsBaseBehindAccessory() throws {
        let presentation = try XCTUnwrap(
            SharedUpdateStatusPresentation.resolve(
                freshness: .behind,
                hasUpstreamResourceChanges: false,
                reconciliation: .clean
            )
        )

        XCTAssertEqual(
            presentation.symbolName,
            "arrow.trianglehead.2.clockwise.rotate.90"
        )
        XCTAssertEqual(presentation.help, "Draft base is behind the shared version")
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

    func testNilItemUsesPrimaryTone() {
        XCTAssertEqual(MemoryFileTreeTitleTone.resolve(item: nil), .primary)
    }

    func testSyncedResourceUsesPrimaryTone() {
        let item = MemoryListItem(id: "res", resource: nil, draft: nil, inherited: false)
        XCTAssertEqual(MemoryFileTreeTitleTone.resolve(item: item), .primary)
    }

    func testInheritedResourceUsesSecondaryTone() {
        let item = MemoryListItem(id: "res", resource: nil, draft: nil, inherited: true)
        XCTAssertEqual(MemoryFileTreeTitleTone.resolve(item: item), .secondary)
    }

    func testNewDraftUsesGreenTone() {
        let item = MemoryListItem(
            id: "new",
            resource: nil,
            draft: draft(targetId: nil),
            inherited: false
        )
        XCTAssertEqual(MemoryFileTreeTitleTone.resolve(item: item), .newDraft)
    }

    func testModifiedDraftUsesYellowTone() {
        let item = MemoryListItem(
            id: "res",
            resource: nil,
            draft: draft(targetId: "res"),
            inherited: false
        )
        XCTAssertEqual(MemoryFileTreeTitleTone.resolve(item: item), .modifiedDraft)
    }

    func testDeletionDraftUsesRedTone() {
        let item = MemoryListItem(
            id: "res",
            resource: nil,
            draft: draft(targetId: "res", isDeletion: true),
            inherited: false
        )
        XCTAssertEqual(MemoryFileTreeTitleTone.resolve(item: item), .deletedDraft)
    }

    func testDraftToneTakesPrecedenceOverInherited() {
        let item = MemoryListItem(
            id: "res",
            resource: nil,
            draft: draft(targetId: "res"),
            inherited: true
        )
        XCTAssertEqual(MemoryFileTreeTitleTone.resolve(item: item), .modifiedDraft)
    }

    private func draft(
        targetId: String?,
        isDeletion: Bool = false
    ) -> LocalDraft {
        LocalDraft(
            id: "draft-\(targetId ?? "new")",
            projectId: "project",
            serverId: nil,
            serverVersion: 0,
            baseCommitId: "base",
            currentCommitId: "base",
            freshness: .current,
            hasUpstreamResourceChanges: false,
            reconciliation: .unknown,
            reconciliationCandidateId: nil,
            scope: .project,
            kind: .context,
            targetId: targetId,
            status: .open,
            origin: .desktop,
            syncStatus: .synced,
            updatedAt: "2026-08-05T00:00:00Z",
            document: .init(title: "Untitled", path: "a.md", body: ""),
            isDeletion: isDeletion
        )
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
