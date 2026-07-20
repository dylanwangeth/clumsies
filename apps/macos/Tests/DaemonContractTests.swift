import XCTest
@testable import Clumsies

final class DaemonContractTests: XCTestCase {
    func testDraftOperationUsesDaemonWireKeys() throws {
        let request = DaemonDraftOperationRequest(
            draftId: "draft-1",
            baseCommitId: "commit-1",
            projectId: "project-1",
            scope: .project,
            resource: .rule,
            op: .update(
                id: "rule-1",
                content: .rule(
                    name: "No compatibility shims",
                    appliesWhen: "Changing an internal contract",
                    constraint: "Migrate the contract directly.",
                    tags: ["coding"]
                ),
                description: nil
            ),
            source: .desktop
        )

        let data = try JSONCoding.encoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["draft_id"] as? String, "draft-1")
        XCTAssertEqual(object["base_commit_id"] as? String, "commit-1")
        XCTAssertEqual(object["resource"] as? String, "rule")
        let operation = try XCTUnwrap(object["op"] as? [String: Any])
        let update = try XCTUnwrap(operation["update"] as? [String: Any])
        let content = try XCTUnwrap(update["content"] as? [String: Any])
        XCTAssertEqual(content["kind"] as? String, "rule")
        XCTAssertEqual(content["applies_when"] as? String, "Changing an internal contract")
    }

    func testProjectConfigDecodesDaemonResponse() throws {
        let json = """
        {
          "server_url": "https://app.clumsies.ai",
          "project_id": "project-1",
          "has_access_token": true,
          "has_refresh_token": true,
          "ready": true,
          "missing_fields": []
        }
        """
        let config = try JSONCoding.decoder().decode(DaemonProjectConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.ready)
        XCTAssertEqual(config.projectId, "project-1")
    }

    func testDaemonStartupReadinessRetriesRequestTimeouts() async throws {
        let expected = DaemonHealth(
            daemonVersion: "0.1.0",
            serverUrl: "https://app.clumsies.ai",
            projectId: "project-1",
            daemonInstallationId: "daemon-1",
            logDir: "/tmp/logs",
            localDb: .init(path: "/tmp/local.db", ready: true, schemaVersion: 12)
        )
        let probe = RetryingDaemonHealthProbe(failuresRemaining: 2, result: expected)
        let readiness = DaemonStartupReadiness(
            timeout: .seconds(1),
            retryInterval: .zero,
            requestTimeout: .milliseconds(10)
        )

        let health = try await readiness.waitForHealth { timeout in
            try await probe.health(timeout: timeout)
        }
        let attempts = await probe.attemptCount()

        XCTAssertEqual(health, expected)
        XCTAssertEqual(attempts, 3)
    }

    func testDraftProjectionAppliesCreateUpdateAndRename() {
        let summary = DaemonDraftSummary(
            draftId: "draft-1",
            projectId: "project-1",
            serverDraftId: nil,
            serverVersion: 0,
            baseCommitId: "commit-1",
            scope: .project,
            resourceKind: .context,
            targetId: nil,
            path: "notes/old.md",
            conflict: nil,
            status: .open,
            createdAt: "2026-07-18T00:00:00Z",
            updatedAt: "2026-07-18T00:00:00Z",
            pendingOperationCount: 1,
            failedOperationCount: 0
        )
        let operations = [
            operation(.create(path: "notes/old.md", content: .context(content: "first"), description: nil), id: "op-1"),
            operation(.update(id: "draft-1", content: .context(content: "second"), description: nil), id: "op-2"),
            operation(.rename(id: "draft-1", newPath: "notes/new.md", description: nil), id: "op-3"),
        ]

        let draft = WorkspaceLoader.mapDraft(.init(draft: summary, operations: operations), resources: [])
        XCTAssertEqual(draft.document.path, "notes/new.md")
        XCTAssertEqual(draft.document.body, "second")
        XCTAssertEqual(draft.syncStatus, .queued)
    }

    func testStructuredDraftProjectionPreservesRuleAndWorkflowFields() {
        let rule = projectedDraft(
            kind: .rule,
            path: "rules/review.md",
            content: .rule(
                name: "Review carefully",
                appliesWhen: "Reviewing changes",
                constraint: "Inspect behavior before style.",
                tags: ["review"]
            )
        )
        XCTAssertEqual(rule.document.title, "Review carefully")
        XCTAssertEqual(rule.document.appliesWhen, "Reviewing changes")
        XCTAssertEqual(rule.document.tags, ["review"])

        let workflow = projectedDraft(
            kind: .workflow,
            path: "workflow/review.md",
            content: .workflow(
                name: "Review",
                description: "Review a change.",
                steps: [
                    .init(ruleId: "rule-1", body: nil),
                    .init(ruleId: nil, body: "Run focused tests."),
                ]
            )
        )
        XCTAssertEqual(workflow.document.title, "Review")
        XCTAssertEqual(workflow.document.steps.count, 2)
        XCTAssertEqual(workflow.document.steps.first?.ruleId, "rule-1")
    }

    func testUserMaintainedMemoryKindsMatchProductModel() {
        XCTAssertEqual(MemoryKind.userMaintainedCases, [.context, .rules, .workflows])
        XCTAssertEqual(MemoryKind.userMaintainedCases.map(\.title), ["Context", "Rules", "Workflow"])
    }

    func testReviewChangeSourcesUseCommitTreeAndDraftOperation() throws {
        let resource = ServerDraftResourceReference(scope: "project", kind: .context, id: "context-1", path: "notes/a.md")
        let detail = ReviewDetail(
            review: ReviewMetadata(
                reviewId: "review-1",
                projectId: "project-1",
                draftId: "draft-1",
                author: user,
                title: "Update note",
                description: "",
                status: "conflicted",
                version: 3,
                decisionBody: nil,
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            draft: ServerDraft(
                draftId: "draft-1",
                projectId: "project-1",
                baseCommitId: "commit-base",
                author: user,
                title: "Update note",
                description: "",
                resource: resource,
                status: "conflicted",
                version: 4,
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            operations: [
                ServerDraftOperation(
                    action: "update",
                    resource: resource,
                    content: .context(content: "Draft body"),
                    newPath: nil,
                    operationId: "operation-1",
                    createdAt: timestamp
                )
            ],
            comments: [],
            conflict: .init(baseCommitId: "commit-base", currentCommitId: "commit-current", detectedAt: timestamp)
        )

        let sources = try WorkspaceLoader.mapReviewChangeSources(
            detail: detail,
            base: commit(id: "commit-base", resource: resource, body: "Base body"),
            current: commit(id: "commit-current", resource: resource, body: "Current body")
        )

        XCTAssertEqual(sources.baseContent, "Base body")
        XCTAssertEqual(sources.currentContent, "Current body")
        XCTAssertEqual(sources.draftContent, "Draft body")
        XCTAssertEqual(sources.resolutionContent, "Draft body")
        XCTAssertTrue(sources.operationLabels.isEmpty)
    }

    func testReviewChangeSourcesPreserveRenameAlongsideContentUpdate() throws {
        let resource = ServerDraftResourceReference(
            scope: "project",
            kind: .context,
            id: "context-1",
            path: "notes/a.md"
        )
        let detail = reviewDetail(
            resource: resource,
            operations: [
                ServerDraftOperation(
                    action: "rename",
                    resource: resource,
                    content: nil,
                    newPath: "notes/b.md",
                    operationId: "operation-1",
                    createdAt: timestamp
                ),
                ServerDraftOperation(
                    action: "update",
                    resource: resource,
                    content: .context(content: "Draft body"),
                    newPath: nil,
                    operationId: "operation-2",
                    createdAt: timestamp
                ),
            ]
        )

        let sources = try WorkspaceLoader.mapReviewChangeSources(
            detail: detail,
            base: commit(id: "commit-base", resource: resource, body: "Base body"),
            current: nil
        )

        XCTAssertEqual(sources.operationLabels, ["Rename to notes/b.md"])
        XCTAssertEqual(sources.draftContent, "Draft body")
    }

    func testStructuredDraftRenderingIncludesRuleMetadata() {
        let content = DaemonDraftContent.rule(
            name: "No compatibility shims",
            appliesWhen: "Changing an internal contract",
            constraint: "Migrate the contract directly.",
            tags: ["coding", "migration"]
        )

        XCTAssertTrue(content.renderedText.contains("# No compatibility shims"))
        XCTAssertTrue(content.renderedText.contains("## Applies when"))
        XCTAssertTrue(content.renderedText.contains("Migrate the contract directly."))
        XCTAssertTrue(content.renderedText.contains("coding, migration"))
    }

    func testReviewLineDiffIdentifiesInsertionsAndRemovals() {
        let lines = ReviewLineDiff.make(base: "one\ntwo", proposed: "one\nthree")

        XCTAssertEqual(lines.map(\.kind), [.context, .removal, .insertion])
        XCTAssertEqual(lines.map(\.text), ["one", "two", "three"])
    }

    func testMarkdownPreviewOnlyAppliesToMarkdownMemory() {
        let markdown = listItem(kind: .context, path: "notes/readme.md")
        let plainText = listItem(kind: .context, path: "notes/readme.txt")
        let rule = listItem(kind: .rules, path: "rules/review.md")

        XCTAssertTrue(markdown.supportsMarkdownPreview)
        XCTAssertFalse(plainText.supportsMarkdownPreview)
        XCTAssertFalse(rule.supportsMarkdownPreview)
    }

    func testLocalWorkbenchTabsAreScopedToTheirProject() {
        let firstProjectTab = WorkbenchTab(
            section: .local,
            projectId: "project-1",
            itemId: "context-1",
            mode: .source,
            title: "Context"
        )
        let secondProjectTab = WorkbenchTab(
            section: .local,
            projectId: "project-2",
            itemId: "context-1",
            mode: .source,
            title: "Context"
        )

        XCTAssertNotEqual(firstProjectTab.id, secondProjectTab.id)
        XCTAssertTrue(firstProjectTab.isVisible(in: .local, projectId: "project-1"))
        XCTAssertFalse(firstProjectTab.isVisible(in: .local, projectId: "project-2"))
        XCTAssertFalse(firstProjectTab.isVisible(in: .hub, projectId: "project-1"))
    }

    func testHubWorkbenchTabsDoNotDependOnTheActiveProject() {
        let tab = WorkbenchTab(
            section: .hub,
            projectId: nil,
            itemId: "rule-1",
            mode: .source,
            title: "Rule"
        )

        XCTAssertTrue(tab.isVisible(in: .hub, projectId: "project-1"))
        XCTAssertTrue(tab.isVisible(in: .hub, projectId: "project-2"))
        XCTAssertFalse(tab.isVisible(in: .local, projectId: "project-1"))
    }

    func testReplacingRulePrimaryTextPreservesStructuredFields() {
        let content = DaemonDraftContent.rule(
            name: "Rule name",
            appliesWhen: "During review",
            constraint: "Old constraint",
            tags: ["review"]
        )

        XCTAssertEqual(
            content.replacingPrimaryText(with: "New constraint"),
            .rule(
                name: "Rule name",
                appliesWhen: "During review",
                constraint: "New constraint",
                tags: ["review"]
            )
        )
    }

    func testSyncToolbarHidesIdleStatus() {
        XCTAssertNil(
            SyncToolbarPresentation.resolve(
                status: syncStatus(),
                isAvailable: true
            )
        )
    }

    func testSyncToolbarShowsPendingWorkAsTransientProgress() {
        XCTAssertEqual(
            SyncToolbarPresentation.resolve(
                status: syncStatus(draftState: "queued", pendingCount: 2),
                isAvailable: true
            ),
            .syncing(changeCount: 2)
        )
    }

    func testSyncToolbarSurfacesCommitChannelFailureWithoutFailedDrafts() {
        XCTAssertEqual(
            SyncToolbarPresentation.resolve(
                status: syncStatus(
                    commitState: "failed",
                    commitError: "The server could not be reached."
                ),
                isAvailable: true
            ),
            .failed(changeCount: 0, message: "The server could not be reached.")
        )
    }

    func testSyncToolbarPrioritizesConflictsOverOtherFailures() {
        XCTAssertEqual(
            SyncToolbarPresentation.resolve(
                status: syncStatus(
                    draftState: "failed",
                    failedCount: 1,
                    conflictCount: 2
                ),
                isAvailable: true
            ),
            .conflicts(count: 2)
        )
    }

    func testSyncToolbarSurfacesUnavailableStatusReader() {
        XCTAssertEqual(
            SyncToolbarPresentation.resolve(status: syncStatus(), isAvailable: false),
            .unavailable(message: nil)
        )
    }

    private func operation(_ value: DaemonDraftOperation, id: String) -> DaemonLocalDraftOperation {
        .init(
            localOperationId: id,
            resourceKind: .context,
            operation: value,
            source: .desktop,
            syncStatus: .queued,
            lastError: nil,
            createdAt: "2026-07-18T00:00:00Z",
            updatedAt: "2026-07-18T00:00:00Z"
        )
    }

    private func syncStatus(
        draftState: String = "idle",
        commitState: String = "idle",
        pendingCount: Int = 0,
        failedCount: Int = 0,
        conflictCount: Int = 0,
        commitError: String? = nil
    ) -> DaemonSyncStatus {
        .init(
            draftSync: syncChannel(state: draftState),
            commitSync: syncChannel(state: commitState, error: commitError),
            pendingOperationCount: pendingCount,
            failedOperationCount: failedCount,
            conflictCount: conflictCount,
            lastSuccessAt: nil
        )
    }

    private func syncChannel(state: String, error: String? = nil) -> DaemonSyncChannelStatus {
        .init(
            state: state,
            serverCursor: nil,
            lastAttemptAt: nil,
            lastSuccessAt: nil,
            lastError: error.map { .init(code: "sync_failed", message: $0, requestId: nil) }
        )
    }

    private func projectedDraft(
        kind: DaemonResourceKind,
        path: String,
        content: DaemonDraftContent
    ) -> LocalDraft {
        let summary = DaemonDraftSummary(
            draftId: "draft-\(kind.rawValue)",
            projectId: "project-1",
            serverDraftId: nil,
            serverVersion: 0,
            baseCommitId: "commit-1",
            scope: .project,
            resourceKind: kind,
            targetId: nil,
            path: path,
            conflict: nil,
            status: .open,
            createdAt: timestamp,
            updatedAt: timestamp,
            pendingOperationCount: 1,
            failedOperationCount: 0
        )
        let operation = DaemonLocalDraftOperation(
            localOperationId: "operation-\(kind.rawValue)",
            resourceKind: kind,
            operation: .create(path: path, content: content, description: nil),
            source: .desktop,
            syncStatus: .synced,
            lastError: nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        return WorkspaceLoader.mapDraft(.init(draft: summary, operations: [operation]), resources: [])
    }

    private func listItem(kind: MemoryKind, path: String) -> MemoryListItem {
        let resource = MemoryResource(
            id: "resource-\(kind.rawValue)-\(path)",
            scope: .project,
            projectId: "project-1",
            projectName: "Project",
            kind: kind,
            contentHash: "hash",
            updatedAt: timestamp,
            refCommitId: "commit-1",
            contentLoaded: true,
            document: .init(
                title: "Readme",
                path: path,
                body: "Body",
                appliesWhen: "",
                tags: [],
                steps: []
            )
        )
        return .init(id: resource.id, resource: resource, draft: nil, inherited: false)
    }

    private func reviewDetail(
        resource: ServerDraftResourceReference,
        operations: [ServerDraftOperation]
    ) -> ReviewDetail {
        .init(
            review: .init(
                reviewId: "review-1",
                projectId: "project-1",
                draftId: "draft-1",
                author: user,
                title: "Update note",
                description: "",
                status: "open",
                version: 1,
                decisionBody: nil,
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            draft: .init(
                draftId: "draft-1",
                projectId: "project-1",
                baseCommitId: "commit-base",
                author: user,
                title: "Update note",
                description: "",
                resource: resource,
                status: "open",
                version: 1,
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            operations: operations,
            comments: [],
            conflict: nil
        )
    }

    private var timestamp: String { "2026-07-18T00:00:00Z" }

    private var user: UserReference {
        .init(userId: "user-1", email: "user@example.com", displayName: "User", avatarUrl: nil, role: "member")
    }

    private func commit(
        id: String,
        resource: ServerDraftResourceReference,
        body: String
    ) -> CommitPayload {
        .init(
            commit: .init(
                commitId: id,
                scope: "project",
                orgId: "org-1",
                projectId: "project-1",
                treeId: "tree-\(id)",
                parentCommitId: nil,
                version: 1,
                createdAt: timestamp
            ),
            tree: .init(
                treeId: "tree-\(id)",
                entries: [
                    .init(
                        id: resource.id ?? "context-1",
                        type: resource.kind,
                        scope: resource.scope,
                        projectId: "project-1",
                        path: resource.path,
                        blobId: "blob-\(id)",
                        source: "project"
                    )
                ]
            ),
            blobs: [.init(blobId: "blob-\(id)", content: body)]
        )
    }
}

private actor RetryingDaemonHealthProbe {
    private var failuresRemaining: Int
    private var attempts = 0
    private let result: DaemonHealth

    init(failuresRemaining: Int, result: DaemonHealth) {
        self.failuresRemaining = failuresRemaining
        self.result = result
    }

    func health(timeout: TimeInterval) throws -> DaemonHealth {
        attempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw DaemonXPCError.requestTimedOut
        }
        return result
    }

    func attemptCount() -> Int {
        attempts
    }
}
