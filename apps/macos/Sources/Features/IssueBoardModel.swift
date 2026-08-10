import Combine
import Foundation

enum IssueBoardModelError: LocalizedError, Sendable {
    case unexpectedProject
    case unexpectedIssue

    var errorDescription: String? {
        switch self {
        case .unexpectedProject:
            "The local Clumsies daemon returned an Issue board for a different project."
        case .unexpectedIssue:
            "The local Clumsies daemon returned details for a different Issue."
        }
    }
}

@MainActor
final class IssueBoardModel: ObservableObject {
    typealias Loader = @Sendable (String) async throws -> IssueBoardResponse
    typealias DetailLoader = @Sendable (String, Int) async throws -> IssueDetailResponse
    typealias GateApplier = @Sendable (ApplyIssueGateRequest) async throws -> IssueMutationResponse
    typealias VerificationStepToggler = @Sendable (SetVerificationStepCompletedRequest) async throws -> IssueMutationResponse
    typealias UnclaimApplier = @Sendable (UnclaimIssueRequest) async throws -> IssueMutationResponse
    typealias RemovalApplier = @Sendable (RemoveIssueRequest) async throws -> IssueRemovalResponse

    @Published private(set) var response: IssueBoardResponse?
    @Published private(set) var projectId: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshError: String?
    @Published private(set) var detailByIssueId: [String: IssueDetailResponse] = [:]
    @Published private(set) var detailErrorByIssueId: [String: String] = [:]
    @Published private(set) var loadingDetailIssueIds: Set<String> = []
    @Published var showsStaleOnly = false
    @Published var showsBlockedOnly = false
    @Published var showsExternalIssuesOnly = false
    @Published var showsPullRequestsOnly = false
    @Published var searchQuery = ""

    private let loader: Loader
    private let detailLoader: DetailLoader
    private let gateApplier: GateApplier
    private let verificationStepToggler: VerificationStepToggler
    private let unclaimApplier: UnclaimApplier
    private let removalApplier: RemovalApplier
    private var generation = UUID()
    private var activeRequestGeneration: UUID?

    init(daemon: DaemonXPCClient) {
        loader = { projectId in
            try await daemon.issueBoard(projectId)
        }
        detailLoader = { projectId, issueNumber in
            try await daemon.issueDetail(projectId: projectId, issueNumber: issueNumber)
        }
        gateApplier = { request in
            try await daemon.applyIssueGate(request)
        }
        verificationStepToggler = { request in
            try await daemon.setVerificationStepCompleted(request)
        }
        unclaimApplier = { request in
            try await daemon.unclaimIssue(request)
        }
        removalApplier = { request in
            try await daemon.removeIssue(request)
        }
    }

    init(
        loader: @escaping Loader,
        detailLoader: @escaping DetailLoader = { _, _ in throw IssueBoardModelError.unexpectedIssue },
        gateApplier: @escaping GateApplier = { _ in throw IssueBoardModelError.unexpectedIssue },
        verificationStepToggler: @escaping VerificationStepToggler = { _ in throw IssueBoardModelError.unexpectedIssue },
        unclaimApplier: @escaping UnclaimApplier = { _ in throw IssueBoardModelError.unexpectedIssue },
        removalApplier: @escaping RemovalApplier = { _ in throw IssueBoardModelError.unexpectedIssue }
    ) {
        self.loader = loader
        self.detailLoader = detailLoader
        self.gateApplier = gateApplier
        self.verificationStepToggler = verificationStepToggler
        self.unclaimApplier = unclaimApplier
        self.removalApplier = removalApplier
    }

    var issues: [IssueBoardCard] {
        response?.issues ?? []
    }

    var unlinkedRuns: [AgentRun] {
        response?.unlinkedRuns ?? []
    }

    var diagnostics: [IssueBoardDiagnostic] {
        response?.diagnostics ?? []
    }

    var matchingIssues: [IssueBoardCard] {
        let needle = searchNeedle
        guard !needle.isEmpty else { return issues }
        return issues.filter { $0.matches(query: needle) }
    }

    func issues(in state: IssueBoardState) -> [IssueBoardCard] {
        let needle = searchNeedle
        return issues.filter { issue in
            issue.boardState == state
                && (needle.isEmpty || issue.matches(query: needle))
                && (!showsStaleOnly || issue.isStale)
                && (!showsBlockedOnly || issue.blocked)
                && (!showsExternalIssuesOnly || issue.hasExternalReference(kind: .issue))
                && (!showsPullRequestsOnly || issue.hasExternalReference(kind: .pullRequest))
        }
    }

    private var searchNeedle: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }

    var hasExternalReferenceFilters: Bool {
        showsExternalIssuesOnly || showsPullRequestsOnly
    }

    func clearExternalReferenceFilters() {
        showsExternalIssuesOnly = false
        showsPullRequestsOnly = false
    }

    func detail(for issue: IssueBoardCard) -> IssueDetailResponse? {
        guard let detail = detailByIssueId[issue.id],
              detail.issue.contentHash == issue.contentHash else { return nil }
        return detail
    }

    func detailError(for issue: IssueBoardCard) -> String? {
        detailErrorByIssueId[issue.id]
    }

    func isLoadingDetail(for issue: IssueBoardCard) -> Bool {
        loadingDetailIssueIds.contains(issue.id)
    }

    func loadDetail(_ issue: IssueBoardCard, force: Bool = false) async {
        let issueId = issue.id
        guard projectId == issue.projectId,
              force || detail(for: issue) == nil,
              !loadingDetailIssueIds.contains(issueId) else { return }
        loadingDetailIssueIds.insert(issueId)
        detailErrorByIssueId[issueId] = nil
        defer { loadingDetailIssueIds.remove(issueId) }
        do {
            let detail = try await detailLoader(issue.projectId, issue.issueNumber)
            guard projectId == issue.projectId else { return }
            guard detail.issue.id == issueId else {
                throw IssueBoardModelError.unexpectedIssue
            }
            detailByIssueId[issueId] = detail
        } catch is CancellationError {
            return
        } catch {
            guard projectId == issue.projectId else { return }
            detailErrorByIssueId[issueId] = error.localizedDescription
        }
    }

    func applyGate(_ action: IssueGateAction, to issue: IssueBoardCard) async throws {
        _ = try await gateApplier(
            .init(
                projectId: issue.projectId,
                issueNumber: issue.issueNumber,
                expectedRevision: issue.stateRevision,
                action: action
            )
        )
        detailByIssueId[issue.id] = nil
        await refresh()
        if let updated = issues.first(where: { $0.id == issue.id }) {
            await loadDetail(updated, force: true)
        }
    }

    func unclaim(_ issue: IssueBoardCard) async throws {
        guard let runId = issue.activeRuns.first?.runId else {
            throw IssueBoardModelError.unexpectedIssue
        }
        _ = try await unclaimApplier(
            .init(
                projectId: issue.projectId,
                issueKey: issue.issueKey,
                expectedRevision: issue.stateRevision,
                runId: runId
            )
        )
        detailByIssueId[issue.id] = nil
        await refresh()
    }

    func setVerificationStep(_ completed: Bool, stepIndex: Int, issue: IssueBoardCard) async throws {
        _ = try await verificationStepToggler(
            .init(
                projectId: issue.projectId,
                issueKey: issue.issueKey,
                expectedRevision: issue.stateRevision,
                stepIndex: stepIndex,
                completed: completed
            )
        )
        detailByIssueId[issue.id] = nil
        await refresh()
        if let updated = issues.first(where: { $0.id == issue.id }) {
            await loadDetail(updated, force: true)
        }
    }

    func remove(_ action: IssueRemovalAction, issue: IssueBoardCard) async throws {
        _ = try await removalApplier(
            .init(
                projectId: issue.projectId,
                issueNumber: issue.issueNumber,
                expectedRevision: issue.stateRevision,
                action: action
            )
        )
        detailByIssueId[issue.id] = nil
        await refresh()
    }

    func poll(
        projectId: String?,
        interval: Duration = .milliseconds(1_500)
    ) async {
        let currentGeneration = prepare(projectId: projectId)
        guard let projectId else { return }

        defer {
            finish(generation: currentGeneration)
        }

        while !Task.isCancelled {
            await refresh(projectId: projectId, generation: currentGeneration)
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    func loadOnce(projectId: String?) async {
        let currentGeneration = prepare(projectId: projectId)
        guard let projectId else { return }
        await refresh(projectId: projectId, generation: currentGeneration)
    }

    func refresh() async {
        guard let projectId else { return }
        await refresh(projectId: projectId, generation: generation)
    }

    private func prepare(projectId: String?) -> UUID {
        generation = UUID()
        activeRequestGeneration = nil

        if self.projectId != projectId {
            response = nil
            refreshError = nil
            detailByIssueId = [:]
            detailErrorByIssueId = [:]
            loadingDetailIssueIds = []
        }
        self.projectId = projectId
        isLoading = projectId != nil && response == nil
        isRefreshing = false
        return generation
    }

    private func refresh(projectId: String, generation: UUID) async {
        guard self.generation == generation,
              self.projectId == projectId,
              !Task.isCancelled,
              activeRequestGeneration != generation else {
            return
        }

        activeRequestGeneration = generation
        if response == nil {
            isLoading = true
        } else {
            isRefreshing = true
        }

        defer {
            if activeRequestGeneration == generation {
                activeRequestGeneration = nil
                isLoading = false
                isRefreshing = false
            }
        }

        do {
            let loaded = try await loader(projectId)
            guard self.generation == generation,
                  self.projectId == projectId,
                  !Task.isCancelled else {
                return
            }
            guard loaded.projectId == projectId else {
                throw IssueBoardModelError.unexpectedProject
            }
            response = loaded
            let currentHashes = Dictionary(
                uniqueKeysWithValues: loaded.issues.map { ($0.id, $0.contentHash) }
            )
            detailByIssueId = detailByIssueId.filter { issueId, detail in
                currentHashes[issueId] == detail.issue.contentHash
            }
            detailErrorByIssueId = detailErrorByIssueId.filter { currentHashes[$0.key] != nil }
            refreshError = nil
        } catch is CancellationError {
            return
        } catch {
            guard self.generation == generation,
                  self.projectId == projectId,
                  !Task.isCancelled else {
                return
            }
            refreshError = error.localizedDescription
        }
    }

    private func finish(generation: UUID) {
        guard self.generation == generation else { return }
        isLoading = false
        isRefreshing = false
        if activeRequestGeneration == generation {
            activeRequestGeneration = nil
        }
    }
}

private extension IssueBoardCard {
    func hasExternalReference(kind: IssueExternalReferenceKind) -> Bool {
        externalReferences.contains { $0.kind == kind }
    }

    func matches(query needle: String) -> Bool {
        "\(issueKey) \(issueNumber) \(title) \(description)".localizedLowercase.contains(needle)
    }
}
