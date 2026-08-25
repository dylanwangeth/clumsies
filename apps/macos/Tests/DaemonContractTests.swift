import XCTest
@testable import Clumsies

final class DaemonContractTests: XCTestCase {
    func testNativeClientUsesClumsiesIdentifierNamespace() {
        XCTAssertEqual(ClumsiesIdentifiers.namespace, "ai.clumsies")
        XCTAssertEqual(DaemonBootstrapController.label, "ai.clumsies.daemon")
        XCTAssertEqual(DaemonXPCClient.serviceName, "ai.clumsies.daemon")
    }

    func testAgentAdapterRequestUsesBundledDaemonRuntimePath() throws {
        let runtime = "/Applications/Clumsies.app/Contents/Resources/clumsiesd"
        let request = DaemonProjectAgentAdapterInstallRequest(
            projectId: "project-1",
            workspaceRoot: "/tmp/repository",
            adapter: .codex,
            runtimeBinaryPath: runtime,
            expectedRevision: nil
        )

        let data = try JSONCoding.encoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["runtime_binary_path"] as? String, runtime)
        XCTAssertTrue((object["runtime_binary_path"] as? String)?.hasSuffix("/clumsiesd") == true)
    }

    func testLegacyAdapterInspectionResponseDecodesDeferredTargets() throws {
        let json = #"{"scanned":3,"deferred":1,"conflicts":[]}"#
        let response = try JSONCoding.decoder().decode(
            DaemonLegacyAgentAdapterInspectionResponse.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(response.scanned, 3)
        XCTAssertEqual(response.deferred, 1)
        XCTAssertTrue(response.conflicts.isEmpty)
    }

    func testWorkspaceStartupPlansEveryReachableAdapterUpgrade() {
        let adapters = [
            DaemonProjectAgentAdapter(
                serverUrl: "https://app.clumsies.ai",
                projectId: "project-2",
                workspaceRoot: "/repos/missing",
                adapter: .opencode,
                revision: 4,
                managedFiles: [],
                createdAt: "2026-08-01T00:00:00Z",
                updatedAt: "2026-08-01T00:00:00Z"
            ),
            DaemonProjectAgentAdapter(
                serverUrl: "https://app.clumsies.ai",
                projectId: "project-1",
                workspaceRoot: "/repos/active",
                adapter: .codex,
                revision: 7,
                managedFiles: [],
                createdAt: "2026-08-01T00:00:00Z",
                updatedAt: "2026-08-01T00:00:00Z"
            ),
            DaemonProjectAgentAdapter(
                serverUrl: "https://app.clumsies.ai",
                projectId: "project-1",
                workspaceRoot: "/repos/active",
                adapter: .claudeCode,
                revision: 3,
                managedFiles: [],
                createdAt: "2026-08-01T00:00:00Z",
                updatedAt: "2026-08-01T00:00:00Z"
            ),
        ]

        let planned = WorkspaceLoader.agentAdapterReconciliationPlan(
            installed: adapters,
            runtimePath: "/Applications/Clumsies.app/Contents/Resources/clumsiesd",
            workspaceExists: { $0 == "/repos/active" }
        )

        XCTAssertEqual(planned.map(\.adapter), [.claudeCode, .codex])
        XCTAssertEqual(planned.map(\.expectedRevision), [3, 7])
        XCTAssertTrue(planned.allSatisfy {
            $0.runtimeBinaryPath == "/Applications/Clumsies.app/Contents/Resources/clumsiesd"
        })
    }

    func testWorkspaceStartupMigratesAdaptersBeforeAuthenticationAndDoesNotReachServer() async {
        actor EventRecorder {
            var events: [String] = []

            func append(_ event: String) {
                events.append(event)
            }
        }

        let recorder = EventRecorder()

        do {
            _ = try await WorkspaceLoader.loadAuthenticatedWorkspaceIdentity(
                reconcileLocalAgentAdapters: {
                    await recorder.append("list-all-native")
                    await recorder.append("install-native")
                    await recorder.append("inspect-legacy")
                    return .init(conflicts: [], inspectionWarning: nil)
                },
                projectConfig: {
                    await recorder.append("project-config")
                    return .init(
                        serverUrl: "https://app.clumsies.ai",
                        projectId: "project-1",
                        hasAccessToken: false,
                        hasRefreshToken: false,
                        ready: false,
                        missingFields: ["access_token", "refresh_token"]
                    )
                },
                retrySync: {
                    await recorder.append("retry-sync")
                },
                currentUser: {
                    await recorder.append("api-v1-me")
                    throw DaemonContractTestError.unexpectedServerRequest
                },
                onLocalAgentAdapters: { _ in
                    await recorder.append("publish-local-warning")
                }
            )
            XCTFail("Expected authenticationRequired")
        } catch WorkspaceLoadError.authenticationRequired {
            // Local discovery and native reconciliation complete before the auth gate.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let events = await recorder.events
        XCTAssertEqual(
            events,
            [
                "list-all-native", "install-native", "inspect-legacy",
                "publish-local-warning", "project-config",
            ]
        )
    }

    func testLegacyAdapterConflictDoesNotBlockAuthenticatedWorkspaceLoading() async throws {
        let conflict = DaemonLegacyAgentAdapterConflict(
            installId: "codex-old",
            adapter: .codex,
            scope: "workspace",
            targetRoot: "/repos/old/.codex",
            code: "legacy_adapter_generation_unsupported",
            message: "This legacy Adapter generation was left unchanged."
        )
        let user = CurrentUserResponse(
            user: .init(
                userId: "user-1",
                email: "user@example.com",
                displayName: nil,
                avatarUrl: nil,
                role: "member"
            ),
            org: .init(orgId: "org-1", name: "Example"),
            projects: [],
            defaultProjectId: nil,
            capabilities: []
        )

        let (_, loadedUser, localResult) = try await WorkspaceLoader.loadAuthenticatedWorkspaceIdentity(
            reconcileLocalAgentAdapters: {
                return .init(conflicts: [conflict], inspectionWarning: nil)
            },
            projectConfig: {
                .init(
                    serverUrl: "https://app.clumsies.ai",
                    projectId: nil,
                    hasAccessToken: true,
                    hasRefreshToken: true,
                    ready: true,
                    missingFields: []
                )
            },
            retrySync: {},
            currentUser: { user }
        )

        XCTAssertEqual(loadedUser.user.userId, "user-1")
        XCTAssertEqual(localResult.conflicts, [conflict])
    }

    func testWarmDaemonRetrySyncDoesNotBlockAuthenticatedIdentityLoad() async throws {
        let retryGate = WarmDaemonRetryGate()
        let retryStarted = expectation(description: "retry sync started")
        let currentUserLoaded = expectation(description: "current user loaded")
        let loadCompleted = expectation(description: "workspace identity load completed")
        let currentUser = CurrentUserResponse(
            user: user,
            org: .init(orgId: "org-1", name: "Example"),
            projects: [],
            defaultProjectId: nil,
            capabilities: []
        )

        let load = Task {
            defer { loadCompleted.fulfill() }
            return try await WorkspaceLoader.loadAuthenticatedWorkspaceIdentity(
                reconcileLocalAgentAdapters: {
                    .init(conflicts: [], inspectionWarning: nil)
                },
                projectConfig: {
                    .init(
                        serverUrl: "https://app.clumsies.ai",
                        projectId: "project-1",
                        hasAccessToken: true,
                        hasRefreshToken: true,
                        ready: true,
                        missingFields: []
                    )
                },
                retrySync: {
                    retryStarted.fulfill()
                    await retryGate.wait()
                },
                currentUser: {
                    currentUserLoaded.fulfill()
                    return currentUser
                }
            )
        }

        await fulfillment(
            of: [retryStarted, currentUserLoaded, loadCompleted],
            timeout: 1
        )
        await retryGate.open()
        let (_, loadedUser, _) = try await load.value

        XCTAssertEqual(loadedUser.user.userId, "user-1")
    }

    @MainActor
    func testLegacyAdapterWarningIsActionableForUserScopeAndInspectionFailure() {
        let conflict = DaemonLegacyAgentAdapterConflict(
            installId: "claude-global",
            adapter: .claudeCode,
            scope: "user",
            targetRoot: "/Users/example",
            code: "legacy_adapter_manual_reinstall_required",
            message: "Remove the global entries, then enable each repository from the App."
        )
        let warning = WorkspaceStore.localAgentAdapterWarning(.init(
            conflicts: [conflict],
            inspectionWarning: "The archived integration store could not be inspected."
        ))

        XCTAssertTrue(warning?.contains("could not be inspected") == true)
        XCTAssertTrue(warning?.contains("Claude Code user integration at /Users/example") == true)
        XCTAssertTrue(warning?.contains("enable each repository") == true)
    }

    func testAppTranslocationIsRejectedBeforeRuntimePathsCanBePersisted() throws {
        XCTAssertThrowsError(try AppBundleRuntimeLocation.requireStable(
            URL(fileURLWithPath: "/private/var/folders/example/AppTranslocation/UUID/d/Clumsies.app")
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("move Clumsies.app"))
            XCTAssertTrue(error.localizedDescription.contains("No daemon"))
        }

        XCTAssertNoThrow(try AppBundleRuntimeLocation.requireStable(
            URL(fileURLWithPath: "/Applications/Clumsies.app")
        ))
        XCTAssertNoThrow(try AppBundleRuntimeLocation.requireStable(
            URL(fileURLWithPath: "/Users/example/Applications/Clumsies.app")
        ))
    }

    func testMacAppBuildEmbedsDaemonWithoutTheArchivedZigClient() throws {
        let macOSRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectYAML = try String(
            contentsOf: macOSRoot.appending(path: "project.yml"),
            encoding: .utf8
        )
        let xcodeProject = try String(
            contentsOf: macOSRoot.appending(path: "Clumsies.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        XCTAssertTrue(projectYAML.contains("name: Embed clumsiesd"))
        XCTAssertFalse(projectYAML.contains("Scripts/embed-client.sh"))
        XCTAssertFalse(projectYAML.contains("name: Embed clumsies\n"))
        XCTAssertTrue(xcodeProject.contains("/* Embed clumsiesd */"))
        XCTAssertFalse(xcodeProject.contains("embed-client.sh"))
        XCTAssertFalse(xcodeProject.contains("/* Embed clumsies */"))
        XCTAssertFalse(xcodeProject.contains("zig build"))
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
            resource: .memory,
            op: .update(
                id: "memory-1",
                content: DaemonDraftContent(
                    description: nil,
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
        XCTAssertEqual(object["resource"] as? String, "memory")
        let operation = try XCTUnwrap(object["op"] as? [String: Any])
        let update = try XCTUnwrap(operation["update"] as? [String: Any])
        let content = try XCTUnwrap(update["content"] as? [String: Any])
        XCTAssertNil(content["kind"])
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
            "evaluation_case_id": null,
            "evaluation_case_status": null
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
          "evidence": [],
          "evidence_suggestions": [],
          "report": null
        }
        """

        let detail = try JSONCoding.decoder().decode(
            RetrievalRunDetail.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(detail.run.status, .succeeded)
        XCTAssertEqual(detail.run.latencies.rerankUs, 70)
        XCTAssertEqual(detail.candidates.first?.kind, .memory)
        XCTAssertEqual(detail.candidates.first?.exclusionReason, .selected)
        XCTAssertEqual(detail.candidates.first?.deltaAction, .add)
    }

    func testEvaluationCaseDetailDecodesAssistedEvidenceReview() throws {
        let json = """
        {
          "evaluation_case": {
            "case_id": "case-1",
            "source_run_id": "run-1",
            "corpus_id": "corpus-1",
            "project_id": "project-1",
            "query": "draft reconciliation",
            "status": "draft",
            "version": 1,
            "created_at": "2026-07-30T00:00:00Z",
            "updated_at": "2026-07-30T00:00:00Z"
          },
          "evidence": [],
          "evidence_suggestions": [{
            "resource_id": "context-1",
            "unit_key": "unit-1",
            "path": "architecture/reconciliation.md",
            "heading_path": ["Draft reconciliation"],
            "evidence_excerpt": "Drafts retain their base commit.",
            "model_relevance": 0.89,
            "likely_failure_stage": "assembly",
            "exclusion_reason": "per_resource_limit"
          }],
          "report": null
        }
        """

        let detail = try JSONCoding.decoder().decode(
            EvaluationCaseDetail.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(detail.evaluationCase.status, .draft)
        XCTAssertEqual(detail.evaluationCase.version, 1)
        XCTAssertEqual(detail.evidenceSuggestions.first?.likelyFailureStage, .assembly)
        XCTAssertEqual(detail.evidenceSuggestions.first?.exclusionReason, .perResourceLimit)
        XCTAssertNil(detail.report)
    }

    func testResolveEvaluationCaseUsesBinaryEvidenceAndOptimisticVersion() throws {
        let request = ResolveEvaluationCaseRequest(
            caseId: "case-1",
            expectedVersion: 4,
            evidence: [
                EvaluationEvidenceInput(resourceId: "context-1", unitKey: "unit-1"),
            ],
            noneMatched: false
        )

        let data = try JSONCoding.encoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["case_id"] as? String, "case-1")
        XCTAssertEqual(object["expected_version"] as? Int, 4)
        XCTAssertEqual(object["none_matched"] as? Bool, false)
        let evidence = try XCTUnwrap(object["evidence"] as? [[String: Any]])
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence[0]["resource_id"] as? String, "context-1")
        XCTAssertEqual(evidence[0]["unit_key"] as? String, "unit-1")
        XCTAssertNil(evidence[0]["relevance"])
        XCTAssertNil(evidence[0]["missed"])
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
            agentRuntime: .init(protocolRevision: 1, buildId: "test-build"),
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
            hasUpstreamResourceChanges: false,
            reconciliation: .unknown,
            reconciliationCandidateId: nil,
            scope: .project,
            resourceKind: .memory,
            targetId: nil,
            path: "notes/old.md",
            status: .open,
            createdAt: "2026-07-18T00:00:00Z",
            updatedAt: "2026-07-18T00:00:00Z",
            pendingOperationCount: 1,
            failedOperationCount: 0
        )
        let operations = [
            operation(.create(path: "notes/old.md", content: .init(description: nil, content: "first"), description: nil), id: "op-1"),
            operation(.update(id: "draft-1", content: .init(description: nil, content: "second"), description: nil), id: "op-2"),
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

    func testDraftInventoryPlanRefreshesFileLevelUpstreamChangeState() {
        let summary = inventorySummary(
            id: "draft-behind",
            hasUpstreamResourceChanges: true,
            updatedAt: "2026-07-23T01:00:00Z"
        )
        let current = inventoryDraft(
            from: inventorySummary(
                id: "draft-behind",
                hasUpstreamResourceChanges: false,
                updatedAt: "2026-07-23T01:00:00Z"
            )
        )

        let plan = WorkspaceStore.draftInventoryPlan(
            summaries: [summary],
            currentDrafts: [current],
            includeFailed: false
        )

        XCTAssertEqual(plan.refreshIds, ["draft-behind"])
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
            hasUpstreamResourceChanges: true,
            reconciliation: .conflicts,
            reconciliationCandidateId: "candidate-1",
            scope: .project,
            resourceKind: .memory,
            targetId: "memory-1",
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
                            id: "memory-1",
                            content: .init(description: nil, content: "Draft body"),
                            description: nil
                        ),
                        id: "operation-1"
                    )
                ]
            ),
            resources: [resource(id: "memory-1", kind: .context, path: "context/guide.md")]
        )

        XCTAssertEqual(draft.baseCommitId, "commit-base")
        XCTAssertEqual(draft.currentCommitId, "commit-current")
        XCTAssertEqual(draft.freshness, .behind)
        XCTAssertTrue(draft.hasUpstreamResourceChanges)
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
            hasUpstreamResourceChanges: true,
            reconciliation: .clean,
            reconciliationCandidateId: "candidate-1",
            scope: .org,
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

    func testReviewRequestUsesRequiredDraftArray() throws {
        let request = CreateReviewRequest(
            drafts: [
                .init(draftId: "draft-1", expectedDraftVersion: 1),
                .init(draftId: "draft-2", expectedDraftVersion: 2),
            ],
            title: "Directory update",
            description: "",
            candidateId: nil,
            resolvedState: nil
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(request))
                as? [String: Any]
        )
        XCTAssertEqual((object["drafts"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(object["draft_id"])
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
        XCTAssertTrue(candidate.hasDraftResultChanges)

        let unchangedCandidate = try JSONCoding.decoder().decode(
            DraftReconciliationCandidate.self,
            from: Data(
                json.replacingOccurrences(
                    of: "\"content\":\"Merged\"",
                    with: "\"content\":\"Draft\""
                ).utf8
            )
        )
        XCTAssertFalse(unchangedCandidate.hasDraftResultChanges)

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
            drafts: [.init(
                draftId: candidate.draftId,
                expectedDraftVersion: candidate.draftVersion
            )],
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
        let submissionDrafts = try XCTUnwrap(submissionObject["drafts"] as? [[String: Any]])
        XCTAssertEqual(submissionDrafts.first?["expected_draft_version"] as? Int, 7)
    }

    func testDraftProjectionPreservesMarkdown() {
        let rule = projectedDraft(
            kind: .memory,
            path: "rules/review.md",
            content: .init(
                description: nil,
                content: "# Review carefully\n\nInspect behavior before style."
            )
        )
        XCTAssertEqual(rule.document.title, "review")
        XCTAssertEqual(rule.document.body, "# Review carefully\n\nInspect behavior before style.")

        let workflow = projectedDraft(
            kind: .memory,
            path: "workflow/review.md",
            content: .init(
                description: nil,
                content: "# Review\n\nReview a change.\n\n- Run focused tests."
            )
        )
        XCTAssertEqual(workflow.document.title, "review")
        XCTAssertEqual(workflow.document.body, "# Review\n\nReview a change.\n\n- Run focused tests.")
    }

    func testUnifiedMemoryKindContractIsSingleValued() throws {
        // MemoryKind keeps the legacy cases as UI-level creation defaults.
        XCTAssertEqual(MemoryKind.allCases, [.context, .rules, .workflows])
        XCTAssertEqual(MemoryKind.allCases.map(\.title), ["Context", "Rules", "Workflow"])

        // The daemon/Server contract is a single Memory kind; legacy values
        // from archived databases and older clients still decode to it.
        XCTAssertEqual(DaemonResourceKind.memory.rawValue, "memory")
        for legacy in ["context", "rule", "workflow"] {
            let decoded = try JSONCoding.decoder().decode(
                DaemonResourceKind.self,
                from: Data("\"\(legacy)\"".utf8)
            )
            XCTAssertEqual(decoded, .memory)
        }
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
                    resourceKind: .memory,
                    projectId: "project-1",
                    path: "rules/review.md",
                    contentHash: "sha256:rule",
                    content: .init(
                        description: nil,
                        content: "# Review carefully\n\nInspect behavior before style."
                    )
                ),
                .init(
                    resourceId: "context-org",
                    scope: .org,
                    resourceKind: .memory,
                    projectId: nil,
                    path: "context/shared.md",
                    contentHash: "sha256:context",
                    content: .init(description: nil, content: "Shared context")
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

    func testReviewCommentContractCarriesVersionAndAnchor() throws {
        let request = CreateReviewCommentRequest(
            body: "Please tighten this sentence.",
            expectedReviewVersion: 7,
            anchorPath: "notes/a.md",
            anchorLine: 12
        )
        let requestData = try JSONCoding.encoder().encode(request)
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )

        XCTAssertEqual(requestObject["body"] as? String, "Please tighten this sentence.")
        XCTAssertEqual(requestObject["expected_review_version"] as? Int, 7)
        XCTAssertEqual(requestObject["anchor_path"] as? String, "notes/a.md")
        XCTAssertEqual(requestObject["anchor_line"] as? Int, 12)

        let response = """
        {
          "comment_id": "comment-1",
          "review_id": "review-1",
          "author": {
            "user_id": "reviewer-1",
            "email": "reviewer@example.com",
            "display_name": "Reviewer",
            "avatar_url": null,
            "role": "member"
          },
          "body": "Please tighten this sentence.",
          "anchor_path": "notes/a.md",
          "anchor_line": 12,
          "review_version": 8,
          "created_at": "2026-08-06T01:00:00Z"
        }
        """
        let comment = try JSONCoding.decoder().decode(
            ReviewComment.self,
            from: Data(response.utf8)
        )

        XCTAssertEqual(comment.anchorPath, "notes/a.md")
        XCTAssertEqual(comment.anchorLine, 12)
        XCTAssertEqual(comment.reviewVersion, 8)
    }

    func testReviewMetadataDecodesLegacyPayloadWithoutDecisionAuditFields() throws {
        let json = """
        {
          "review_id": "review-legacy",
          "project_id": "project-1",
          "draft_id": "draft-1",
          "author": {
            "user_id": "author-1",
            "email": "author@example.com",
            "display_name": null,
            "avatar_url": null,
            "role": "member"
          },
          "title": "Legacy review",
          "description": "Created before decision audit metadata.",
          "status": "approved",
          "version": 2,
          "decision_body": "Looks good.",
          "approved_result_hash": "sha256:approved",
          "coordination": {
            "freshness": "current",
            "current_commit_id": "commit-1",
            "has_upstream_resource_changes": false,
            "reconciliation": "clean",
            "candidate_id": null
          },
          "created_at": "2026-08-05T00:00:00Z",
          "updated_at": "2026-08-05T01:00:00Z"
        }
        """

        let metadata = try JSONCoding.decoder().decode(
            ReviewMetadata.self,
            from: Data(json.utf8)
        )
        let record = WorkspaceLoader.mapReview(metadata)

        XCTAssertNil(metadata.decidedBy)
        XCTAssertNil(metadata.decidedAt)
        XCTAssertNil(record.decidedBy)
        XCTAssertNil(record.decidedAt)
    }

    func testReviewChangeSourcesUseCommitTreeAndDraftOperation() throws {
        let resource = ServerDraftResourceReference(scope: "project", id: "context-1", path: "notes/a.md")
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
                decidedBy: nil,
                decidedAt: nil,
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
                    content: .init(description: nil, content: "Draft body"),
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
        XCTAssertEqual(sources.proposedPath, "notes/a.md")
        XCTAssertTrue(sources.operationLabels.isEmpty)
        let mapped = WorkspaceLoader.mapReview(detail)
        XCTAssertEqual(mapped.freshness, .behind)
        XCTAssertEqual(mapped.reconciliation, .conflicts)
        XCTAssertEqual(mapped.currentCommitId, "commit-current")
    }

    func testReviewChangeSourcesPreserveRenameAlongsideContentUpdate() throws {
        let resource = ServerDraftResourceReference(
            scope: "project",
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
                    content: .init(description: nil, content: "Draft body"),
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
        XCTAssertEqual(sources.proposedPath, "notes/b.md")
    }

    func testMemoryDraftRenderingPreservesMarkdown() {
        let content = DaemonDraftContent(
            description: nil,
            content: "# No compatibility shims\n\nMigrate the contract directly."
        )

        XCTAssertEqual(
            content.renderedText,
            "# No compatibility shims\n\nMigrate the contract directly."
        )
    }

    func testReviewListMetadataMapsWithoutLoadingReviewDetail() throws {
        let metadata = ReviewMetadata(
            reviewId: "review-1",
            projectId: "project-1",
            draftId: "draft-1",
            author: UserReference(
                userId: "user-1",
                email: "dylan@example.com",
                displayName: "Dylan",
                avatarUrl: nil,
                role: "owner"
            ),
            title: "Split diff UI example",
            description: "Review the proposed memory change.",
            status: "open",
            version: 1,
            decisionBody: nil,
            approvedResultHash: nil,
            decidedBy: UserReference(
                userId: "reviewer-1",
                email: "reviewer@example.com",
                displayName: "Reviewer",
                avatarUrl: nil,
                role: "member"
            ),
            decidedAt: "2026-08-06T01:00:00Z",
            coordination: DraftCoordination(
                freshness: .current,
                currentCommitId: "commit-1",
                hasUpstreamResourceChanges: false,
                reconciliation: .unknown,
                candidateId: nil
            ),
            createdAt: "2026-08-06T00:00:00Z",
            updatedAt: "2026-08-06T00:00:00Z"
        )

        let review = WorkspaceLoader.mapReview(metadata)

        XCTAssertEqual(review.id, "review-1")
        XCTAssertEqual(review.title, "Split diff UI example")
        XCTAssertEqual(review.freshness, .current)
        XCTAssertEqual(review.currentCommitId, "commit-1")
        XCTAssertEqual(review.decidedBy?.userId, "reviewer-1")
        XCTAssertEqual(review.decidedBy?.displayName, "Reviewer")
        XCTAssertEqual(review.decidedAt, "2026-08-06T01:00:00Z")

        let encoded = try JSONCoding.encoder().encode(metadata)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let decidedBy = try XCTUnwrap(object["decided_by"] as? [String: Any])
        XCTAssertEqual(decidedBy["user_id"] as? String, "reviewer-1")
        XCTAssertEqual(object["decided_at"] as? String, "2026-08-06T01:00:00Z")

        let decoded = try JSONCoding.decoder().decode(ReviewMetadata.self, from: encoded)
        XCTAssertEqual(decoded.decidedBy?.displayName, "Reviewer")
        XCTAssertEqual(decoded.decidedAt, "2026-08-06T01:00:00Z")
    }

    func testCommitPayloadDecodesInternalProjectSelectionTreeEntry() throws {
        let json = """
        {
          "commit": {
            "commit_id": "commit-1",
            "scope": "project",
            "org_id": "org-1",
            "project_id": "project-1",
            "tree_id": "tree-1",
            "parent_commit_id": null,
            "version": 1,
            "created_at": "2026-07-16T11:42:58.008401Z"
          },
          "tree": {
            "tree_id": "tree-1",
            "entries": [{
              "id": "project_org_selection:project-1",
              "type": "project_org_selection",
              "scope": "daemon",
              "project_id": "project-1",
              "path": null,
              "blob_id": "blob-1",
              "source": "config"
            }]
          },
          "blobs": [{
            "blob_id": "blob-1",
            "content": "{\\"project_id\\":\\"project-1\\",\\"rules\\":[],\\"context\\":[],\\"workflows\\":[],\\"revision\\":0}"
          }]
        }
        """

        let payload = try JSONCoding.decoder().decode(CommitPayload.self, from: Data(json.utf8))

        XCTAssertEqual(payload.tree.entries.first?.type, .projectOrgSelection)
    }

    func testServerDecodeFailureIncludesRequestAndCodingPath() {
        struct MissingValue: Decodable {
            let value: String
        }

        do {
            _ = try JSONCoding.decoder().decode(MissingValue.self, from: Data("{}".utf8))
            XCTFail("Expected decoding to fail")
        } catch {
            let message = ServerClient.decodingFailureMessage(
                error,
                method: "GET",
                path: "/api/v1/example",
                responseType: MissingValue.self
            )
            XCTAssertTrue(message.contains("GET /api/v1/example"))
            XCTAssertTrue(message.contains("MissingValue"))
            XCTAssertTrue(message.contains("value"))
        }
    }

    func testReviewCommentPlacementKeepsCurrentFileThreadsOnTheirExactLine() {
        let author = UserReference(
            userId: "reviewer-1",
            email: "reviewer@example.com",
            displayName: "Reviewer",
            avatarUrl: nil,
            role: "member"
        )
        func comment(
            _ id: String,
            path: String?,
            line: Int?,
            version: Int = 3
        ) -> ReviewComment {
            ReviewComment(
                commentId: id,
                reviewId: "review-1",
                author: author,
                body: id,
                createdAt: "2026-08-11T00:00:00Z",
                anchorPath: path,
                anchorLine: line,
                reviewVersion: version
            )
        }
        let general = comment("general", path: nil, line: nil)
        let inline = comment("inline", path: "context/review.md", line: 7)
        let priorPath = comment("prior", path: "context/old-review.md", line: 7)
        let priorVersion = comment(
            "prior-version",
            path: "context/review.md",
            line: 7,
            version: 2
        )
        let missingLine = comment("missing-line", path: "context/review.md", line: 99)

        let placement = ReviewCommentPlacement.resolve(
            comments: [general, inline, priorPath, priorVersion, missingLine],
            activePath: "context/review.md",
            renderableLines: [7, 8],
            minimumInlineVersion: 3
        )

        XCTAssertEqual(placement.general.map(\.id), ["general"])
        XCTAssertEqual(placement.byLine[7]?.map(\.id), ["inline"])
        XCTAssertEqual(
            placement.unplaced.map(\.id),
            ["prior", "prior-version", "missing-line"]
        )
        XCTAssertNil(placement.byLine[1])
    }

    func testReviewCommentPlacementAccountsForDecisionOnlyVersionChanges() {
        XCTAssertEqual(
            ReviewCommentPlacement.minimumInlineVersion(reviewVersion: 4, status: "open"),
            4
        )
        XCTAssertEqual(
            ReviewCommentPlacement.minimumInlineVersion(reviewVersion: 4, status: "approved"),
            3
        )
        XCTAssertEqual(
            ReviewCommentPlacement.minimumInlineVersion(reviewVersion: 4, status: "rejected"),
            3
        )
        XCTAssertEqual(
            ReviewCommentPlacement.minimumInlineVersion(reviewVersion: 5, status: "merged"),
            3
        )
    }

    func testUnifiedDiffRevealsUnchangedContextContainingAnchoredComments() {
        let content = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let model = SplitDiffModel.make(original: content, modified: content)

        XCTAssertTrue(UnifiedDiffPresentation(model: model).blocks.isEmpty)

        let presentation = UnifiedDiffPresentation(
            model: model,
            anchoredLines: [8]
        )
        let anchoredLine = presentation.blocks
            .flatMap(\.lines)
            .first { $0.commentAnchorLine == 8 }

        XCTAssertNotNil(anchoredLine)
        XCTAssertTrue(presentation.blocks.contains { block in
            guard case .hunk = block.kind else { return false }
            return block.lines.contains { $0.commentAnchorLine == 8 }
        })
    }

    func testUnifiedDiffSplitsLargeOmissionAroundAnchoredComment() throws {
        let originalLines = (1...50).map { "line \($0)" }
        var modifiedLines = originalLines
        modifiedLines[1] = "changed line 2"
        let model = SplitDiffModel.make(
            original: originalLines.joined(separator: "\n"),
            modified: modifiedLines.joined(separator: "\n")
        )

        let presentation = UnifiedDiffPresentation(
            model: model,
            anchoredLines: [40]
        )
        let commentHunk = try XCTUnwrap(presentation.blocks.first { block in
            guard case .hunk = block.kind else { return false }
            return block.lines.contains { $0.commentAnchorLine == 40 }
        })

        XCTAssertLessThanOrEqual(commentHunk.lines.count, 7)
        XCTAssertFalse(presentation.blocks.contains { block in
            guard case .omission = block.kind else { return false }
            return block.lines.contains { $0.commentAnchorLine == 40 }
        })
    }

    func testSplitDiffAlignsReplacementRows() {
        let model = SplitDiffModel.make(original: "one\ntwo", modified: "one\nthree")

        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.rows[0].original?.kind, .context)
        XCTAssertEqual(model.rows[0].modified?.kind, .context)
        XCTAssertEqual(model.rows[1].original?.kind, .removal)
        XCTAssertEqual(model.rows[1].modified?.kind, .insertion)
        XCTAssertEqual(model.rows[1].original?.text, "two")
        XCTAssertEqual(model.rows[1].modified?.text, "three")
        XCTAssertEqual(model.rows[1].original?.lineNumber, 2)
        XCTAssertEqual(model.rows[1].modified?.lineNumber, 2)
    }

    func testUnifiedDiffExpandsReplacementIntoRemovalAndInsertion() {
        let model = SplitDiffModel.make(original: "one\ntwo", modified: "one\nthree")
        let presentation = UnifiedDiffPresentation(model: model)
        let changed = presentation.blocks
            .flatMap(\.lines)
            .filter { $0.kind != .context }

        XCTAssertEqual(changed.map(\.kind), [.removal, .insertion])
        XCTAssertEqual(changed.map(\.text), ["two", "three"])
        XCTAssertEqual(changed[0].oldLineNumber, 2)
        XCTAssertNil(changed[0].commentAnchorLine)
        XCTAssertEqual(changed[1].newLineNumber, 2)
        XCTAssertEqual(changed[1].commentAnchorLine, 2)
    }

    func testUnifiedDiffKeepsDistantContextInCollapsedOmissionBlock() {
        let original = (1...20).map { "line \($0)" }.joined(separator: "\n")
        var modifiedLines = (1...20).map { "line \($0)" }
        modifiedLines[1] = "changed 2"
        modifiedLines[18] = "changed 19"

        let presentation = UnifiedDiffPresentation(model: SplitDiffModel.make(
            original: original,
            modified: modifiedLines.joined(separator: "\n")
        ))

        XCTAssertEqual(presentation.blocks.count, 3)
        XCTAssertEqual(presentation.blocks[1].kind, .omission)
        XCTAssertGreaterThan(presentation.blocks[1].lines.count, 0)
    }

    func testSplitDiffTreatsEmptyContentAsNoLines() {
        let empty = SplitDiffModel.make(original: "", modified: "")
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertTrue(empty.blocks.isEmpty)

        let created = SplitDiffModel.make(original: "", modified: "created")
        XCTAssertEqual(created.rows.count, 1)
        XCTAssertNil(created.rows[0].original)
        XCTAssertEqual(created.rows[0].modified?.kind, .insertion)
        XCTAssertEqual(created.rows[0].modified?.lineNumber, 1)
    }

    func testSplitDiffCollapsesUnchangedLinesBetweenDistantHunks() {
        let original = (1...20).map { "line \($0)" }.joined(separator: "\n")
        var modifiedLines = (1...20).map { "line \($0)" }
        modifiedLines[1] = "changed 2"
        modifiedLines[18] = "changed 19"

        let model = SplitDiffModel.make(
            original: original,
            modified: modifiedLines.joined(separator: "\n")
        )

        XCTAssertEqual(model.blocks.count, 3)
        guard case .hunk = model.blocks[0].kind else {
            return XCTFail("Expected the first diff block to be a hunk")
        }
        XCTAssertEqual(model.blocks[1].kind, .omission)
        guard case .hunk = model.blocks[2].kind else {
            return XCTFail("Expected the last diff block to be a hunk")
        }
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

    func testProjectWorkbenchTabsAreScopedToTheirProject() {
        let firstProjectTab = WorkbenchTab(
            section: .memory,
            projectId: "project-1",
            itemId: "context-1",
            mode: .source,
            title: "Context"
        )
        let secondProjectTab = WorkbenchTab(
            section: .memory,
            projectId: "project-2",
            itemId: "context-1",
            mode: .source,
            title: "Context"
        )

        XCTAssertNotEqual(firstProjectTab.id, secondProjectTab.id)
        XCTAssertTrue(firstProjectTab.isVisible(in: .memory, projectId: "project-1"))
        XCTAssertFalse(firstProjectTab.isVisible(in: .memory, projectId: "project-2"))
    }

    func testOrgAuthorityWorkbenchTabStaysInOrgViewContext() {
        let tab = WorkbenchTab(
            section: .memory,
            projectId: nil,
            itemId: "rule-1",
            mode: .source,
            title: "Rule"
        )

        XCTAssertTrue(tab.isVisible(in: .memory, projectId: nil))
        XCTAssertFalse(tab.isVisible(in: .memory, projectId: "project-1"))
        XCTAssertFalse(tab.isVisible(in: .memory, projectId: "project-2"))
    }

    func testReplacingMemoryPrimaryTextReplacesMarkdown() {
        let content = DaemonDraftContent(
            description: nil,
            content: "# Rule name\n\nOld content"
        )

        XCTAssertEqual(
            content.replacingPrimaryText(with: "# Rule name\n\nNew content"),
            .init(description: nil, content: "# Rule name\n\nNew content")
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
            resourceKind: .memory,
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
        hasUpstreamResourceChanges: Bool = false,
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
            hasUpstreamResourceChanges: hasUpstreamResourceChanges,
            reconciliation: .unknown,
            reconciliationCandidateId: nil,
            scope: .project,
            resourceKind: .memory,
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
            hasUpstreamResourceChanges: summary.hasUpstreamResourceChanges,
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
            hasUpstreamResourceChanges: false,
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
                decidedBy: nil,
                decidedAt: nil,
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
        hasUpstreamResourceChanges: Bool = false,
        reconciliation: DraftReconciliationStatus = .unknown,
        candidateId: String? = nil
    ) -> DraftCoordination {
        .init(
            freshness: freshness,
            currentCommitId: currentCommitId,
            hasUpstreamResourceChanges: hasUpstreamResourceChanges,
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
                        type: .memory,
                        scope: resource.scope,
                        projectId: "project-1",
                        path: resource.path,
                        blobId: "blob-\(id)",
                        source: "project",
                        description: nil
                    )
                ]
            ),
            blobs: [.init(blobId: "blob-\(id)", content: body)]
        )
    }
}

private enum DaemonContractTestError: Error {
    case unexpectedServerRequest
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
            throw DaemonXPCError.requestTimedOut()
        }
        return result
    }

    func attemptCount() -> Int {
        attempts
    }
}

private actor WarmDaemonRetryGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
