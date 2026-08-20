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

    func testStaleResourceWithoutDraftShowsSyncAccessory() throws {
        let presentation = try XCTUnwrap(
            SharedUpdateStatusPresentation.resolve(
                freshness: nil,
                hasUpstreamResourceChanges: false,
                reconciliation: .unknown,
                isStale: true
            )
        )

        XCTAssertEqual(
            presentation.symbolName,
            "arrow.trianglehead.2.clockwise.rotate.90"
        )
        XCTAssertEqual(presentation.help, "A newer shared version is available")
    }

    func testSyncedResourceWithoutDraftShowsNoAccessory() {
        XCTAssertNil(
            SharedUpdateStatusPresentation.resolve(
                freshness: nil,
                hasUpstreamResourceChanges: false,
                reconciliation: .unknown,
                isStale: false
            )
        )
    }

    func testBehindDraftTakesPrecedenceOverStaleResource() throws {
        let presentation = try XCTUnwrap(
            SharedUpdateStatusPresentation.resolve(
                freshness: .behind,
                hasUpstreamResourceChanges: false,
                reconciliation: .clean,
                isStale: true
            )
        )

        XCTAssertEqual(presentation.help, "Draft base is behind the shared version")
    }

    func testNilItemUsesPrimaryTone() {
        XCTAssertEqual(MemoryFileTreeTitleTone.resolve(item: nil), .primary)
    }

    func testSyncedResourceUsesPrimaryTone() {
        let item = MemoryListItem(id: "res", resource: nil, draft: nil, inherited: false)
        XCTAssertEqual(MemoryFileTreeTitleTone.resolve(item: item), .primary)
    }

    func testInheritedResourceWithoutDraftUsesPrimaryTone() {
        let item = MemoryListItem(id: "res", resource: nil, draft: nil, inherited: true)
        XCTAssertEqual(MemoryFileTreeTitleTone.resolve(item: item), .primary)
    }

    func testNewDraftUsesGreenToneRegardlessOfInheritance() {
        for inherited in [false, true] {
            let item = MemoryListItem(
                id: "new",
                resource: nil,
                draft: draft(targetId: nil),
                inherited: inherited
            )
            XCTAssertEqual(MemoryFileTreeTitleTone.resolve(item: item), .newDraft)
        }
    }

    func testModifiedDraftUsesYellowToneRegardlessOfInheritance() {
        for inherited in [false, true] {
            let item = MemoryListItem(
                id: "res",
                resource: nil,
                draft: draft(targetId: "res"),
                inherited: inherited
            )
            XCTAssertEqual(MemoryFileTreeTitleTone.resolve(item: item), .modifiedDraft)
        }
    }

    func testDeletionDraftUsesRedToneRegardlessOfInheritance() {
        for inherited in [false, true] {
            let item = MemoryListItem(
                id: "res",
                resource: nil,
                draft: draft(targetId: "res", isDeletion: true),
                inherited: inherited
            )
            XCTAssertEqual(MemoryFileTreeTitleTone.resolve(item: item), .deletedDraft)
        }
    }

    func testLegacyProjectMemoryUsesReadOnlyLockWithoutChangingTitleTone() {
        let item = memoryItem(
            id: "legacy-project-memory",
            path: "legacy.md",
            scope: .project,
            projectId: "project"
        )

        let accessory = MemoryFileTreeRowAccessory.resolve(item: item)
        XCTAssertEqual(accessory, .legacyProjectReadOnly)
        XCTAssertEqual(accessory.help, "Legacy Project memory — read-only")
        XCTAssertEqual(MemoryFileTreeTitleTone.resolve(item: item), .primary)
    }

    func testOrgMemoryDoesNotUseLegacyReadOnlyLock() {
        let item = memoryItem(id: "org-memory", path: "org.md")

        XCTAssertEqual(MemoryFileTreeRowAccessory.resolve(item: item), .none)
    }

    func testThreeWayLocalChangeShowsRemovalThenInsertion() {
        let lines = ThreeWayDiff.lines(base: "a\nb", local: "a\nB", remote: "a\nb")
        XCTAssertEqual(lines.map(\.kind), [.context, .removal, .insertion])
    }

    func testThreeWayRemoteChangeShowsGrayLines() {
        let lines = ThreeWayDiff.lines(base: "a\nb", local: "a\nb", remote: "a\nB")
        XCTAssertEqual(lines.map(\.kind), [.context, .remoteRemoval, .remoteInsertion])
    }

    func testThreeWayConflictShowsRemoteThenLocal() {
        let lines = ThreeWayDiff.lines(base: "a", local: "L", remote: "R")
        XCTAssertEqual(lines.map(\.kind), [.removal, .remoteInsertion, .insertion])
    }

    func testThreeWayIdenticalLocalAndRemoteReplacementIsEmittedOnce() {
        let lines = ThreeWayDiff.lines(base: "a", local: "x", remote: "x")

        XCTAssertEqual(lines.map(\.kind), [.removal, .insertion])
        XCTAssertEqual(lines.map(\.text), ["a", "x"])
        XCTAssertEqual(lines.map(\.oldLineNumber), [1, nil])
        XCTAssertEqual(lines.map(\.newLineNumber), [nil, 1])
        XCTAssertEqual(lines.map(\.remoteLineNumber), [nil, 1])
    }

    func testThreeWayMultiLineConflictKeepsRemoteAndLocalGroupsContiguous() {
        let lines = ThreeWayDiff.lines(
            base: "old 1\nold 2",
            local: "local 1\nlocal 2",
            remote: "remote 1\nremote 2"
        )

        XCTAssertEqual(lines.map(\.kind), [
            .removal,
            .removal,
            .remoteInsertion,
            .remoteInsertion,
            .insertion,
            .insertion,
        ])
        XCTAssertEqual(lines.map(\.text), [
            "old 1",
            "old 2",
            "remote 1",
            "remote 2",
            "local 1",
            "local 2",
        ])
        XCTAssertEqual(lines.compactMap(\.remoteLineNumber), [1, 2])
        XCTAssertEqual(lines.compactMap(\.newLineNumber), [1, 2])
    }

    func testThreeWayConflictEmitsSharedPrefixAndSuffixOnce() {
        let lines = ThreeWayDiff.lines(
            base: "old prefix\nold middle\nold suffix",
            local: "shared prefix\nlocal middle\nshared suffix",
            remote: "shared prefix\nremote middle\nshared suffix"
        )

        XCTAssertEqual(lines.map(\.kind), [
            .removal,
            .removal,
            .removal,
            .insertion,
            .remoteInsertion,
            .insertion,
            .insertion,
        ])
        XCTAssertEqual(lines.map(\.text), [
            "old prefix",
            "old middle",
            "old suffix",
            "shared prefix",
            "remote middle",
            "local middle",
            "shared suffix",
        ])
        XCTAssertEqual(lines.compactMap(\.newLineNumber), [1, 2, 3])
        XCTAssertEqual(lines.compactMap(\.remoteLineNumber), [1, 2, 3])
        XCTAssertEqual(lines.filter { $0.text == "shared prefix" }.count, 1)
        XCTAssertEqual(lines.filter { $0.text == "shared suffix" }.count, 1)
    }

    func testThreeWayEmptyBaseYieldsPureInsertions() {
        let lines = ThreeWayDiff.lines(base: "", local: "a\nb", remote: "")
        XCTAssertEqual(lines.map(\.kind), [.insertion, .insertion])
    }

    func testThreeWayEmptyBaseWithRemoteYieldsGrayFirst() {
        let lines = ThreeWayDiff.lines(base: "", local: "a", remote: "b")
        XCTAssertEqual(lines.map(\.kind), [.remoteInsertion, .insertion])
    }

    func testThreeWayPureRemoteInsertionFromEmptyBaseUsesRemoteCoordinatesAndLabel() throws {
        let lines = ThreeWayDiff.lines(base: "", local: "", remote: "remote 1\nremote 2")

        XCTAssertEqual(lines.map(\.kind), [.remoteInsertion, .remoteInsertion])
        XCTAssertEqual(lines.map(\.text), ["remote 1", "remote 2"])
        XCTAssertEqual(lines.map(\.oldLineNumber), [nil, nil])
        XCTAssertEqual(lines.map(\.newLineNumber), [nil, nil])
        XCTAssertEqual(lines.map(\.remoteLineNumber), [1, 2])

        let presentation = UnifiedDiffPresentation(lines: lines)
        XCTAssertTrue(presentation.showsRemoteLineNumbers)
        let block = try XCTUnwrap(presentation.blocks.first)
        guard case .hunk(let label) = block.kind else {
            return XCTFail("Expected a three-way hunk")
        }
        XCTAssertEqual(label, "@@ base 0,0 · local 0,0 · remote 1,2 @@")
    }

    func testThreeWayHunkLabelKeepsInsertionBoundaryForEmptyAxes() throws {
        let lines = ThreeWayDiff.lines(
            base: "a\nb\nc",
            local: "a\nx\nb\nc",
            remote: "a\nb\nc"
        )

        let presentation = UnifiedDiffPresentation(lines: lines, contextLineCount: 0)
        let block = try XCTUnwrap(presentation.blocks.first { block in
            if case .hunk = block.kind { return true }
            return false
        })
        guard case .hunk(let label) = block.kind else {
            return XCTFail("Expected a three-way hunk")
        }
        XCTAssertEqual(label, "@@ base 1,0 · local 2,1 · remote 1,0 @@")
    }

    func testThreeWayHunkLabelKeepsDeletionBoundaryForEmptyAxis() throws {
        let lines = ThreeWayDiff.lines(
            base: "a\nb\nc",
            local: "a\nc",
            remote: "a\nb\nc"
        )

        let presentation = UnifiedDiffPresentation(lines: lines, contextLineCount: 0)
        let block = try XCTUnwrap(presentation.blocks.first { block in
            if case .hunk = block.kind { return true }
            return false
        })
        guard case .hunk(let label) = block.kind else {
            return XCTFail("Expected a three-way hunk")
        }
        XCTAssertEqual(label, "@@ base 2,1 · local 1,0 · remote 2,1 @@")
    }

    func testThreeWayRemoteReplacementPreservesTextAndThreeCoordinateSpaces() throws {
        let lines = ThreeWayDiff.lines(base: "a\nb", local: "a\nb", remote: "a\nB")

        XCTAssertEqual(lines.map(\.text), ["a", "b", "B"])
        XCTAssertEqual(lines.map(\.oldLineNumber), [1, 2, nil])
        XCTAssertEqual(lines.map(\.newLineNumber), [1, 2, nil])
        XCTAssertEqual(lines.map(\.remoteLineNumber), [1, nil, 2])

        let presentation = UnifiedDiffPresentation(lines: lines)
        let block = try XCTUnwrap(presentation.blocks.first)
        guard case .hunk(let label) = block.kind else {
            return XCTFail("Expected a three-way hunk")
        }
        XCTAssertEqual(label, "@@ base 1,2 · local 1,2 · remote 1,2 @@")
    }

    func testThreeWayDiffRetainsRepeatedBaseLines() {
        let lines = ThreeWayDiff.lines(
            base: "repeat\nrepeat\nend",
            local: "repeat\nlocal\nrepeat\nend",
            remote: "repeat\nremote\nrepeat\nend"
        )
        let context = lines.filter { $0.kind == .context }

        XCTAssertEqual(context.map(\.text), ["repeat", "repeat", "end"])
        XCTAssertEqual(context.compactMap(\.oldLineNumber), [1, 2, 3])
        XCTAssertEqual(
            lines.filter { $0.kind == .remoteInsertion }.map(\.text),
            ["remote"]
        )
        XCTAssertEqual(
            lines.filter { $0.kind == .insertion }.map(\.text),
            ["local"]
        )
    }

    func testTwoWayUnifiedPresentationKeepsStandardHeaderAndTwoCoordinates() throws {
        let presentation = UnifiedDiffPresentation(model: SplitDiffModel.make(
            original: "old",
            modified: "new"
        ))

        XCTAssertFalse(presentation.showsRemoteLineNumbers)
        let block = try XCTUnwrap(presentation.blocks.first)
        guard case .hunk(let label) = block.kind else {
            return XCTFail("Expected a two-way hunk")
        }
        XCTAssertEqual(label, "@@ -1,1 +1,1 @@")
        XCTAssertTrue(block.lines.allSatisfy { $0.remoteLineNumber == nil })
    }

    func testThreeWayUnchangedStreamYieldsNoBlocks() {
        let presentation = UnifiedDiffPresentation(lines: ThreeWayDiff.lines(
            base: "a", local: "a", remote: "a"
        ))
        XCTAssertEqual(presentation.changedLineCount, 0)
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

    private func memoryItem(
        id: String,
        path: String,
        scope: MemoryScope = .org,
        projectId: String? = nil
    ) -> MemoryListItem {
        .init(
            id: id,
            resource: .init(
                id: id,
                scope: scope,
                projectId: projectId,
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
