import XCTest
@testable import Clumsies

final class IssueBoardContractTests: XCTestCase {
    func testListRequestUsesDaemonWireKeys() throws {
        let data = try JSONCoding.encoder().encode(
            IssueBoardListRequest(projectId: "project-1")
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["project_id"] as? String, "project-1")
        XCTAssertNil(object["projectId"])
    }

    func testDetailRequestUsesDaemonWireKeys() throws {
        let data = try JSONCoding.encoder().encode(
            IssueDetailRequest(projectId: "project-1", issueNumber: 7)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["project_id"] as? String, "project-1")
        XCTAssertEqual(object["issue_number"] as? Int, 7)
        XCTAssertNil(object["issueNumber"])
    }

    func testIssueGateUsesExplicitDaemonWireAction() throws {
        let data = try JSONCoding.encoder().encode(
            ApplyIssueGateRequest(
                projectId: "project-1",
                issueNumber: 7,
                expectedRevision: 4,
                action: .approveClosure
            )
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["project_id"] as? String, "project-1")
        XCTAssertEqual(object["issue_number"] as? Int, 7)
        XCTAssertEqual(object["expected_revision"] as? Int, 4)
        XCTAssertEqual(object["action"] as? String, "approve_closure")
    }

    func testIssueRemovalUsesExplicitDaemonWireAction() throws {
        let data = try JSONCoding.encoder().encode(
            RemoveIssueRequest(
                projectId: "project-1",
                issueNumber: 7,
                expectedRevision: 4,
                action: .archive
            )
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["project_id"] as? String, "project-1")
        XCTAssertEqual(object["issue_number"] as? Int, 7)
        XCTAssertEqual(object["expected_revision"] as? Int, 4)
        XCTAssertEqual(object["action"] as? String, "archive")
    }

    func testIssueBoardDecodesDaemonProjection() throws {
        let json = """
        {
          "project_id": "project-1",
          "effective_hash": "sha256:effective",
          "issues": [{
            "issue_id": "issue_0123456789abcdef0123456789abcdef",
            "project_id": "project-1",
            "issue_number": 7,
            "issue_key": "ISSUE-007",
            "resource_id": "draft-7",
            "path": "issues/open/007_native_issue_board.md",
            "lifecycle": "open",
            "title": "原生 Issue board with a deliberately long mixed-language title",
            "description": "A native description available to both the board and Agent.",
            "external_references": [{
              "kind": "issue",
              "url": "https://github.com/clumsies/非常长的仓库名称/issues/321?source=看板&token=abcdefghijklmnopqrstuvwxyz"
            }, {
              "kind": "pull_request",
              "url": "https://github.com/clumsies/clumsies/pull/987654321?diff=split"
            }],
            "found_at": null,
            "created_at": "2026-08-05T23:00:00Z",
            "started_at": "2026-08-06T01:00:00Z",
            "closed_at": null,
            "archived_at": null,
            "content_hash": "sha256:issue",
            "source_commit_id": null,
            "draft_id": "draft-7",
            "draft_revision": "sha256:draft-overlay",
            "board_state": "in_progress",
            "state_revision": 3,
            "state_updated_at": "2026-08-06T01:00:00Z",
            "closure_summary": null,
            "is_stale": false,
            "active_runs": [{
              "run_id": "run-1",
              "project_id": "project-1",
              "issue_number": 7,
              "host": "codex",
              "host_run_key": "turn-1",
              "host_session_id": "session-1",
              "parent_run_id": null,
              "kind": "root",
              "phase": "running",
              "outcome": null,
              "end_reason": null,
              "display_label": "Implement board",
              "summary": null,
              "revision": 2,
              "started_at": "2026-08-06T01:00:00Z",
              "last_seen_at": "2026-08-06T01:00:01Z",
              "lease_expires_at": "2026-08-06T01:05:01Z",
              "ended_at": null
            }],
            "latest_run": {
              "run_id": "run-1",
              "project_id": "project-1",
              "issue_number": 7,
              "host": "codex",
              "host_run_key": "turn-1",
              "host_session_id": "session-1",
              "parent_run_id": null,
              "kind": "root",
              "phase": "running",
              "outcome": null,
              "end_reason": null,
              "display_label": "Implement board",
              "summary": null,
              "revision": 2,
              "started_at": "2026-08-06T01:00:00Z",
              "last_seen_at": "2026-08-06T01:00:01Z",
              "lease_expires_at": "2026-08-06T01:05:01Z",
              "ended_at": null
            }
          }],
          "unlinked_runs": [{
            "run_id": "run-2",
            "project_id": "project-1",
            "issue_number": null,
            "host": "claude-code",
            "host_run_key": "agent-2",
            "host_session_id": "session-2",
            "parent_run_id": "run-root",
            "kind": "subagent",
            "phase": "ended",
            "outcome": "unknown",
            "end_reason": "lease_expired",
            "display_label": null,
            "summary": null,
            "revision": 4,
            "started_at": "2026-08-06T00:00:00Z",
            "last_seen_at": "2026-08-06T00:01:00Z",
            "lease_expires_at": "2026-08-06T00:02:00Z",
            "ended_at": "2026-08-06T00:02:00Z"
          }],
          "diagnostics": [{
            "resource_id": "context-8",
            "path": "issues/open/not-an-issue.md",
            "code": "malformed_path",
            "message": "Issue path does not contain a three-digit number."
          }]
        }
        """

        let response = try JSONCoding.decoder().decode(
            IssueBoardResponse.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(response.projectId, "project-1")
        XCTAssertEqual(response.effectiveHash, "sha256:effective")
        XCTAssertEqual(response.issues.first?.issueId, "issue_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(response.issues.first?.id, "issue_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(response.issues.first?.boardState, .inProgress)
        XCTAssertEqual(
            response.issues.first?.description,
            "A native description available to both the board and Agent."
        )
        XCTAssertEqual(
            response.issues.first?.externalReferences,
            [
                IssueExternalReference(
                    kind: .issue,
                    url: "https://github.com/clumsies/非常长的仓库名称/issues/321?source=看板&token=abcdefghijklmnopqrstuvwxyz"
                ),
                IssueExternalReference(
                    kind: .pullRequest,
                    url: "https://github.com/clumsies/clumsies/pull/987654321?diff=split"
                ),
            ]
        )
        XCTAssertEqual(response.issues.first?.stateRevision, 3)
        XCTAssertEqual(response.issues.first?.createdAt, "2026-08-05T23:00:00Z")
        XCTAssertEqual(response.issues.first?.startedAt, "2026-08-06T01:00:00Z")
        XCTAssertNil(response.issues.first?.closedAt)
        XCTAssertEqual(response.issues.first?.isStale, false)
        XCTAssertEqual(response.issues.first?.activeRuns.first?.host, .codex)
        XCTAssertEqual(response.unlinkedRuns.first?.host, .claudeCode)
        XCTAssertEqual(response.unlinkedRuns.first?.kind, .subagent)
        XCTAssertEqual(response.unlinkedRuns.first?.parentRunId, "run-root")
        XCTAssertEqual(response.diagnostics.first?.code, .malformedPath)
    }

    func testExternalReferenceWireContractSupportsBothKindsAndEmptyArrays() throws {
        let references = ExternalReferencesEnvelope(
            externalReferences: [
                IssueExternalReference(kind: .issue, url: "https://example.com/issues/问题-123"),
                IssueExternalReference(
                    kind: .pullRequest,
                    url: "https://example.com/pulls/456"
                ),
            ]
        )
        let data = try JSONCoding.encoder().encode(references)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let encodedReferences = try XCTUnwrap(
            object["external_references"] as? [[String: String]]
        )

        XCTAssertEqual(encodedReferences.map { $0["kind"] }, ["issue", "pull_request"])
        XCTAssertEqual(
            try JSONCoding.decoder().decode(
                ExternalReferencesEnvelope.self,
                from: Data(#"{"external_references":[]}"#.utf8)
            ).externalReferences,
            []
        )
    }

    func testIssueBoardCardDefaultsOmittedExternalReferencesToEmpty() throws {
        let json = """
        {
          "issue_id": "issue_0123456789abcdef0123456789abcdef",
          "project_id": "project-1",
          "issue_number": 7,
          "issue_key": "ISSUE-007",
          "resource_id": "issue_0123456789abcdef0123456789abcdef",
          "path": "",
          "lifecycle": "open",
          "title": "Compatible native Issue",
          "description": "Created before external references were introduced.",
          "found_at": "2026-08-05T23:00:00Z",
          "created_at": "2026-08-05T23:00:00Z",
          "started_at": null,
          "closed_at": null,
          "archived_at": null,
          "content_hash": "native:1",
          "source_commit_id": null,
          "draft_id": null,
          "draft_revision": null,
          "board_state": "todo",
          "state_revision": 1,
          "state_updated_at": "2026-08-05T23:00:00Z",
          "closure_summary": null,
          "is_stale": false,
          "active_runs": [],
          "latest_run": null
        }
        """

        let issue = try JSONCoding.decoder().decode(
            IssueBoardCard.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(issue.externalReferences, [])
    }

    func testIssueBoardCardDecodesBlockedDependenciesAndBlockingFacts() throws {
        let json = """
        {
          "issue_id": "issue_0123456789abcdef0123456789abcdef",
          "project_id": "project-1",
          "issue_number": 7,
          "issue_key": "ISSUE-007",
          "resource_id": "issue_0123456789abcdef0123456789abcdef",
          "path": "",
          "lifecycle": "open",
          "title": "Depends on ISSUE-003",
          "description": "Waiting for a prerequisite.",
          "found_at": "2026-08-05T23:00:00Z",
          "created_at": "2026-08-05T23:00:00Z",
          "started_at": null,
          "closed_at": null,
          "archived_at": null,
          "content_hash": "native:1",
          "source_commit_id": null,
          "draft_id": null,
          "draft_revision": null,
          "board_state": "todo",
          "state_revision": 1,
          "state_updated_at": "2026-08-05T23:00:00Z",
          "closure_summary": null,
          "is_stale": false,
          "blocked": true,
          "blocking_reasons": [
            {
              "kind": "dependency",
              "issue_key": "ISSUE-003",
              "title": "Prerequisite",
              "board_state": "in_progress"
            },
            {
              "kind": "fact",
              "fact_id": "host:zed-hooks",
              "description": "Zed does not provide lifecycle hooks yet"
            }
          ],
          "dependencies": [
            {
              "issue_key": "ISSUE-003",
              "title": "Prerequisite",
              "board_state": "in_progress"
            }
          ],
          "blocking_facts": [
            {
              "fact_id": "host:zed-hooks",
              "kind": "host_capability",
              "value": "hooks",
              "description": "Zed does not provide lifecycle hooks yet",
              "satisfied": false
            }
          ],
          "active_runs": [],
          "latest_run": null
        }
        """

        let issue = try JSONCoding.decoder().decode(
            IssueBoardCard.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(issue.blocked)
        XCTAssertEqual(issue.dependencies.map(\.issueKey), ["ISSUE-003"])
        XCTAssertEqual(issue.blockingReasons.count, 2)
        XCTAssertEqual(issue.blockingReasons[0].kind, .dependency)
        XCTAssertEqual(issue.blockingReasons[1].kind, .fact)
        XCTAssertEqual(issue.blockingFacts[0].factId, "host:zed-hooks")
        XCTAssertEqual(issue.blockingFacts[0].kind, .hostCapability)
        XCTAssertFalse(issue.blockingFacts[0].satisfied)
    }
}

@MainActor
final class IssueBoardModelTests: XCTestCase {
    func testRefreshFailurePreservesLastSuccessfulBoard() async {
        let response = makeBoardResponse(projectId: "project-1")
        let loader = IssueBoardLoaderScript(response: response, failsAfterCall: 1)
        let model = IssueBoardModel { projectId in
            try await loader.load(projectId: projectId)
        }

        await model.loadOnce(projectId: "project-1")
        XCTAssertEqual(model.response, response)
        XCTAssertNil(model.refreshError)

        await model.refresh()

        XCTAssertEqual(model.response, response)
        XCTAssertEqual(model.refreshError, "The test daemon is unavailable.")
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isRefreshing)
    }

    func testChangingProjectsDoesNotRetainThePreviousProjectsBoard() async {
        let response = makeBoardResponse(projectId: "project-1")
        let loader = IssueBoardLoaderScript(response: response, failsAfterCall: 1)
        let model = IssueBoardModel { projectId in
            try await loader.load(projectId: projectId)
        }

        await model.loadOnce(projectId: "project-1")
        await model.loadOnce(projectId: "project-2")

        XCTAssertEqual(model.projectId, "project-2")
        XCTAssertNil(model.response)
        XCTAssertEqual(model.refreshError, "The test daemon is unavailable.")
    }

    func testLatePreviousProjectResponseCannotReplaceTheCurrentBoard() async throws {
        let previousResponse = makeBoardResponse(projectId: "project-1")
        let currentResponse = makeBoardResponse(projectId: "project-2")
        let model = IssueBoardModel { projectId in
            if projectId == "project-1" {
                try await Task.sleep(for: .milliseconds(80))
                return previousResponse
            }
            try await Task.sleep(for: .milliseconds(5))
            return currentResponse
        }

        let previousLoad = Task {
            await model.loadOnce(projectId: "project-1")
        }
        try await Task.sleep(for: .milliseconds(10))
        let currentLoad = Task {
            await model.loadOnce(projectId: "project-2")
        }

        await currentLoad.value
        await previousLoad.value

        XCTAssertEqual(model.projectId, "project-2")
        XCTAssertEqual(model.response, currentResponse)
        XCTAssertNil(model.refreshError)
    }

    func testPollingStopsWhenItsTaskIsCancelled() async throws {
        let response = makeBoardResponse(projectId: "project-1")
        let loader = IssueBoardLoaderScript(response: response)
        let model = IssueBoardModel { projectId in
            try await loader.load(projectId: projectId)
        }
        let polling = Task {
            await model.poll(projectId: "project-1", interval: .milliseconds(20))
        }

        for _ in 0..<100 {
            if await loader.callCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let countBeforeCancellation = await loader.callCount
        XCTAssertGreaterThanOrEqual(countBeforeCancellation, 2)

        polling.cancel()
        await polling.value
        let countAfterCancellation = await loader.callCount
        try await Task.sleep(for: .milliseconds(60))
        let finalCount = await loader.callCount

        XCTAssertEqual(finalCount, countAfterCancellation)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isRefreshing)
    }

    func testStaleInProgressIssuesBucketIntoTheAbandonedColumn() async {
        let response = makeBoardResponse(projectId: "project-1", isStale: true)
        let model = IssueBoardModel { _ in response }
        await model.loadOnce(projectId: "project-1")

        XCTAssertTrue(model.issues(in: .inProgress).isEmpty)
        XCTAssertEqual(model.abandonedIssues.count, 1)
        XCTAssertEqual(model.abandonedIssues.first?.issueNumber, 1)
        model.showsStaleOnly = true
        XCTAssertTrue(model.issues(in: .inProgress).isEmpty)
        XCTAssertEqual(model.abandonedIssues.count, 1)
        XCTAssertTrue(model.issues(in: .todo).isEmpty)
    }

    func testBlockedFilterShowsOnlyIssuesWithUnresolvedDependenciesOrFacts() async {
        let blockedIssue = makeIssue(
            projectId: "project-1",
            issueNumber: 1
        )
        let unblockedIssue = makeIssue(
            projectId: "project-1",
            issueNumber: 2
        )
        let response = IssueBoardResponse(
            projectId: "project-1",
            effectiveHash: "sha256:effective",
            issues: [
                IssueBoardCard(
                    issueId: blockedIssue.issueId,
                    projectId: blockedIssue.projectId,
                    issueNumber: blockedIssue.issueNumber,
                    issueKey: blockedIssue.issueKey,
                    resourceId: blockedIssue.resourceId,
                    path: blockedIssue.path,
                    lifecycle: blockedIssue.lifecycle,
                    title: blockedIssue.title,
                    description: blockedIssue.description,
                    descriptionExcerpt: blockedIssue.descriptionExcerpt,
                    externalReferences: [],
                    foundAt: blockedIssue.foundAt,
                    createdAt: blockedIssue.createdAt,
                    startedAt: blockedIssue.startedAt,
                    closedAt: blockedIssue.closedAt,
                    archivedAt: blockedIssue.archivedAt,
                    contentHash: blockedIssue.contentHash,
                    sourceCommitId: blockedIssue.sourceCommitId,
                    draftId: blockedIssue.draftId,
                    draftRevision: blockedIssue.draftRevision,
                    boardState: .todo,
                    stateRevision: blockedIssue.stateRevision,
                    stateUpdatedAt: blockedIssue.stateUpdatedAt,
                    closureSummary: blockedIssue.closureSummary,
                    isStale: false,
                    blocked: true,
                    blockingReasons: [
                        IssueBlockingReason(
                            kind: .dependency,
                            issueKey: "ISSUE-003",
                            title: "Prerequisite",
                            boardState: .inProgress,
                            factId: nil,
                            description: nil
                        ),
                    ],
                    dependencies: [
                        IssueDependencyState(
                            issueKey: "ISSUE-003",
                            title: "Prerequisite",
                            boardState: .inProgress
                        ),
                    ],
                    blockingFacts: [],
                    activeRuns: [],
                    latestRun: nil,
                    changedByRunId: nil,
                    verificationLevel: .agentSelf,
                    verificationSteps: [],
                    stateEvents: []
                ),
                unblockedIssue,
            ],
            unlinkedRuns: [],
            diagnostics: []
        )
        let model = IssueBoardModel { _ in response }
        await model.loadOnce(projectId: "project-1")

        XCTAssertEqual(model.issues(in: .todo).map(\.issueNumber), [1])
        XCTAssertEqual(model.issues(in: .inProgress).map(\.issueNumber), [2])
        model.showsBlockedOnly = true
        XCTAssertEqual(model.issues(in: .todo).map(\.issueNumber), [1])
        XCTAssertTrue(model.issues(in: .inProgress).isEmpty)
    }

    func testExternalReferenceFiltersComposeAndIgnoreEmptyReferences() async {
        let externalIssue = IssueExternalReference(
            kind: .issue,
            url: "https://github.com/clumsies/clumsies/issues/11"
        )
        let pullRequest = IssueExternalReference(
            kind: .pullRequest,
            url: "https://github.com/clumsies/clumsies/pull/12"
        )
        let response = IssueBoardResponse(
            projectId: "project-1",
            effectiveHash: "sha256:effective",
            issues: [
                makeIssue(
                    projectId: "project-1",
                    issueNumber: 1,
                    externalReferences: [externalIssue]
                ),
                makeIssue(
                    projectId: "project-1",
                    issueNumber: 2,
                    externalReferences: [pullRequest]
                ),
                makeIssue(
                    projectId: "project-1",
                    issueNumber: 3,
                    externalReferences: [externalIssue, pullRequest]
                ),
                makeIssue(
                    projectId: "project-1",
                    issueNumber: 4,
                    externalReferences: []
                ),
            ],
            unlinkedRuns: [],
            diagnostics: []
        )
        let model = IssueBoardModel { _ in response }
        await model.loadOnce(projectId: "project-1")

        XCTAssertEqual(model.issues(in: .inProgress).map(\.issueNumber), [1, 2, 3, 4])

        model.showsExternalIssuesOnly = true
        XCTAssertEqual(model.issues(in: .inProgress).map(\.issueNumber), [1, 3])

        model.showsPullRequestsOnly = true
        XCTAssertEqual(model.issues(in: .inProgress).map(\.issueNumber), [3])
        XCTAssertTrue(model.hasExternalReferenceFilters)

        model.showsExternalIssuesOnly = false
        XCTAssertEqual(model.issues(in: .inProgress).map(\.issueNumber), [2, 3])

        model.clearExternalReferenceFilters()
        XCTAssertEqual(model.issues(in: .inProgress).map(\.issueNumber), [1, 2, 3, 4])
        XCTAssertFalse(model.hasExternalReferenceFilters)
    }

    func testExternalReferenceAndStaleFiltersRemainOrthogonal() async {
        let externalIssue = IssueExternalReference(
            kind: .issue,
            url: "https://example.com/issues/需要修复-11"
        )
        let response = IssueBoardResponse(
            projectId: "project-1",
            effectiveHash: "sha256:effective",
            issues: [
                makeIssue(
                    projectId: "project-1",
                    issueNumber: 1,
                    isStale: true,
                    externalReferences: [externalIssue]
                ),
                makeIssue(
                    projectId: "project-1",
                    issueNumber: 2,
                    isStale: false,
                    externalReferences: [externalIssue]
                ),
                makeIssue(
                    projectId: "project-1",
                    issueNumber: 3,
                    isStale: true,
                    externalReferences: []
                ),
            ],
            unlinkedRuns: [],
            diagnostics: []
        )
        let model = IssueBoardModel { _ in response }
        await model.loadOnce(projectId: "project-1")

        model.showsStaleOnly = true
        model.showsExternalIssuesOnly = true

        XCTAssertTrue(model.issues(in: .inProgress).isEmpty)
        XCTAssertEqual(model.abandonedIssues.map(\.issueNumber), [1])
    }

    func testIssueDetailLoadsOnDemandAndIsCachedByContentHash() async throws {
        let response = makeBoardResponse(projectId: "project-1")
        let issue = try XCTUnwrap(response.issues.first)
        let detailLoader = IssueDetailLoaderScript(
            response: IssueDetailResponse(
                issue: issue,
                body: "Full details",
                acceptanceCriteria: ["The board is native"]
            )
        )
        let model = IssueBoardModel(
            loader: { _ in response },
            detailLoader: { projectId, issueNumber in
                try await detailLoader.load(projectId: projectId, issueNumber: issueNumber)
            }
        )
        await model.loadOnce(projectId: "project-1")

        await model.loadDetail(issue)
        await model.loadDetail(issue)
        let detailCallCount = await detailLoader.callCount

        XCTAssertEqual(model.detail(for: issue)?.body, "Full details")
        XCTAssertEqual(model.detail(for: issue)?.acceptanceCriteria, ["The board is native"])
        XCTAssertEqual(detailCallCount, 1)
        XCTAssertFalse(model.isLoadingDetail(for: issue))
        XCTAssertNil(model.detailError(for: issue))
    }

    func testSearchFiltersIssuesByKeyNumberTitleAndDescription() async {
        let response = IssueBoardResponse(
            projectId: "project-1",
            effectiveHash: "sha256:effective",
            issues: [
                makeIssue(
                    projectId: "project-1",
                    issueNumber: 7,
                    title: "Native Issue board",
                    description: "A board rendered from native Issues."
                ),
                makeIssue(
                    projectId: "project-1",
                    issueNumber: 42,
                    title: "Sync reliability",
                    description: "Retry syncs when the daemon is unavailable."
                ),
                makeIssue(
                    projectId: "project-1",
                    issueNumber: 43,
                    title: "Page search independence",
                    description: "Each page searches only its own domain."
                ),
            ],
            unlinkedRuns: [],
            diagnostics: []
        )
        let model = IssueBoardModel { _ in response }
        await model.loadOnce(projectId: "project-1")

        model.searchQuery = "ISSUE-042"
        XCTAssertEqual(model.matchingIssues.map(\.issueNumber), [42])

        model.searchQuery = "board"
        XCTAssertEqual(model.matchingIssues.map(\.issueNumber), [7])

        model.searchQuery = "43"
        XCTAssertEqual(model.matchingIssues.map(\.issueNumber), [43])

        model.searchQuery = "own domain"
        XCTAssertEqual(model.matchingIssues.map(\.issueNumber), [43])

        model.searchQuery = "   "
        XCTAssertEqual(model.matchingIssues.map(\.issueNumber), [7, 42, 43])
    }

    func testSearchComposesWithStateAndToggleFilters() async {
        let matching = makeIssue(
            projectId: "project-1",
            issueNumber: 1,
            title: "Searchable blocked stale board issue"
        )
        let response = IssueBoardResponse(
            projectId: "project-1",
            effectiveHash: "sha256:effective",
            issues: [
                IssueBoardCard(
                    issueId: matching.issueId,
                    projectId: matching.projectId,
                    issueNumber: matching.issueNumber,
                    issueKey: matching.issueKey,
                    resourceId: matching.resourceId,
                    path: matching.path,
                    lifecycle: matching.lifecycle,
                    title: matching.title,
                    description: matching.description,
                    descriptionExcerpt: matching.descriptionExcerpt,
                    externalReferences: [],
                    foundAt: matching.foundAt,
                    createdAt: matching.createdAt,
                    startedAt: matching.startedAt,
                    closedAt: matching.closedAt,
                    archivedAt: matching.archivedAt,
                    contentHash: matching.contentHash,
                    sourceCommitId: matching.sourceCommitId,
                    draftId: matching.draftId,
                    draftRevision: matching.draftRevision,
                    boardState: .todo,
                    stateRevision: matching.stateRevision,
                    stateUpdatedAt: matching.stateUpdatedAt,
                    closureSummary: matching.closureSummary,
                    isStale: true,
                    blocked: true,
                    blockingReasons: [],
                    dependencies: [],
                    blockingFacts: [],
                    activeRuns: [],
                    latestRun: nil,
                    changedByRunId: nil,
                    verificationLevel: .agentSelf,
                    verificationSteps: [],
                    stateEvents: []
                ),
                makeIssue(
                    projectId: "project-1",
                    issueNumber: 2,
                    title: "Searchable healthy issue"
                ),
                makeIssue(
                    projectId: "project-1",
                    issueNumber: 3,
                    title: "Unrelated issue"
                ),
            ],
            unlinkedRuns: [],
            diagnostics: []
        )
        let model = IssueBoardModel { _ in response }
        await model.loadOnce(projectId: "project-1")

        model.searchQuery = "searchable"
        XCTAssertEqual(model.matchingIssues.map(\.issueNumber), [1, 2])
        XCTAssertEqual(model.issues(in: .todo).map(\.issueNumber), [1])
        XCTAssertEqual(model.issues(in: .inProgress).map(\.issueNumber), [2])
        XCTAssertTrue(model.issues(in: .done).isEmpty)

        model.showsStaleOnly = true
        XCTAssertEqual(model.issues(in: .todo).map(\.issueNumber), [1])
        XCTAssertTrue(model.issues(in: .inProgress).isEmpty)

        model.showsBlockedOnly = true
        XCTAssertEqual(model.issues(in: .todo).map(\.issueNumber), [1])
    }

    private func makeBoardResponse(
        projectId: String,
        isStale: Bool = false,
        externalReferences: [IssueExternalReference] = []
    ) -> IssueBoardResponse {
        let issue = makeIssue(
            projectId: projectId,
            isStale: isStale,
            externalReferences: externalReferences
        )
        return IssueBoardResponse(
            projectId: projectId,
            effectiveHash: "sha256:effective",
            issues: [issue],
            unlinkedRuns: [],
            diagnostics: []
        )
    }

    private func makeIssue(
        projectId: String,
        issueNumber: Int = 1,
        isStale: Bool = false,
        externalReferences: [IssueExternalReference] = [],
        title: String? = nil,
        description: String? = nil
    ) -> IssueBoardCard {
        let resolvedTitle = title ?? "Issue board \(issueNumber)"
        let resolvedDescription = description
            ?? "Explain the durable problem to users and Agents."
        let run = AgentRun(
            runId: "run-\(issueNumber)",
            projectId: projectId,
            issueNumber: issueNumber,
            host: .codex,
            hostRunKey: "turn-\(issueNumber)",
            hostSessionId: "session-1",
            parentRunId: nil,
            kind: .root,
            phase: .running,
            outcome: nil,
            endReason: nil,
            displayLabel: "Implement board",
            summary: nil,
            revision: 1,
            startedAt: "2026-08-06T00:00:00Z",
            lastSeenAt: "2026-08-06T00:00:01Z",
            leaseExpiresAt: "2026-08-06T00:05:01Z",
            endedAt: nil
        )
        return IssueBoardCard(
            issueId: String(format: "issue_%032d", issueNumber),
            projectId: projectId,
            issueNumber: issueNumber,
            issueKey: String(format: "ISSUE-%03d", issueNumber),
            resourceId: "context-\(issueNumber)",
            path: String(format: "issues/open/%03d_issue_board.md", issueNumber),
            lifecycle: .open,
            title: resolvedTitle,
            description: resolvedDescription,
            descriptionExcerpt: resolvedDescription,
            externalReferences: externalReferences,
            foundAt: nil,
            createdAt: "2026-08-05T23:00:00Z",
            startedAt: "2026-08-06T00:00:00Z",
            closedAt: nil,
            archivedAt: nil,
            contentHash: "sha256:issue",
            sourceCommitId: nil,
            draftId: nil,
            draftRevision: nil,
            boardState: .inProgress,
            stateRevision: 2,
            stateUpdatedAt: "2026-08-06T00:00:00Z",
            closureSummary: nil,
            isStale: isStale,
            blocked: false,
            blockingReasons: [],
            dependencies: [],
            blockingFacts: [],
            activeRuns: [run],
            latestRun: run,
            changedByRunId: run.runId,
            verificationLevel: .agentSelf,
            verificationSteps: [],
            stateEvents: []
        )
    }
}

private struct ExternalReferencesEnvelope: Codable {
    let externalReferences: [IssueExternalReference]
}

final class IssueBoardLayoutTests: XCTestCase {
    func testIssueTimingFormatsRecordedLifecycleTimestamps() {
        XCTAssertNotNil(IssueTiming.absoluteText("2026-08-07T03:30:00.000Z"))
        XCTAssertNil(IssueTiming.absoluteText(nil))
    }

    func testUnlinkedActivityIsConditionalAndProjectScoped() {
        XCTAssertTrue(
            IssueBoardPresentation.showsUnlinkedActivity(
                activeProjectId: "project-1",
                responseProjectId: "project-1",
                runCount: 1
            )
        )
        XCTAssertFalse(
            IssueBoardPresentation.showsUnlinkedActivity(
                activeProjectId: "project-2",
                responseProjectId: "project-1",
                runCount: 1
            )
        )
        XCTAssertFalse(
            IssueBoardPresentation.showsUnlinkedActivity(
                activeProjectId: "project-1",
                responseProjectId: "project-1",
                runCount: 0
            )
        )
        XCTAssertFalse(
            IssueBoardPresentation.showsUnlinkedActivity(
                activeProjectId: nil,
                responseProjectId: "project-1",
                runCount: 1
            )
        )
    }

    func testExternalReferenceCardsIdentifyFirstTwoTargetsAndCountTheRemainder() {
        let references = [
            IssueExternalReference(
                kind: .issue,
                url: "https://github.com/clumsies/clumsies/issues/11?tracking=a-very-long-value#discussion"
            ),
            IssueExternalReference(
                kind: .pullRequest,
                url: "https://github.com/clumsies/clumsies/pull/13"
            ),
            IssueExternalReference(
                kind: .issue,
                url: "https://example.com/issues/需要跟进-12"
            ),
        ]
        let presentation = IssueExternalReferencePresentation.cardPresentation(
            for: references
        )

        XCTAssertEqual(
            presentation,
            IssueExternalReferenceCardPresentation(
                items: [
                    IssueExternalReferenceCardItem(
                        kind: .issue,
                        title: "Issue · clumsies/clumsies#11",
                        reference: references[0]
                    ),
                    IssueExternalReferenceCardItem(
                        kind: .pullRequest,
                        title: "PR · clumsies/clumsies#13",
                        reference: references[1]
                    ),
                ],
                remainingCount: 1
            )
        )
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Issue · clumsies/clumsies#11, PR · clumsies/clumsies#13, +1 more"
        )
        XCTAssertEqual(
            IssueExternalReferencePresentation.cardPresentation(for: []),
            IssueExternalReferenceCardPresentation(items: [], remainingCount: 0)
        )
        XCTAssertFalse(
            presentation.items
                .map(\.title)
                .joined()
                .contains("https://")
        )
        XCTAssertFalse(presentation.items.map(\.title).joined().contains("tracking="))
        XCTAssertFalse(presentation.items.map(\.title).joined().contains("discussion"))
    }

    func testExternalReferenceMenuLabelsCompactLongURLsAndPreserveCJKTargets() {
        let longReference = IssueExternalReference(
            kind: .issue,
            url: "https://github.com/an-extraordinarily-long-organization-name/an-even-longer-repository-name/issues/123456789?tracking=abcdefghijklmnopqrstuvwxyz"
        )
        let cjkReference = IssueExternalReference(
            kind: .pullRequest,
            url: "https://code.example.com/reviews/修复登录流程-四二?view=完整#diff"
        )
        let longLabel = IssueExternalReferencePresentation.menuLabel(for: longReference)
        let cjkLabel = IssueExternalReferencePresentation.menuLabel(for: cjkReference)
        let cjkCardLabel = IssueExternalReferencePresentation
            .cardPresentation(for: [cjkReference])
            .items.first?.title

        XCTAssertTrue(longLabel.hasPrefix("Issue · "))
        XCTAssertLessThanOrEqual(
            longLabel.count,
            "Issue · ".count + IssueExternalReferencePresentation.maximumMenuTargetLength
        )
        XCTAssertTrue(longLabel.contains("tracking="))
        XCTAssertTrue(cjkLabel.contains("修复登录流程-四二"))
        XCTAssertTrue(cjkLabel.contains("view=完整"))
        XCTAssertTrue(cjkLabel.contains("diff"))
        XCTAssertTrue(cjkCardLabel?.contains("修复登录流程-四二") == true)
        XCTAssertFalse(cjkCardLabel?.contains("view=") == true)
        XCTAssertFalse(cjkCardLabel?.contains("diff") == true)
    }

    func testExternalReferenceMenuLabelsDistinguishQueryAndFragmentVariants() {
        let queryA = IssueExternalReference(
            kind: .pullRequest,
            url: "https://github.com/clumsies/clumsies/pull/13?view=files"
        )
        let queryB = IssueExternalReference(
            kind: .pullRequest,
            url: "https://github.com/clumsies/clumsies/pull/13?view=checks"
        )
        let fragmentA = IssueExternalReference(
            kind: .issue,
            url: "https://github.com/clumsies/clumsies/issues/11#discussion-a"
        )
        let fragmentB = IssueExternalReference(
            kind: .issue,
            url: "https://github.com/clumsies/clumsies/issues/11#discussion-b"
        )

        XCTAssertNotEqual(
            IssueExternalReferencePresentation.menuLabel(for: queryA),
            IssueExternalReferencePresentation.menuLabel(for: queryB)
        )
        XCTAssertNotEqual(
            IssueExternalReferencePresentation.menuLabel(for: fragmentA),
            IssueExternalReferencePresentation.menuLabel(for: fragmentB)
        )
        XCTAssertEqual(
            IssueExternalReferencePresentation.cardPresentation(for: [queryA])
                .items.map(\.title),
            IssueExternalReferencePresentation.cardPresentation(for: [queryB])
                .items.map(\.title)
        )
        XCTAssertEqual(
            IssueExternalReferencePresentation.cardPresentation(for: [fragmentA])
                .items.map(\.title),
            IssueExternalReferencePresentation.cardPresentation(for: [fragmentB])
                .items.map(\.title)
        )
    }

    func testExternalReferenceOpenDestinationAcceptsOnlyWebURLs() {
        XCTAssertNotNil(
            IssueExternalReferencePresentation.destinationURL(
                for: IssueExternalReference(
                    kind: .issue,
                    url: "https://example.com/issues/需要跟进-12"
                )
            )
        )
        XCTAssertNil(
            IssueExternalReferencePresentation.destinationURL(
                for: IssueExternalReference(kind: .issue, url: "file:///tmp/private")
            )
        )
    }

    func testBoardUsesTheRequiredFiveColumnOrder() {
        XCTAssertEqual(
            IssueBoardState.allCases,
            [.todo, .inProgress, .paused, .inReview, .done]
        )
        XCTAssertEqual(IssueBoardState.allCases.map(\.title), [
            "Todo",
            "In Progress",
            "Paused",
            "In Review",
            "Done",
        ])
        XCTAssertTrue(IssueBoardState.allCases.allSatisfy { !$0.symbolName.isEmpty })
    }

    func testBoardColumnsPlaceStaleIssuesInTheAbandonedBucket() {
        XCTAssertEqual(
            BoardColumn.allCases,
            [.todo, .inProgress, .inReview, .abandoned, .done]
        )
        XCTAssertEqual(BoardColumn.allCases.map(\.title), [
            "Todo",
            "In Progress",
            "In Review",
            "Abandoned",
            "Done",
        ])
        XCTAssertNil(BoardColumn.abandoned.state)
        XCTAssertEqual(BoardColumn.inProgress.state, .inProgress)
        XCTAssertTrue(BoardColumn.allCases.allSatisfy { !$0.symbolName.isEmpty })
    }

    func testReadableColumnsScrollAtTheMinimumWorkspaceWidth() {
        XCTAssertEqual(IssueBoardLayout.workspaceMinimumWidth, 920)
        XCTAssertGreaterThanOrEqual(IssueBoardLayout.columnWidth, 260)
        XCTAssertGreaterThan(
            IssueBoardLayout.boardContentWidth,
            IssueBoardLayout.workspaceMinimumWidth
        )
    }

    func testShortBoardContentFillsTheViewportFromTheTop() {
        XCTAssertEqual(
            IssueBoardLayout.minimumContentWidth(for: 640),
            IssueBoardLayout.boardContentWidth
        )
        XCTAssertEqual(
            IssueBoardLayout.minimumContentWidth(
                for: IssueBoardLayout.boardContentWidth + 100
            ),
            IssueBoardLayout.boardContentWidth + 100
        )
        XCTAssertEqual(
            IssueBoardLayout.minimumContentHeight(for: 640),
            640
        )
        XCTAssertEqual(
            IssueBoardLayout.minimumContentHeight(for: -1),
            0
        )
    }
}

private actor IssueBoardLoaderScript {
    private let response: IssueBoardResponse
    private let failsAfterCall: Int?
    private(set) var callCount = 0

    init(response: IssueBoardResponse, failsAfterCall: Int? = nil) {
        self.response = response
        self.failsAfterCall = failsAfterCall
    }

    func load(projectId: String) throws -> IssueBoardResponse {
        callCount += 1
        if let failsAfterCall, callCount > failsAfterCall {
            throw IssueBoardTestError.unavailable
        }
        return response
    }
}

private actor IssueDetailLoaderScript {
    private let response: IssueDetailResponse
    private(set) var callCount = 0

    init(response: IssueDetailResponse) {
        self.response = response
    }

    func load(projectId _: String, issueNumber _: Int) throws -> IssueDetailResponse {
        callCount += 1
        return response
    }
}

private enum IssueBoardTestError: LocalizedError, Sendable {
    case unavailable

    var errorDescription: String? {
        "The test daemon is unavailable."
    }
}
