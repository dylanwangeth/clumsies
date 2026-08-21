import XCTest
@testable import Clumsies

final class MemoryFileTreeMenuTests: XCTestCase {
    private func resourceItem(
        _ id: String,
        scope: MemoryScope,
        inherited: Bool,
        projectId: String? = nil,
        draft: LocalDraft? = nil
    ) -> MemoryListItem {
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
            draft: draft,
            inherited: inherited
        )
    }

    private func localDraft(
        _ id: String,
        scope: MemoryScope,
        targetId: String? = nil,
        isDeletion: Bool = false,
        status: DaemonLocalDraftStatus = .open
    ) -> LocalDraft {
        LocalDraft(
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
            targetId: targetId,
            status: status,
            origin: .desktop,
            syncStatus: .queued,
            updatedAt: "2026-01-01T00:00:00Z",
            document: EditableMemoryDocument(title: id, path: "\(id).md", body: ""),
            isDeletion: isDeletion
        )
    }

    private func draftItem(
        _ id: String,
        scope: MemoryScope,
        targetId: String? = nil,
        isDeletion: Bool = false
    ) -> MemoryListItem {
        MemoryListItem(
            id: targetId ?? id,
            resource: nil,
            draft: localDraft(id, scope: scope, targetId: targetId, isDeletion: isDeletion),
            inherited: false
        )
    }

    // MARK: - Org view

    func testOrgViewAddableIncludesPublishedOrgItems() {
        let items = [
            resourceItem("org-a", scope: .org, inherited: false),
            resourceItem("org-b", scope: .org, inherited: false),
            draftItem("draft-a", scope: .org),
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

    func testOrgViewIsReadOnlyForAuthorityMutations() {
        let items = [
            resourceItem("org-a", scope: .org, inherited: false),
            draftItem("draft-a", scope: .org),
        ]
        XCTAssertTrue(MemoryFileTreeMenu.trashable(items, inOrgView: true).isEmpty)
        XCTAssertFalse(MemoryFileTreeMenu.canRename(items[0], inOrgView: true))
        XCTAssertFalse(
            MemoryFileTreeMenu.canProposeOrganizationDeletion(items[0], inOrgView: true)
        )
    }

    func testOrgViewDoesNotOfferNewMemoryCreation() {
        XCTAssertNil(MemoryFileTreeMenu.creationScope(inOrgView: true))
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

    func testProjectViewAuthorityActionsOnlyIncludeSelectedOrgResources() {
        let items = [
            resourceItem("org-ref", scope: .org, inherited: true),
            resourceItem("org-unref", scope: .org, inherited: false),
            resourceItem("own-a", scope: .project, inherited: false, projectId: "p1"),
        ]
        XCTAssertEqual(
            items.map { MemoryFileTreeMenu.canRename($0, inOrgView: false) },
            [true, false, false]
        )
        XCTAssertEqual(
            MemoryFileTreeMenu.trashable(items, inOrgView: false).map(\.id),
            ["org-ref"]
        )
    }

    func testProjectViewCreatesProjectBoundOrgProposals() {
        XCTAssertEqual(MemoryFileTreeMenu.creationScope(inOrgView: false), .org)
    }

    func testDirectoryReviewIncludesOnlyOpenOrganizationDraftsInProjectView() {
        let openOrg = resourceItem(
            "org-open",
            scope: .org,
            inherited: true,
            draft: localDraft("draft-open", scope: .org, targetId: "org-open")
        )
        let submittedOrg = resourceItem(
            "org-submitted",
            scope: .org,
            inherited: true,
            draft: localDraft(
                "draft-submitted",
                scope: .org,
                targetId: "org-submitted",
                status: .submitted
            )
        )
        let project = draftItem("project-draft", scope: .project)

        XCTAssertEqual(
            MemoryFileTreeMenu.reviewableDrafts(
                [openOrg, submittedOrg, project],
                inOrgView: false
            ).map(\.id),
            ["draft-open"]
        )
        XCTAssertTrue(
            MemoryFileTreeMenu.reviewableDrafts([openOrg], inOrgView: true).isEmpty
        )
    }

    func testSelectedOrgAuthorityOffersExplicitMutationActionsInProjectView() {
        let item = resourceItem("org-ref", scope: .org, inherited: true)

        XCTAssertTrue(MemoryFileTreeMenu.canRename(item, inOrgView: false))
        XCTAssertTrue(MemoryFileTreeMenu.canProposeOrganizationDeletion(item, inOrgView: false))
        XCTAssertEqual(MemoryFileTreeMenu.trashable([item], inOrgView: false), [item])
    }

    func testUnselectedOrgAuthorityDoesNotOfferMutationActionsInProjectView() {
        let item = resourceItem("org-unselected", scope: .org, inherited: false)

        XCTAssertFalse(MemoryFileTreeMenu.canRename(item, inOrgView: false))
        XCTAssertFalse(MemoryFileTreeMenu.canProposeOrganizationDeletion(item, inOrgView: false))
        XCTAssertTrue(MemoryFileTreeMenu.trashable([item], inOrgView: false).isEmpty)
    }

    func testTargetBackedDraftOnlyRowDoesNotOfferAuthorityMutationActions() {
        let item = draftItem("draft", scope: .org, targetId: "org-removed")

        XCTAssertFalse(MemoryFileTreeMenu.canRename(item, inOrgView: false))
        XCTAssertFalse(MemoryFileTreeMenu.canProposeOrganizationDeletion(item, inOrgView: false))
        XCTAssertTrue(MemoryFileTreeMenu.trashable([item], inOrgView: false).isEmpty)
    }

    func testDeletionDraftDoesNotOfferDeletionAgain() {
        let item = resourceItem(
            "org-ref",
            scope: .org,
            inherited: true,
            draft: localDraft(
                "draft-delete",
                scope: .org,
                targetId: "org-ref",
                isDeletion: true
            )
        )

        XCTAssertFalse(MemoryFileTreeMenu.canRename(item, inOrgView: false))
        XCTAssertFalse(MemoryFileTreeMenu.canProposeOrganizationDeletion(item, inOrgView: false))
        XCTAssertTrue(MemoryFileTreeMenu.trashable([item], inOrgView: false).isEmpty)
    }

    func testLegacyProjectAuthorityDoesNotOfferOrganizationMutationActions() {
        let item = resourceItem(
            "legacy-project",
            scope: .project,
            inherited: false,
            projectId: "p1"
        )

        XCTAssertFalse(MemoryFileTreeMenu.canRename(item, inOrgView: false))
        XCTAssertFalse(MemoryFileTreeMenu.canProposeOrganizationDeletion(item, inOrgView: false))
        XCTAssertTrue(MemoryFileTreeMenu.trashable([item], inOrgView: false).isEmpty)
    }

    // MARK: - Mixed selection stays predictable

    func testMixedSelectionSplitsRemovableAndTrashable() {
        let items = [
            resourceItem("org-ref", scope: .org, inherited: true),
            resourceItem("own-a", scope: .project, inherited: false, projectId: "p1"),
            resourceItem("org-unref", scope: .org, inherited: false),
        ]
        XCTAssertEqual(MemoryFileTreeMenu.removable(items, inOrgView: false).map(\.id), ["org-ref"])
        XCTAssertEqual(
            MemoryFileTreeMenu.trashable(items, inOrgView: false).map(\.id),
            ["org-ref"]
        )
    }
}
