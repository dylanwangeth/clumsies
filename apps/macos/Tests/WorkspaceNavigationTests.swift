import XCTest
@testable import Clumsies

@MainActor
final class WorkspaceNavigationTests: XCTestCase {
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
}
