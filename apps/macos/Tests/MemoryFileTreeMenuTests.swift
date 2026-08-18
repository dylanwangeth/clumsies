import XCTest
@testable import Clumsies

final class MemoryFileTreeMenuTests: XCTestCase {
    private func resourceItem(_ id: String, scope: MemoryScope, inherited: Bool, projectId: String? = nil) -> MemoryListItem {
        MemoryListItem(
            id: id,
            resource: MemoryResource(
                id: id,
                scope: scope,
                projectId: projectId,
                projectName: nil,
                kind: .context,
                contentHash: "hash-\(id)",
                updatedAt: "2026-01-01T00:00:00Z",
                refCommitId: nil,
                contentLoaded: false,
                document: EditableMemoryDocument(title: id, path: "\(id).md", body: "")
            ),
            draft: nil,
            inherited: inherited
        )
    }

    private func draftItem(_ id: String, scope: MemoryScope) -> MemoryListItem {
        MemoryListItem(
            id: id,
            resource: nil,
            draft: LocalDraft(
                id: id,
                projectId: "p1",
                serverId: nil,
                serverVersion: 0,
                baseCommitId: nil,
                currentCommitId: nil,
                freshness: .current,
                hasUpstreamResourceChanges: false,
                reconciliation: .clean,
                reconciliationCandidateId: nil,
                scope: scope,
                kind: .context,
                targetId: nil,
                status: .open,
                origin: .desktop,
                syncStatus: .queued,
                updatedAt: "2026-01-01T00:00:00Z",
                document: EditableMemoryDocument(title: id, path: "\(id).md", body: ""),
                isDeletion: false
            ),
            inherited: false
        )
    }

    // MARK: - Org view

    func testOrgViewAddableIncludesAllOrgItems() {
        let items = [
            resourceItem("org-a", scope: .org, inherited: false),
            resourceItem("org-b", scope: .org, inherited: false),
        ]
        XCTAssertEqual(MemoryFileTreeMenu.addable(items, inOrgView: true).map(\.id), ["org-a", "org-b"])
    }

    func testOrgViewHasNoRemovableOrInheritedItems() {
        let items = [
            resourceItem("org-a", scope: .org, inherited: false),
            resourceItem("org-b", scope: .org, inherited: true),
        ]
        XCTAssertTrue(MemoryFileTreeMenu.removable(items, inOrgView: true).isEmpty)
    }

    func testOrgViewTrashableExcludesPureDrafts() {
        let items = [
            resourceItem("org-a", scope: .org, inherited: false),
            draftItem("draft-a", scope: .org),
        ]
        XCTAssertEqual(MemoryFileTreeMenu.trashable(items, inOrgView: true).map(\.id), ["org-a"])
        XCTAssertTrue(MemoryFileTreeMenu.isManageable(items[1], inOrgView: true))
    }

    // MARK: - Project view

    func testProjectViewHasNoAddableItems() {
        let items = [
            resourceItem("org-a", scope: .org, inherited: false),
            resourceItem("own-a", scope: .project, inherited: false, projectId: "p1"),
        ]
        XCTAssertTrue(MemoryFileTreeMenu.addable(items, inOrgView: false).isEmpty)
    }

    func testProjectViewRemovableOnlyInheritedItems() {
        let items = [
            resourceItem("org-ref", scope: .org, inherited: true),
            resourceItem("org-unref", scope: .org, inherited: false),
            resourceItem("own-a", scope: .project, inherited: false, projectId: "p1"),
        ]
        XCTAssertEqual(MemoryFileTreeMenu.removable(items, inOrgView: false).map(\.id), ["org-ref"])
    }

    func testProjectViewManageableOnlyProjectOwned() {
        let items = [
            resourceItem("org-ref", scope: .org, inherited: true),
            resourceItem("org-unref", scope: .org, inherited: false),
            resourceItem("own-a", scope: .project, inherited: false, projectId: "p1"),
        ]
        XCTAssertEqual(
            items.map { MemoryFileTreeMenu.isManageable($0, inOrgView: false) },
            [false, false, true]
        )
        XCTAssertEqual(MemoryFileTreeMenu.trashable(items, inOrgView: false).map(\.id), ["own-a"])
    }

    // MARK: - Mixed selection stays predictable

    func testMixedSelectionSplitsRemovableAndTrashable() {
        let items = [
            resourceItem("org-ref", scope: .org, inherited: true),
            resourceItem("own-a", scope: .project, inherited: false, projectId: "p1"),
            resourceItem("org-unref", scope: .org, inherited: false),
        ]
        XCTAssertEqual(MemoryFileTreeMenu.removable(items, inOrgView: false).map(\.id), ["org-ref"])
        XCTAssertEqual(MemoryFileTreeMenu.trashable(items, inOrgView: false).map(\.id), ["own-a"])
    }
}
