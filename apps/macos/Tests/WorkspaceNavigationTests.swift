import XCTest
@testable import Clumsies

@MainActor
final class WorkspaceNavigationTests: XCTestCase {
    func testIssueWorkspaceIsPresentedAsKanban() {
        XCTAssertEqual(WorkspaceSection.issues.title, "Kanban")
    }

    func testIssuesAndReviewsUseSidebarAndDetailWhileOtherSectionsKeepThreeColumns() {
        XCTAssertEqual(WorkspaceColumnLayout(section: .issues), .sidebarDetail)
        XCTAssertEqual(WorkspaceColumnLayout(section: .reviews), .sidebarDetail)

        for section in [
            WorkspaceSection.hub,
            .local,
            .bundles,
        ] {
            XCTAssertEqual(
                WorkspaceColumnLayout(section: section),
                .sidebarContentDetail
            )
        }
    }

    func testReviewStatusFilterMatchesByStatus() {
        func record(status: String) -> ReviewRecord {
            ReviewRecord(
                id: UUID().uuidString,
                projectId: "prj",
                draftId: "draft",
                title: "T",
                description: "",
                author: UserReference(
                    userId: "u",
                    email: "u@example.com",
                    displayName: nil,
                    avatarUrl: nil,
                    role: "member"
                ),
                status: status,
                version: 1,
                decisionBody: nil,
                approvedResultHash: nil,
                freshness: .current,
                reconciliation: .clean,
                reconciliationCandidateId: nil,
                currentCommitId: nil,
                updatedAt: "2026-08-09T00:00:00Z"
            )
        }

        let all = ReviewStatusFilter.allCases
        let open = record(status: "open")
        XCTAssertTrue(ReviewStatusFilter.open.matches(open))
        XCTAssertFalse(ReviewStatusFilter.approved.matches(open))
        XCTAssertTrue(ReviewStatusFilter.all.matches(open))
        XCTAssertEqual(all.count, 5)
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
        let hiddenHubTab = tab(itemId: "hub", section: .hub)
        let firstLocalTab = tab(itemId: "local-first", section: .local, projectId: "project")
        let secondLocalTab = tab(itemId: "local-second", section: .local, projectId: "project")
        store.tabs = [hiddenHubTab, firstLocalTab, secondLocalTab]
        store.selectedSection = .local
        store.activeProjectId = "project"
        store.activeTabId = hiddenHubTab.id

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
        section: WorkspaceSection = .hub,
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
}
