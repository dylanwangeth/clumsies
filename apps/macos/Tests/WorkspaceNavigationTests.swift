import XCTest
@testable import Clumsies

@MainActor
final class WorkspaceNavigationTests: XCTestCase {
    func testIssueWorkspaceIsPresentedAsKanban() {
        XCTAssertEqual(WorkspaceSection.issues.title, "Kanban")
    }

    func testMemoryWorkspaceTitleIsMemory() {
        XCTAssertEqual(WorkspaceSection.memory.title, "Memory")
    }

    func testReviewsAndKanbanUseSidebarWithPushNavigatedDetail() {
        XCTAssertEqual(WorkspaceColumnLayout(section: .issues), .sidebarDetail)
        XCTAssertEqual(WorkspaceColumnLayout(section: .reviews), .sidebarDetail)

        for section in [
            WorkspaceSection.memory,
            .bundles,
        ] {
            XCTAssertEqual(
                WorkspaceColumnLayout(section: section),
                .sidebarContentDetail
            )
        }
    }

    func testReviewStatusFilterMatchesByStatus() {
        let all = ReviewStatusFilter.allCases
        let open = reviewRecord(status: "open")
        XCTAssertTrue(ReviewStatusFilter.open.matches(open))
        XCTAssertFalse(ReviewStatusFilter.approved.matches(open))
        XCTAssertTrue(ReviewStatusFilter.all.matches(open))
        XCTAssertEqual(ReviewStatusFilter.open.count(in: [open]), 1)
        XCTAssertEqual(ReviewStatusFilter.approved.count(in: [open]), 0)
        XCTAssertEqual(ReviewStatusFilter.all.count(in: [open]), 1)
        XCTAssertEqual(all.count, 5)
    }

    func testReviewQueueStatePrioritizesDecisionBlockersAndViewerAction() {
        XCTAssertEqual(
            ReviewQueueStatePresentation.resolve(
                review: reviewRecord(
                    status: "merged",
                    freshness: .behind,
                    reconciliation: .conflicts
                ),
                isAuthor: false,
                canMerge: true
            ),
            .init(
                title: "Merged",
                symbolName: "arrow.triangle.merge",
                tone: .neutral,
                isQueueSignal: false
            )
        )
        XCTAssertEqual(
            ReviewQueueStatePresentation.resolve(
                review: reviewRecord(
                    status: "open",
                    freshness: .behind,
                    reconciliation: .conflicts
                ),
                isAuthor: false,
                canMerge: false
            ).title,
            "Conflicts"
        )
        XCTAssertEqual(
            ReviewQueueStatePresentation.resolve(
                review: reviewRecord(status: "open", reconciliation: .conflicts),
                isAuthor: false,
                canMerge: false
            ).title,
            "Needs Review"
        )
        XCTAssertEqual(
            ReviewQueueStatePresentation.resolve(
                review: reviewRecord(status: "approved", freshness: .behind),
                isAuthor: false,
                canMerge: true
            ).title,
            "Out of Date"
        )
        XCTAssertEqual(
            ReviewQueueStatePresentation.resolve(
                review: reviewRecord(status: "approved", freshness: .behind),
                isAuthor: true,
                canMerge: true
            ).title,
            "Update Required"
        )
        XCTAssertEqual(
            ReviewQueueStatePresentation.resolve(
                review: reviewRecord(status: "open"),
                isAuthor: false,
                canMerge: false
            ).title,
            "Needs Review"
        )
        XCTAssertEqual(
            ReviewQueueStatePresentation.resolve(
                review: reviewRecord(status: "approved", approvedResultHash: "result"),
                isAuthor: false,
                canMerge: true
            ).title,
            "Ready to Merge"
        )
        XCTAssertEqual(
            ReviewQueueStatePresentation.resolve(
                review: reviewRecord(status: "approved"),
                isAuthor: false,
                canMerge: true
            ).title,
            "Approved"
        )
        XCTAssertEqual(
            ReviewQueueStatePresentation.resolve(
                review: reviewRecord(status: "rejected"),
                isAuthor: true,
                canMerge: false
            ).title,
            "Resubmit"
        )
        XCTAssertEqual(
            ReviewQueueStatePresentation.resolve(
                review: reviewRecord(status: "rejected"),
                isAuthor: false,
                canMerge: false
            ).title,
            "Awaiting Author"
        )
    }

    func testReviewDecisionReadinessIsBoundToTheRenderedVersion() {
        let reviewId = "review-versioned"
        let rendered = reviewRecord(status: "open", id: reviewId, version: 7)
        let readiness = ReviewDecisionReadiness(review: rendered)

        XCTAssertTrue(readiness.matches(rendered))
        XCTAssertFalse(readiness.matches(reviewRecord(
            status: "open",
            id: reviewId,
            version: 8
        )))
        XCTAssertFalse(readiness.matches(reviewRecord(
            status: "open",
            freshness: .behind,
            id: reviewId,
            version: 7,
            currentCommitId: "commit-new"
        )))
    }

    func testMergeActionRequiresAnImmutableApprovedResult() {
        XCTAssertFalse(ReviewMenuAction.merge.isAvailable(
            for: reviewRecord(status: "approved"),
            canMergeReviews: true,
            isAuthor: false
        ))
        XCTAssertFalse(ReviewMenuAction.merge.isAvailable(
            for: reviewRecord(status: "approved", approvedResultHash: ""),
            canMergeReviews: true,
            isAuthor: false
        ))
        XCTAssertTrue(ReviewMenuAction.merge.isAvailable(
            for: reviewRecord(status: "approved", approvedResultHash: "sha256:result"),
            canMergeReviews: true,
            isAuthor: false
        ))
    }

    func testReviewListContentStateDistinguishesLoadingAndEmptyQueues() {
        XCTAssertEqual(
            ReviewListContentState.resolve(phase: .launching, totalCount: 0, visibleCount: 0),
            .loading
        )
        XCTAssertEqual(
            ReviewListContentState.resolve(phase: .loading, totalCount: 0, visibleCount: 0),
            .loading
        )
        XCTAssertEqual(
            ReviewListContentState.resolve(phase: .ready, totalCount: 0, visibleCount: 0),
            .empty
        )
        XCTAssertEqual(
            ReviewListContentState.resolve(phase: .ready, totalCount: 2, visibleCount: 0),
            .filteredEmpty
        )
        XCTAssertEqual(
            ReviewListContentState.resolve(phase: .loading, totalCount: 2, visibleCount: 1),
            .content
        )
    }

    func testReviewToolbarOwnershipAcrossListAndOpenDetail() {
        let review = reviewRecord(status: "open")
        XCTAssertEqual(
            ReviewToolbarOwnership.resolve(
                surface: .list,
                review: review,
                canMergeReviews: false,
                isAuthor: false
            ).items,
            [.filter, .search]
        )
        XCTAssertEqual(
            ReviewToolbarOwnership.resolve(
                surface: .detail,
                review: review,
                canMergeReviews: false,
                isAuthor: false
            ).items,
            [.decision(.reject), .decision(.approve)]
        )
    }

    func testReviewDetailRouteCarriesOnlyTheStableReviewId() {
        let route = ReviewRoute(reviewId: "review-0123456789abcdef")

        XCTAssertEqual(route.reviewId, "review-0123456789abcdef")
    }

    func testIssueDetailRouteCarriesOnlyTheGlobalIssueId() {
        let route = IssueBoardRoute(
            issueId: "issue_0123456789abcdef0123456789abcdef"
        )

        XCTAssertEqual(
            route.issueId,
            "issue_0123456789abcdef0123456789abcdef"
        )
    }

    func testReviewStatusFiltersKeepServerStatusOrderAndTitles() {
        XCTAssertEqual(
            ReviewStatusFilter.allCases.map(\.rawValue),
            ["open", "approved", "rejected", "merged", "all"]
        )
        XCTAssertEqual(
            ReviewStatusFilter.allCases.map(\.title),
            ["Open", "Approved", "Rejected", "Merged", "All"]
        )
    }

    func testBackAndForwardFollowTabSelectionHistory() {
        let store = WorkspaceStore()
        let first = tab(itemId: "first")
        let second = tab(itemId: "second")
        store.tabs = [first, second]
        store.activeTabId = first.id

        store.selectTab(second)

        XCTAssertEqual(store.activeTabId, second.id)
        XCTAssertTrue(store.canGoBack)
        XCTAssertFalse(store.canGoForward)

        store.goBack()

        XCTAssertEqual(store.activeTabId, first.id)
        XCTAssertFalse(store.canGoBack)
        XCTAssertTrue(store.canGoForward)

        store.goForward()

        XCTAssertEqual(store.activeTabId, second.id)
        XCTAssertTrue(store.canGoBack)
        XCTAssertFalse(store.canGoForward)
    }

    func testNavigationHistoryUsesTheVisibleTabWhenStoredActiveTabIsFromAnotherScope() {
        let store = WorkspaceStore()
        let hiddenTab = tab(itemId: "other-project", section: .memory, projectId: "other-project")
        let firstLocalTab = tab(itemId: "local-first", section: .memory, projectId: "project")
        let secondLocalTab = tab(itemId: "local-second", section: .memory, projectId: "project")
        store.tabs = [hiddenTab, firstLocalTab, secondLocalTab]
        store.selectedSection = .memory
        store.activeProjectId = "project"
        store.activeTabId = hiddenTab.id

        store.selectTab(firstLocalTab)
        store.goBack()

        XCTAssertEqual(store.activeTabId, secondLocalTab.id)
        XCTAssertEqual(store.selectedItemId, secondLocalTab.itemId)
    }

    func testOpeningMarkdownDefaultsToPreview() {
        let store = WorkspaceStore()

        store.open(item(path: "context/architecture.md"))

        XCTAssertEqual(store.activeVisibleTab?.mode, .preview)
    }

    func testOpeningPlainTextDefaultsToSource() {
        let store = WorkspaceStore()

        store.open(item(path: "context/notes.txt"))

        XCTAssertEqual(store.activeVisibleTab?.mode, .source)
    }

    func testCenteredTextViewUsesMinimumInsetInNarrowPane() {
        XCTAssertEqual(
            CenteredTextView.horizontalInset(for: 700),
            DocumentContentMetrics.minimumHorizontalInset
        )
    }

    func testCenteredTextViewCentersReadableColumnInWidePane() {
        let paneWidth: CGFloat = 1_200

        XCTAssertEqual(
            CenteredTextView.horizontalInset(for: paneWidth),
            (paneWidth - DocumentContentMetrics.maximumWidth) / 2
        )
    }

    func testReconciliationToolbarCommandsRemainBoundToDocument() {
        XCTAssertEqual(
            DocumentSessionCommand.applyReconciliation(itemId: "document").itemId,
            "document"
        )
        XCTAssertEqual(
            DocumentSessionCommand.closeReconciliation(itemId: "document").itemId,
            "document"
        )
    }

    private func tab(
        itemId: String,
        section: WorkspaceSection = .memory,
        projectId: String? = nil
    ) -> WorkbenchTab {
        WorkbenchTab(
            section: section,
            projectId: projectId,
            itemId: itemId,
            mode: .source,
            title: "\(itemId).md"
        )
    }

    private func item(path: String) -> MemoryListItem {
        let resource = MemoryResource(
            id: path,
            scope: .org,
            projectId: nil,
            projectName: nil,
            kind: .context,
            contentHash: "hash",
            updatedAt: "2026-08-05T00:00:00Z",
            refCommitId: nil,
            contentLoaded: true,
            document: .init(title: URL(fileURLWithPath: path).lastPathComponent, path: path, body: "")
        )
        return MemoryListItem(id: resource.id, resource: resource, draft: nil, inherited: false)
    }

    private func reviewRecord(
        status: String,
        freshness: DraftFreshness = .current,
        reconciliation: DraftReconciliationStatus = .clean,
        approvedResultHash: String? = nil,
        id: String = UUID().uuidString,
        version: Int = 1,
        currentCommitId: String? = nil
    ) -> ReviewRecord {
        ReviewRecord(
            id: id,
            projectId: "prj",
            draftId: "draft",
            title: "Review title",
            description: "",
            author: UserReference(
                userId: "u",
                email: "u@example.com",
                displayName: "Reviewer",
                avatarUrl: nil,
                role: "member"
            ),
            status: status,
            version: version,
            decisionBody: nil,
            approvedResultHash: approvedResultHash,
            decidedBy: nil,
            decidedAt: nil,
            freshness: freshness,
            reconciliation: reconciliation,
            reconciliationCandidateId: nil,
            currentCommitId: currentCommitId,
            updatedAt: "2026-08-09T00:00:00Z"
        )
    }

}
