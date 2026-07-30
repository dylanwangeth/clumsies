import Foundation

struct EvaluationEvidenceDraft: Identifiable, Equatable, Sendable {
    var id: String {
        "\(resourceId)\u{0}\(unitKey ?? "")"
    }

    let resourceId: String
    let unitKey: String?

    init(resourceId: String, unitKey: String?) {
        self.resourceId = resourceId
        self.unitKey = unitKey
    }

    init(_ evidence: EvaluationEvidence) {
        self.init(
            resourceId: evidence.resourceId,
            unitKey: evidence.unitKey
        )
    }

    var input: EvaluationEvidenceInput {
        EvaluationEvidenceInput(
            resourceId: resourceId,
            unitKey: unitKey
        )
    }
}

@MainActor
final class RetrievalDiagnosticsModel: ObservableObject {
    @Published private(set) var runs: [RetrievalRun] = []
    @Published var selectedRunId: String?
    @Published private(set) var detail: RetrievalRunDetail?
    @Published private(set) var evidenceDrafts: [EvaluationEvidenceDraft] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isMutating = false
    @Published var errorMessage: String?

    private let daemon: DaemonXPCClient
    private var projectId: String?
    private(set) var nextCursor: String?
    private var selectionGeneration = UUID()

    init(daemon: DaemonXPCClient) {
        self.daemon = daemon
    }

    func load(projectId: String?) async {
        self.projectId = projectId
        let generation = UUID()
        selectionGeneration = generation
        isLoading = true
        errorMessage = nil
        defer {
            if selectionGeneration == generation {
                isLoading = false
            }
        }
        do {
            let response = try await daemon.listRetrievalRuns(
                RetrievalRunListRequest(
                    projectId: projectId,
                    status: nil,
                    cursor: nil,
                    limit: 100
                )
            )
            guard selectionGeneration == generation else { return }
            runs = response.items
            nextCursor = response.nextCursor
            let selected = selectedRunId.flatMap { selected in
                response.items.first(where: { $0.runId == selected })?.runId
            } ?? response.items.first?.runId
            selectedRunId = selected
            if let selected {
                try await loadDetail(runId: selected, generation: generation)
            } else {
                detail = nil
                evidenceDrafts = []
            }
        } catch {
            guard selectionGeneration == generation else { return }
            runs = []
            nextCursor = nil
            detail = nil
            evidenceDrafts = []
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        errorMessage = nil
        defer { isLoadingMore = false }
        do {
            let response = try await daemon.listRetrievalRuns(
                RetrievalRunListRequest(
                    projectId: projectId,
                    status: nil,
                    cursor: cursor,
                    limit: 100
                )
            )
            let existing = Set(runs.map(\.runId))
            runs.append(contentsOf: response.items.filter { !existing.contains($0.runId) })
            nextCursor = response.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(runId: String?) async {
        guard runId != selectedRunId || detail?.run.runId != runId else { return }
        selectedRunId = runId
        let generation = UUID()
        selectionGeneration = generation
        guard let runId else {
            detail = nil
            evidenceDrafts = []
            return
        }
        detail = nil
        evidenceDrafts = []
        isLoading = true
        errorMessage = nil
        defer {
            if selectionGeneration == generation {
                isLoading = false
            }
        }
        do {
            try await loadDetail(runId: runId, generation: generation)
        } catch {
            guard selectionGeneration == generation else { return }
            detail = nil
            evidenceDrafts = []
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func markInaccurate() async -> Bool {
        guard let runId = detail?.run.runId else { return false }
        return await mutate {
            _ = try await daemon.createEvaluationCase(
                CreateEvaluationCaseRequest(runId: runId)
            )
            try await refreshDetail(runId: runId)
        }
    }

    @discardableResult
    func resolveEvidenceReview() async -> Bool {
        guard let runId = detail?.run.runId,
              let evaluationCase = detail?.evaluationCase else {
            return false
        }
        let evidence = evidenceDrafts.map(\.input)
        return await mutate {
            _ = try await daemon.resolveEvaluationCase(
                ResolveEvaluationCaseRequest(
                    caseId: evaluationCase.caseId,
                    expectedVersion: evaluationCase.version,
                    evidence: evidence,
                    noneMatched: evidence.isEmpty
                )
            )
            try await refreshDetail(runId: runId)
        }
    }

    func resetEvidenceSelection() {
        evidenceDrafts = detail?.evidence.map(EvaluationEvidenceDraft.init) ?? []
    }

    func isEvidenceSelected(_ suggestion: EvaluationEvidenceSuggestion) -> Bool {
        evidenceDrafts.contains {
            $0.resourceId == suggestion.resourceId && $0.unitKey == suggestion.unitKey
        }
    }

    func setEvidenceSelected(_ selected: Bool, suggestion: EvaluationEvidenceSuggestion) {
        evidenceDrafts.removeAll {
            $0.resourceId == suggestion.resourceId && $0.unitKey == suggestion.unitKey
        }
        if selected {
            evidenceDrafts.append(
                EvaluationEvidenceDraft(
                    resourceId: suggestion.resourceId,
                    unitKey: suggestion.unitKey
                )
            )
        }
    }

    func clearUnpinnedHistory() async {
        await mutate {
            _ = try await daemon.clearRetrievalRuns(projectId: projectId)
            await load(projectId: projectId)
        }
    }

    func exportEvaluationSet() async throws -> ExportEvaluationSetResponse {
        try await daemon.exportEvaluationSet(projectId: projectId)
    }

    private func loadDetail(runId: String, generation: UUID) async throws {
        let loaded = try await daemon.retrievalRun(runId)
        guard selectionGeneration == generation else { return }
        apply(loaded)
    }

    private func refreshDetail(runId: String) async throws {
        let loaded = try await daemon.retrievalRun(runId)
        apply(loaded)
        let response = try await daemon.listRetrievalRuns(
            RetrievalRunListRequest(
                projectId: projectId,
                status: nil,
                cursor: nil,
                limit: 100
            )
        )
        runs = response.items
        nextCursor = response.nextCursor
    }

    private func apply(_ loaded: RetrievalRunDetail) {
        detail = loaded
        if selectedRunId != loaded.run.runId {
            selectedRunId = loaded.run.runId
        }
        evidenceDrafts = loaded.evidence.map(EvaluationEvidenceDraft.init)
    }

    @discardableResult
    private func mutate(_ operation: () async throws -> Void) async -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }
        do {
            try await operation()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
