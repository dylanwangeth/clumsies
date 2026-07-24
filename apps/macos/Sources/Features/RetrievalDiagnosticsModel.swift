import Foundation

struct EvaluationJudgmentDraft: Identifiable, Equatable, Sendable {
    var id: String {
        "\(resourceId)\u{0}\(unitKey ?? "")\u{0}\(missed)"
    }

    let resourceId: String
    let unitKey: String?
    var relevance: UInt8
    let missed: Bool
    var notes: String?

    init(
        resourceId: String,
        unitKey: String?,
        relevance: UInt8,
        missed: Bool,
        notes: String?
    ) {
        self.resourceId = resourceId
        self.unitKey = unitKey
        self.relevance = relevance
        self.missed = missed
        self.notes = notes
    }

    init(_ judgment: EvaluationJudgment) {
        self.init(
            resourceId: judgment.resourceId,
            unitKey: judgment.unitKey,
            relevance: judgment.relevance,
            missed: judgment.missed,
            notes: judgment.notes
        )
    }

    var input: EvaluationJudgmentInput {
        EvaluationJudgmentInput(
            resourceId: resourceId,
            unitKey: unitKey,
            relevance: relevance,
            missed: missed,
            notes: notes
        )
    }
}

@MainActor
final class RetrievalDiagnosticsModel: ObservableObject {
    @Published private(set) var runs: [RetrievalRun] = []
    @Published var selectedRunId: String?
    @Published private(set) var detail: RetrievalRunDetail?
    @Published private(set) var judgmentDrafts: [EvaluationJudgmentDraft] = []
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
                judgmentDrafts = []
            }
        } catch {
            guard selectionGeneration == generation else { return }
            runs = []
            nextCursor = nil
            detail = nil
            judgmentDrafts = []
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
            judgmentDrafts = []
            return
        }
        detail = nil
        judgmentDrafts = []
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
            judgmentDrafts = []
            errorMessage = error.localizedDescription
        }
    }

    func createEvaluationCase() async {
        guard let runId = detail?.run.runId else { return }
        await mutate {
            _ = try await daemon.createEvaluationCase(
                CreateEvaluationCaseRequest(
                    runId: runId,
                    queryCategory: nil,
                    notes: nil
                )
            )
            try await refreshDetail(runId: runId)
        }
    }

    func saveJudgments() async {
        guard let runId = detail?.run.runId,
              let evaluationCase = detail?.evaluationCase else {
            return
        }
        let judgments = judgmentDrafts.map(\.input)
        await mutate {
            _ = try await daemon.replaceEvaluationJudgments(
                ReplaceEvaluationJudgmentsRequest(
                    caseId: evaluationCase.caseId,
                    expectedJudgmentVersion: evaluationCase.judgmentVersion,
                    judgments: judgments
                )
            )
            try await refreshDetail(runId: runId)
        }
    }

    func candidateRelevance(_ candidate: RetrievalCandidate) -> UInt8? {
        judgmentDrafts.first {
            !$0.missed && $0.resourceId == candidate.resourceId && $0.unitKey == candidate.unitKey
        }?.relevance
    }

    func setCandidateRelevance(_ relevance: UInt8?, candidate: RetrievalCandidate) {
        let index = judgmentDrafts.firstIndex {
            !$0.missed && $0.resourceId == candidate.resourceId && $0.unitKey == candidate.unitKey
        }
        switch (index, relevance) {
        case (.some(let index), .some(let relevance)):
            judgmentDrafts[index].relevance = relevance
        case (.some(let index), .none):
            judgmentDrafts.remove(at: index)
        case (.none, .some(let relevance)):
            judgmentDrafts.append(
                EvaluationJudgmentDraft(
                    resourceId: candidate.resourceId,
                    unitKey: candidate.unitKey,
                    relevance: relevance,
                    missed: false,
                    notes: nil
                )
            )
        case (.none, .none):
            break
        }
    }

    func addMissedEvidence(_ resource: EvaluationCorpusResource) {
        guard !judgmentDrafts.contains(where: {
            $0.missed && $0.resourceId == resource.resourceId
        }) else {
            return
        }
        judgmentDrafts.append(
            EvaluationJudgmentDraft(
                resourceId: resource.resourceId,
                unitKey: nil,
                relevance: 1,
                missed: true,
                notes: nil
            )
        )
    }

    func setMissedRelevance(_ relevance: UInt8, draftId: String) {
        guard let index = judgmentDrafts.firstIndex(where: { $0.id == draftId }) else { return }
        judgmentDrafts[index].relevance = relevance
    }

    func removeMissedEvidence(draftId: String) {
        judgmentDrafts.removeAll { $0.id == draftId && $0.missed }
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
        judgmentDrafts = loaded.judgments.map(EvaluationJudgmentDraft.init)
    }

    private func mutate(_ operation: () async throws -> Void) async {
        guard !isMutating else { return }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
