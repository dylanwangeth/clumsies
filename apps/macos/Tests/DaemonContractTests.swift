import XCTest
@testable import Clumsies

final class DaemonContractTests: XCTestCase {
    func testNativeClientUsesClumsiesIdentifierNamespace() {
        XCTAssertEqual(ClumsiesIdentifiers.namespace, "ai.clumsies")
        XCTAssertEqual(DaemonBootstrapController.label, "ai.clumsies.daemon")
        XCTAssertEqual(DaemonXPCClient.serviceName, "ai.clumsies.daemon")
    }

    func testBootstrapControllerDecodesCanonicalDaemonStatus() throws {
        let json = """
        {
          "installed": true,
          "runtime": {
            "installed": true,
            "bootstrapped": true,
            "running": true,
            "pid": 4242,
            "state": "running",
            "last_exit_code": null,
            "last_error": null
          }
        }
        """

        let state = try DaemonBootstrapController.decodeState(Data(json.utf8))

        XCTAssertEqual(
            state,
            DaemonBootstrapState(installed: true, running: true, pid: 4242, error: nil)
        )
    }

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
                    content: "# No compatibility shims\n\nMigrate the contract directly."
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
        XCTAssertEqual(
            content["content"] as? String,
            "# No compatibility shims\n\nMigrate the contract directly."
        )
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

    func testProjectStorageDecodesDaemonResponse() throws {
        let json = """
        {
          "authority_key": "https://app.clumsies.ai",
          "project_id": "project-1",
          "mode": "custom",
          "selected_root_path": "/Volumes/Memory",
          "managed_root_path": "/Volumes/Memory/.clumsies/cache-v1/hash/project-1",
          "active_generation_path": null,
          "search_index_path": "/Volumes/Memory/.clumsies/cache-v1/hash/project-1/search/index.sqlite",
          "availability": "moving",
          "location_revision": 4,
          "size_bytes": 4096,
          "active_move_id": "move-1",
          "issue_code": null,
          "diagnostic": null
        }
        """

        let storage = try JSONCoding.decoder().decode(
            DaemonProjectStorage.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(storage.mode, .custom)
        XCTAssertEqual(storage.availability, .moving)
        XCTAssertEqual(storage.locationRevision, 4)
        XCTAssertEqual(storage.activeMoveId, "move-1")
    }

    func testRetrievalRunDetailDecodesDaemonTrace() throws {
        let json = """
        {
          "run": {
            "run_id": "run-1",
            "project_id": "project-1",
            "query": "draft reconciliation",
            "activation_state_fingerprint": "sha256:state",
            "status": "succeeded",
            "effective_hash": "sha256:effective",
            "index_revision": "revision-1",
            "resource_count": 3,
            "unit_count": 8,
            "parser_version": "markdown-v1",
            "chunker_version": "section-v1",
            "model_revision": "models-v1",
            "ranking_profile": "hybrid-v1",
            "latencies": {
              "effective_memory_us": 10,
              "index_ensure_us": 20,
              "bm25_us": 30,
              "embedding_us": 40,
              "vector_us": 50,
              "rrf_us": 60,
              "rerank_us": 70,
              "assembly_us": 80,
              "persistence_us": 90,
              "total_us": 360
            },
            "returned_fragment_count": 1,
            "returned_token_count": 120,
            "error_stage": null,
            "error_code": null,
            "error_summary": null,
            "created_at": "2026-07-23T00:00:00Z",
            "completed_at": "2026-07-23T00:00:01Z",
            "evaluation_case_id": null
          },
          "candidates": [{
            "unit_key": "unit-1",
            "resource_id": "context-1",
            "scope": "project",
            "kind": "context",
            "path": "architecture/reconciliation.md",
            "heading_path": ["Draft reconciliation"],
            "locator": {
              "type": "markdown_span",
              "start_byte": 0,
              "end_byte": 120,
              "heading_path": ["Draft reconciliation"]
            },
            "content_hash": "sha256:content",
            "resource_content_hash": "sha256:resource",
            "token_count": 120,
            "evidence_excerpt": "Drafts retain their base commit.",
            "exact_rank": 1,
            "bm25_rank": 1,
            "bm25_score": 7.5,
            "vector_rank": 2,
            "vector_score": 0.88,
            "rrf_rank": 1,
            "rrf_score": 0.03,
            "reranker_rank": 1,
            "reranker_logit": 2.1,
            "reranker_relevance": 0.89,
            "final_rank": 1,
            "selected": true,
            "exclusion_reason": "selected",
            "delta_action": "add"
          }],
          "evaluation_case": null,
          "judgments": [],
          "corpus_resources": [],
          "report": null
        }
        """

        let detail = try JSONCoding.decoder().decode(
            RetrievalRunDetail.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(detail.run.status, .succeeded)
        XCTAssertEqual(detail.run.latencies.rerankUs, 70)
        XCTAssertEqual(detail.candidates.first?.kind, .context)
        XCTAssertEqual(detail.candidates.first?.exclusionReason, .selected)
        XCTAssertEqual(detail.candidates.first?.deltaAction, .add)
    }

    func testProjectStorageHandoffBookmarkRoundTripUsesTheSelectedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clumsies-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bookmark = try directory.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )

        XCTAssertFalse(stale)
        XCTAssertEqual(
            resolved.resolvingSymlinksInPath().path,
            directory.resolvingSymlinksInPath().path
        )
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
            currentCommitId: "commit-1",
            freshness: .current,
            reconciliation: .unknown,
            reconciliationCandidateId: nil,
            scope: .project,
            resourceKind: .context,
            targetId: nil,
            path: "notes/old.md",
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

    func testDeletionDraftDoesNotOfferMarkdownPreview() {
        let summary = inventorySummary(id: "draft-delete", updatedAt: timestamp)
        var draft = inventoryDraft(from: summary)
        draft.isDeletion = true
        let item = MemoryListItem(
            id: draft.id,
            resource: nil,
            draft: draft,
            inherited: false
        )

        XCTAssertFalse(item.supportsMarkdownPreview)
    }

    func testDraftInventoryPlanDiscoversExternalDraftChanges() {
        let unchanged = inventorySummary(id: "draft-unchanged", updatedAt: "2026-07-23T01:00:00Z")
        let external = inventorySummary(id: "draft-external", updatedAt: "2026-07-23T02:00:00Z")
        let updated = inventorySummary(id: "draft-updated", updatedAt: "2026-07-23T03:00:00Z")
        let queued = inventorySummary(id: "draft-queued", updatedAt: "2026-07-23T04:00:00Z")
        let terminal = inventorySummary(
            id: "draft-terminal",
            status: .merged,
            updatedAt: "2026-07-23T05:00:00Z"
        )
        let currentDrafts = [
            inventoryDraft(from: unchanged),
            inventoryDraft(
                from: inventorySummary(id: updated.draftId, updatedAt: "2026-07-23T02:30:00Z")
            ),
            inventoryDraft(from: queued, syncStatus: .queued),
            inventoryDraft(from: terminal, status: .open),
        ]

        let plan = WorkspaceStore.draftInventoryPlan(
            summaries: [unchanged, external, updated, queued, terminal],
            currentDrafts: currentDrafts,
            includeFailed: false
        )

        XCTAssertEqual(plan.refreshIds, ["draft-external", "draft-updated", "draft-queued"])
        XCTAssertEqual(plan.terminalIds, ["draft-terminal"])
    }

    func testBehindDraftProjectionPreservesCoordinationWithoutChangingTheBase() {
        let summary = DaemonDraftSummary(
            draftId: "draft-behind",
            projectId: "project-1",
            serverDraftId: "server-draft-1",
            serverVersion: 7,
            baseCommitId: "commit-base",
            currentCommitId: "commit-current",
            freshness: .behind,
            reconciliation: .conflicts,
            reconciliationCandidateId: "candidate-1",
            scope: .project,
            resourceKind: .context,
            targetId: "context-1",
            path: "context/guide.md",
            status: .submitted,
            createdAt: timestamp,
            updatedAt: timestamp,
            pendingOperationCount: 0,
            failedOperationCount: 0
        )
        let draft = WorkspaceLoader.mapDraft(
            .init(
                draft: summary,
                operations: [
                    operation(
                        .update(
                            id: "context-1",
                            content: .context(content: "Draft body"),
                            description: nil
                        ),
                        id: "operation-1"
                    )
                ]
            ),
            resources: [resource(id: "context-1", kind: .context, path: "context/guide.md")]
        )

        XCTAssertEqual(draft.baseCommitId, "commit-base")
        XCTAssertEqual(draft.currentCommitId, "commit-current")
        XCTAssertEqual(draft.freshness, .behind)
        XCTAssertEqual(draft.reconciliation, .conflicts)
        XCTAssertEqual(draft.reconciliationCandidateId, "candidate-1")
        XCTAssertEqual(draft.document.body, "Draft body")
        XCTAssertEqual(draft.status, .submitted)
    }

    @MainActor
    func testRequestReviewRejectsBehindDraftBeforeCallingTheServer() async {
        let store = WorkspaceStore()
        let draft = LocalDraft(
            id: "draft-behind",
            projectId: "project-1",
            serverId: "server-draft-1",
            serverVersion: 7,
            baseCommitId: "commit-base",
            currentCommitId: "commit-current",
            freshness: .behind,
            reconciliation: .clean,
            reconciliationCandidateId: "candidate-1",
            scope: .project,
            kind: .context,
            targetId: "context-1",
            status: .open,
            origin: .desktop,
            syncStatus: .synced,
            updatedAt: timestamp,
            document: .init(title: "Guide", path: "context/guide.md", body: "Draft body"),
            isDeletion: false
        )

        do {
            try await store.requestReview(for: draft, title: "Guide", description: "")
            XCTFail("behind Draft must be reconciled before Review creation")
        } catch ReviewRequestError.reconciliationRequired {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testReconciliationCandidateAndRebaseWireContract() throws {
        let json = """
        {
          "candidate_id": "candidate-1",
          "draft_id": "draft-1",
          "draft_version": 7,
          "base_commit_id": "commit-base",
          "current_commit_id": "commit-current",
          "status": "clean",
          "base_state": {
            "exists": true,
            "resource": {"scope":"project","kind":"context","id":"context-1","path":"context/guide.md"},
            "content": {"kind":"context","content":"Base"}
          },
          "current_state": {
            "exists": true,
            "resource": {"scope":"project","kind":"context","id":"context-1","path":"context/guide.md"},
            "content": {"kind":"context","content":"Current"}
          },
          "draft_state": {
            "exists": true,
            "resource": {"scope":"project","kind":"context","id":"context-1","path":"context/guide.md"},
            "content": {"kind":"context","content":"Draft"}
          },
          "proposed_state": {
            "exists": true,
            "resource": {"scope":"project","kind":"context","id":"context-1","path":"context/guide.md"},
            "content": {"kind":"context","content":"Merged"}
          },
          "conflicts": [],
          "result_hash": "sha256:result",
          "valid": true,
          "created_at": "2026-07-22T00:00:00Z",
          "invalidated_at": null
        }
        """
        let candidate = try JSONCoding.decoder().decode(
            DraftReconciliationCandidate.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(candidate.status, .clean)
        XCTAssertEqual(candidate.baseCommitId, "commit-base")
        XCTAssertEqual(candidate.currentCommitId, "commit-current")
        XCTAssertEqual(candidate.proposedState?.content?.primaryText, "Merged")

        let request = CreateDraftRebaseRequest(
            candidateId: candidate.candidateId,
            expectedDraftVersion: candidate.draftVersion,
            resolvedState: nil
        )
        let encoded = try JSONCoding.encoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["candidate_id"] as? String, "candidate-1")
        XCTAssertEqual(object["expected_draft_version"] as? Int, 7)
        XCTAssertNil(object["resolved_state"])

        let submission = CreateReviewSubmissionRequest(
            expectedReviewVersion: 4,
            expectedDraftVersion: candidate.draftVersion,
            title: "Guide",
            description: "",
            candidateId: candidate.candidateId,
            resolvedState: nil
        )
        let submissionData = try JSONCoding.encoder().encode(submission)
        let submissionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: submissionData) as? [String: Any]
        )
        XCTAssertEqual(submissionObject["candidate_id"] as? String, "candidate-1")
        XCTAssertEqual(submissionObject["expected_review_version"] as? Int, 4)
        XCTAssertEqual(submissionObject["expected_draft_version"] as? Int, 7)
    }

    func testDraftProjectionPreservesRuleAndWorkflowMarkdown() {
        let rule = projectedDraft(
            kind: .rule,
            path: "rules/review.md",
            content: .rule(
                content: "# Review carefully\n\nInspect behavior before style."
            )
        )
        XCTAssertEqual(rule.document.title, "review")
        XCTAssertEqual(rule.document.body, "# Review carefully\n\nInspect behavior before style.")

        let workflow = projectedDraft(
            kind: .workflow,
            path: "workflow/review.md",
            content: .workflow(content: "# Review\n\nReview a change.\n\n- Run focused tests.")
        )
        XCTAssertEqual(workflow.document.title, "review")
        XCTAssertEqual(workflow.document.body, "# Review\n\nReview a change.\n\n- Run focused tests.")
    }

    func testUserMaintainedMemoryKindsMatchProductModel() {
        XCTAssertEqual(MemoryKind.allCases, [.context, .rules, .workflows])
        XCTAssertEqual(MemoryKind.allCases.map(\.title), ["Context", "Rules", "Workflow"])
    }

    func testCachedProjectCheckoutHydratesProjectMemoryWithoutInheritedDuplicates() {
        let checkout = DaemonProjectCheckout(
            projectId: "project-1",
            commitId: "commit-1",
            refEtag: "\"commit-1\"",
            commitCreatedAt: timestamp,
            orgSelectionRevision: 3,
            selectedOrgResourceIds: ["context-org"],
            resources: [
                .init(
                    resourceId: "rule-project",
                    scope: .project,
                    resourceKind: .rule,
                    projectId: "project-1",
                    path: "rules/review.md",
                    contentHash: "sha256:rule",
                    content: .rule(
                        content: "# Review carefully\n\nInspect behavior before style."
                    )
                ),
                .init(
                    resourceId: "context-org",
                    scope: .org,
                    resourceKind: .context,
                    projectId: nil,
                    path: "context/shared.md",
                    contentHash: "sha256:context",
                    content: .context(content: "Shared context")
                ),
            ],
            ready: true
        )

        let loaded = WorkspaceLoader.mapProjectCheckout(checkout, projectName: "Clumsies")

        XCTAssertEqual(loaded.state.refCommitId, "commit-1")
        XCTAssertEqual(loaded.state.refEtag, "\"commit-1\"")
        XCTAssertEqual(loaded.state.orgSelectionRevision, 3)
        XCTAssertEqual(loaded.state.selectedOrgResourceIds, ["context-org"])
        XCTAssertEqual(loaded.resources.count, 1)
        XCTAssertEqual(loaded.resources[0].document.title, "review")
        XCTAssertEqual(
            loaded.resources[0].document.body,
            "# Review carefully\n\nInspect behavior before style."
        )
        XCTAssertTrue(loaded.resources[0].contentLoaded)
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
                status: "approved",
                version: 3,
                decisionBody: nil,
                approvedResultHash: nil,
                coordination: coordination(
                    freshness: .behind,
                    currentCommitId: "commit-current",
                    reconciliation: .conflicts
                ),
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
                status: "submitted",
                coordination: coordination(
                    freshness: .behind,
                    currentCommitId: "commit-current",
                    reconciliation: .conflicts
                ),
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
            comments: []
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
        let mapped = WorkspaceLoader.mapReview(detail)
        XCTAssertEqual(mapped.freshness, .behind)
        XCTAssertEqual(mapped.reconciliation, .conflicts)
        XCTAssertEqual(mapped.currentCommitId, "commit-current")
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

    func testRuleDraftRenderingPreservesMarkdown() {
        let content = DaemonDraftContent.rule(
            content: "# No compatibility shims\n\nMigrate the contract directly."
        )

        XCTAssertEqual(
            content.renderedText,
            "# No compatibility shims\n\nMigrate the contract directly."
        )
    }

    func testReviewLineDiffIdentifiesInsertionsAndRemovals() {
        let lines = ReviewLineDiff.make(base: "one\ntwo", proposed: "one\nthree")

        XCTAssertEqual(lines.map(\.kind), [.context, .removal, .insertion])
        XCTAssertEqual(lines.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(lines.map(\.oldLineNumber), [1, 2, nil])
        XCTAssertEqual(lines.map(\.newLineNumber), [1, nil, 2])
    }

    func testReviewLineDiffTreatsEmptyContentAsNoLines() {
        XCTAssertTrue(ReviewLineDiff.make(base: "", proposed: "").isEmpty)

        let lines = ReviewLineDiff.make(base: "", proposed: "created")
        XCTAssertEqual(lines.map(\.kind), [.insertion])
        XCTAssertEqual(lines.map(\.oldLineNumber), [nil])
        XCTAssertEqual(lines.map(\.newLineNumber), [1])
    }

    func testMarkdownPreviewAppliesToMarkdownContextAndStructuredMemory() {
        let markdown = listItem(kind: .context, path: "notes/readme.md")
        let plainText = listItem(kind: .context, path: "notes/readme.txt")
        let rule = listItem(kind: .rules, path: "rules/review.md")
        let workflow = listItem(kind: .workflows, path: "workflow/review.md")

        XCTAssertTrue(markdown.supportsMarkdownPreview)
        XCTAssertFalse(plainText.supportsMarkdownPreview)
        XCTAssertTrue(rule.supportsMarkdownPreview)
        XCTAssertTrue(workflow.supportsMarkdownPreview)
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

    func testReplacingRulePrimaryTextReplacesMarkdown() {
        let content = DaemonDraftContent.rule(
            content: "# Rule name\n\nOld content"
        )

        XCTAssertEqual(
            content.replacingPrimaryText(with: "# Rule name\n\nNew content"),
            .rule(content: "# Rule name\n\nNew content")
        )
    }

    func testSyncToolbarHidesIdleStatus() {
        XCTAssertNil(
            SyncToolbarPresentation.resolve(
                status: syncStatus(),
                isAvailable: true,
                serverDataSource: "live"
            )
        )
    }

    func testSyncToolbarShowsPendingWorkAsTransientProgress() {
        XCTAssertEqual(
            SyncToolbarPresentation.resolve(
                status: syncStatus(draftState: "queued", pendingCount: 2),
                isAvailable: true,
                serverDataSource: "live"
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
                isAvailable: true,
                serverDataSource: "live"
            ),
            .unavailable(message: "The server could not be reached.")
        )
    }

    func testSyncToolbarHidesCommitBackgroundRefresh() {
        XCTAssertNil(
            SyncToolbarPresentation.resolve(
                status: syncStatus(commitState: "syncing"),
                isAvailable: true,
                serverDataSource: "live"
            )
        )
    }

    func testSyncToolbarDoesNotTreatReconciliationAsTransportFailure() {
        XCTAssertNil(
            SyncToolbarPresentation.resolve(
                status: syncStatus(reconciliationConflictCount: 2),
                isAvailable: true,
                serverDataSource: "live"
            )
        )
    }

    func testSyncToolbarSurfacesUnavailableStatusReader() {
        XCTAssertEqual(
            SyncToolbarPresentation.resolve(
                status: syncStatus(),
                isAvailable: false,
                serverDataSource: "stale"
            ),
            .unavailable(message: nil)
        )
    }

    func testSyncToolbarSurfacesCachedServerDataWhenSyncIsIdle() {
        XCTAssertEqual(
            SyncToolbarPresentation.resolve(
                status: syncStatus(),
                isAvailable: true,
                serverDataSource: "stale"
            ),
            .stale
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
        behindDraftCount: Int = 0,
        reconciliationConflictCount: Int = 0,
        commitError: String? = nil
    ) -> DaemonSyncStatus {
        .init(
            draftSync: syncChannel(state: draftState),
            commitSync: syncChannel(state: commitState, error: commitError),
            pendingOperationCount: pendingCount,
            failedOperationCount: failedCount,
            behindDraftCount: behindDraftCount,
            reconciliationConflictCount: reconciliationConflictCount,
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

    private func inventorySummary(
        id: String,
        status: DaemonLocalDraftStatus = .open,
        updatedAt: String
    ) -> DaemonDraftSummary {
        .init(
            draftId: id,
            projectId: "project-1",
            serverDraftId: "server-\(id)",
            serverVersion: 1,
            baseCommitId: "commit-1",
            currentCommitId: "commit-1",
            freshness: .current,
            reconciliation: .unknown,
            reconciliationCandidateId: nil,
            scope: .project,
            resourceKind: .rule,
            targetId: nil,
            path: "rules/\(id).md",
            status: status,
            createdAt: "2026-07-23T00:00:00Z",
            updatedAt: updatedAt,
            pendingOperationCount: 0,
            failedOperationCount: 0
        )
    }

    private func inventoryDraft(
        from summary: DaemonDraftSummary,
        status: DaemonLocalDraftStatus? = nil,
        syncStatus: DaemonDraftSyncState = .synced
    ) -> LocalDraft {
        .init(
            id: summary.draftId,
            projectId: summary.projectId,
            serverId: summary.serverDraftId,
            serverVersion: summary.serverVersion,
            baseCommitId: summary.baseCommitId,
            currentCommitId: summary.currentCommitId,
            freshness: summary.freshness,
            reconciliation: summary.reconciliation,
            reconciliationCandidateId: summary.reconciliationCandidateId,
            scope: .project,
            kind: .rules,
            targetId: summary.targetId,
            status: status ?? summary.status,
            origin: .mcpStore,
            syncStatus: syncStatus,
            updatedAt: summary.updatedAt,
            document: .init(
                title: summary.draftId,
                path: summary.path ?? "",
                body: "Draft body"
            ),
            isDeletion: false
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
            currentCommitId: "commit-1",
            freshness: .current,
            reconciliation: .unknown,
            reconciliationCandidateId: nil,
            scope: .project,
            resourceKind: kind,
            targetId: nil,
            path: path,
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
                body: "Body"
            )
        )
        return .init(id: resource.id, resource: resource, draft: nil, inherited: false)
    }

    private func resource(id: String, kind: MemoryKind, path: String) -> MemoryResource {
        .init(
            id: id,
            scope: .project,
            projectId: "project-1",
            projectName: "Project",
            kind: kind,
            contentHash: "hash",
            updatedAt: timestamp,
            refCommitId: "commit-base",
            contentLoaded: true,
            document: .init(title: "Guide", path: path, body: "Base body")
        )
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
                approvedResultHash: nil,
                coordination: coordination(),
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
                coordination: coordination(),
                version: 1,
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            operations: operations,
            comments: []
        )
    }

    private func coordination(
        freshness: DraftFreshness = .current,
        currentCommitId: String? = "commit-base",
        reconciliation: DraftReconciliationStatus = .unknown,
        candidateId: String? = nil
    ) -> DraftCoordination {
        .init(
            freshness: freshness,
            currentCommitId: currentCommitId,
            reconciliation: reconciliation,
            candidateId: candidateId
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
