import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum RetrievalDiagnosticsLayout {
    static let runListMinimumWidth: CGFloat = 360
    static let runListIdealWidth: CGFloat = 360
    static let runListMaximumWidth: CGFloat = 480
    static let mainPaneMinimumWidth: CGFloat = 650
    static let dividerAllowance: CGFloat = 2
    static let minimumWindowContentWidth =
        runListMinimumWidth
        + mainPaneMinimumWidth
        + dividerAllowance
}

enum RetrievalRunDetailsWindowLayout {
    static let defaultContentSize = NSSize(width: 560, height: 720)
    static let minimumContentSize = NSSize(width: 460, height: 560)
}

enum DiagnosticsDestination: String, Identifiable {
    case runtime
    case retrieval

    var id: Self { self }

    var title: String {
        switch self {
        case .runtime: "Runtime Status"
        case .retrieval: "Retrieval Runs"
        }
    }

    var defaultContentSize: NSSize {
        switch self {
        case .runtime: NSSize(width: 640, height: 560)
        case .retrieval: NSSize(width: 1_600, height: 850)
        }
    }

    var minimumContentSize: NSSize {
        switch self {
        case .runtime: NSSize(width: 520, height: 440)
        case .retrieval:
            NSSize(
                width: RetrievalDiagnosticsLayout.minimumWindowContentWidth,
                height: 560
            )
        }
    }
}

struct NativeDiagnosticsView: View {
    @ObservedObject var store: WorkspaceStore
    let destination: DiagnosticsDestination
    @StateObject private var retrieval: RetrievalDiagnosticsModel

    init(store: WorkspaceStore, destination: DiagnosticsDestination) {
        self.store = store
        self.destination = destination
        _retrieval = StateObject(
            wrappedValue: RetrievalDiagnosticsModel(daemon: store.daemon)
        )
    }

    var body: some View {
        Group {
            switch destination {
            case .runtime:
                RuntimeDiagnosticsView(store: store)
            case .retrieval:
                RetrievalDiagnosticsView(
                    model: retrieval,
                    projectName: store.activeProject?.name,
                    projectId: store.activeProjectId
                )
            }
        }
        .task(id: "\(destination.rawValue):\(store.activeProjectId ?? "")") {
            guard destination == .retrieval else { return }
            await retrieval.load(projectId: store.activeProjectId)
        }
    }
}

private struct RuntimeDiagnosticsView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        Form {
            if let runtime = store.runtime {
                Section("Daemon") {
                    LabeledContent("Version", value: runtime.health.daemonVersion)
                    LabeledContent("Project", value: runtime.health.projectId ?? "Not selected")
                    LabeledContent("Database", value: runtime.health.localDb.path)
                    LabeledContent("Schema", value: String(runtime.health.localDb.schemaVersion))
                    LabeledContent("MCP", value: runtime.mcp.running ? "Running" : "Stopped")
                    LabeledContent("Log directory", value: runtime.health.logDir)
                }
                Section("Synchronization") {
                    LabeledContent("Drafts", value: runtime.sync.draftSync.state.capitalized)
                    LabeledContent("Commits", value: runtime.sync.commitSync.state.capitalized)
                    LabeledContent(
                        "Pending operations",
                        value: String(runtime.sync.pendingOperationCount)
                    )
                    LabeledContent(
                        "Failed operations",
                        value: String(runtime.sync.failedOperationCount)
                    )
                    LabeledContent(
                        "Drafts behind",
                        value: String(runtime.sync.behindDraftCount)
                    )
                    LabeledContent(
                        "Reconciliation conflicts",
                        value: String(runtime.sync.reconciliationConflictCount)
                    )
                    Button("Retry") { Task { await store.retrySync() } }
                }
                Section("Server") {
                    LabeledContent("Data source", value: runtime.serverDataSource.capitalized)
                    LabeledContent("URL", value: runtime.health.serverUrl)
                }
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
    }
}

private struct RetrievalDiagnosticsView: View {
    @ObservedObject var model: RetrievalDiagnosticsModel
    let projectName: String?
    let projectId: String?

    @State private var confirmsClear = false
    @State private var exportError: String?
    @StateObject private var detailsWindow = RetrievalRunDetailsWindowPresenter()

    var body: some View {
        NavigationSplitView {
            RetrievalRunList(
                model: model,
                scopeTitle: projectName ?? projectId ?? "All Projects",
                onRefresh: {
                    Task { await model.load(projectId: projectId) }
                },
                onClearHistory: {
                    confirmsClear = true
                }
            )
                .frame(
                    minWidth: RetrievalDiagnosticsLayout.runListMinimumWidth,
                    idealWidth: RetrievalDiagnosticsLayout.runListIdealWidth,
                    maxWidth: RetrievalDiagnosticsLayout.runListMaximumWidth,
                    maxHeight: .infinity
                )
                .navigationSplitViewColumnWidth(
                    min: RetrievalDiagnosticsLayout.runListMinimumWidth,
                    ideal: RetrievalDiagnosticsLayout.runListIdealWidth,
                    max: RetrievalDiagnosticsLayout.runListMaximumWidth
                )
        } detail: {
            RetrievalRunContent(model: model)
            .frame(
                minWidth: RetrievalDiagnosticsLayout.mainPaneMinimumWidth,
                maxWidth: .infinity,
                maxHeight: .infinity
            )
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await exportEvaluationSet() }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Export Evaluation Set")
                    .disabled(model.runs.allSatisfy { $0.evaluationCaseId == nil })

                    Button {
                        detailsWindow.present(model: model)
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .help("Show Run Details")
                    .accessibilityLabel("Show Run Details")
                    .disabled(model.detail == nil)
                }
            }
        }
        .onDisappear {
            detailsWindow.close()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = model.errorMessage ?? exportError {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(message)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider()
                }
            }
        }
        .confirmationDialog(
            "Clear unpinned retrieval history?",
            isPresented: $confirmsClear
        ) {
            Button("Clear History", role: .destructive) {
                Task { await model.clearUnpinnedHistory() }
            }
        } message: {
            Text("Runs used by Evaluation Cases will be kept.")
        }
    }

    @MainActor
    private func exportEvaluationSet() async {
        exportError = nil
        do {
            let exported = try await model.exportEvaluationSet()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "clumsies-retrieval-evaluation.json"
            panel.allowedContentTypes = [.json]
            guard await panel.selectionResponse == .OK, let url = panel.url else { return }
            try exported.fixtureJson.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct RetrievalRunList: View {
    @ObservedObject var model: RetrievalDiagnosticsModel
    let scopeTitle: String
    let onRefresh: () -> Void
    let onClearHistory: () -> Void
    @State private var selectedRunId: String?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text(scopeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)

                ForEach(model.runs) { run in
                    let isSelected = selectedRunId == run.runId
                    Button {
                        selectedRunId = run.runId
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run.query)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 6) {
                                Image(systemName: run.status.symbolName)
                                    .foregroundStyle(isSelected ? Color.white : run.status.tint)
                                Text(run.createdAt)
                                    .lineLimit(1)
                                if run.evaluationCaseId != nil {
                                    Image(systemName: "pin.fill")
                                        .help("Included in the Evaluation Set")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(
                                isSelected ? Color.white.opacity(0.8) : Color.secondary
                            )
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                }
                if model.nextCursor != nil {
                    Button {
                        Task { await model.loadMore() }
                    } label: {
                        if model.isLoadingMore {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Load More")
                        }
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)
        }
        .overlay {
            if model.isLoading && model.runs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.runs.isEmpty {
                ContentUnavailableView(
                    "No Retrieval Runs",
                    systemImage: "text.magnifyingglass",
                    description: Text("Memory activation results will appear here.")
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Retrieval Runs")

                Button(role: .destructive, action: onClearHistory) {
                    Image(systemName: "trash")
                }
                .help("Clear Unpinned Retrieval History")
                .disabled(model.runs.isEmpty)
            }
        }
        .onChange(of: selectedRunId) { _, runId in
            guard runId != model.selectedRunId else { return }
            DispatchQueue.main.async {
                guard runId != model.selectedRunId else { return }
                Task { await model.select(runId: runId) }
            }
        }
        .onChange(of: model.selectedRunId) { _, runId in
            guard selectedRunId != runId else { return }
            selectedRunId = runId
        }
    }
}

private struct RetrievalRunContent: View {
    @ObservedObject var model: RetrievalDiagnosticsModel

    var body: some View {
        if model.isLoading, model.detail == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail = model.detail {
            VStack(spacing: 0) {
                RetrievalRunSummary(run: detail.run)
                Divider()
                if let error = detail.run.errorSummary {
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                            Text(error)
                                .textSelection(.enabled)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        Divider()
                    }
                }
                CandidateTraceTable(
                    model: model,
                    detail: detail
                )
            }
        } else {
            ContentUnavailableView(
                "Select a Retrieval Run",
                systemImage: "list.bullet.rectangle"
            )
        }
    }
}

private struct RetrievalRunSummary: View {
    let run: RetrievalRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(run.query)
                    .font(.headline)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer()
                Label(run.status.rawValue.capitalized, systemImage: run.status.symbolName)
                    .font(.caption)
                    .foregroundStyle(run.status.tint)
            }
            HStack(spacing: 24) {
                summaryItem(
                    "Result",
                    "\(run.returnedFragmentCount) fragments · \(run.returnedTokenCount) tokens"
                )
                summaryItem("Corpus", "\(run.resourceCount) resources · \(run.unitCount) units")
                summaryItem("Total", formatDuration(run.latencies.totalUs))
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func summaryItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
        }
        .font(.caption)
    }
}

private struct CandidateTraceTable: View {
    @ObservedObject var model: RetrievalDiagnosticsModel
    let detail: RetrievalRunDetail

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Candidate Trace")
                    .font(.headline)
                Spacer()
                Text("\(detail.candidates.count) candidates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            Divider()
            Table(detail.candidates) {
                TableColumn("Final") { candidate in
                    Text(rank(candidate.finalRank))
                        .monospacedDigit()
                }
                .width(44)
                TableColumn("Resource") { candidate in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.path)
                            .lineLimit(1)
                        if !candidate.headingPath.isEmpty {
                            Text(candidate.headingPath.joined(separator: " › "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .help(candidate.evidenceExcerpt)
                }
                .width(min: 150, ideal: 220)
                TableColumn("BM25") { candidate in
                    stage(rank: candidate.bm25Rank ?? candidate.exactRank, score: candidate.bm25Score)
                }
                .width(64)
                TableColumn("Vector") { candidate in
                    stage(rank: candidate.vectorRank, score: candidate.vectorScore)
                }
                .width(64)
                TableColumn("RRF") { candidate in
                    stage(rank: candidate.rrfRank, score: candidate.rrfScore)
                }
                .width(64)
                TableColumn("Rerank") { candidate in
                    stage(rank: candidate.rerankerRank, score: candidate.rerankerRelevance)
                }
                .width(64)
                TableColumn("Result") { candidate in
                    Text(result(candidate))
                        .foregroundStyle(candidate.selected ? .primary : .secondary)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Grade") { candidate in
                    if detail.evaluationCase != nil {
                        Picker(
                            "Relevance",
                            selection: Binding<UInt8?>(
                                get: { model.candidateRelevance(candidate) },
                                set: { model.setCandidateRelevance($0, candidate: candidate) }
                            )
                        ) {
                            Text("—").tag(UInt8?.none)
                            ForEach(UInt8(0) ... UInt8(3), id: \.self) { value in
                                Text(String(value)).tag(Optional(value))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    } else {
                        Text("—")
                    }
                }
                .width(54)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if detail.candidates.isEmpty {
                    ContentUnavailableView(
                        "No Candidates",
                        systemImage: "list.bullet.rectangle"
                    )
                }
            }
        }
    }

    private func stage(rank: UInt64?, score: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(self.rank(rank))
                .monospacedDigit()
            if let score {
                Text(score.formatted(.number.precision(.fractionLength(3))))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func rank(_ rank: UInt64?) -> String {
        rank.map { "#\($0)" } ?? "—"
    }

    private func result(_ candidate: RetrievalCandidate) -> String {
        candidate.selected
            ? candidate.deltaAction?.rawValue.capitalized ?? "Selected"
            : candidate.exclusionReason.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct RetrievalRunDetailsView: View {
    @ObservedObject var model: RetrievalDiagnosticsModel

    private var missedDrafts: [EvaluationJudgmentDraft] {
        model.judgmentDrafts.filter(\.missed)
    }

    var body: some View {
        if let detail = model.detail {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Run Details")
                        .font(.headline)
                    runDetail("Created", detail.run.createdAt)
                    runDetail("Run ID", detail.run.runId)
                    runDetail("Index", detail.run.indexRevision ?? "Unavailable")
                    runDetail("Parser", detail.run.parserVersion ?? "Unavailable")
                    runDetail("Chunker", detail.run.chunkerVersion ?? "Unavailable")
                    runDetail("Ranking profile", detail.run.rankingProfile ?? "Unavailable")
                    runDetail("Model", detail.run.modelRevision ?? "Unavailable")
                    Divider()
                    Text("Evaluation")
                        .font(.headline)
                    if let evaluationCase = detail.evaluationCase {
                        HStack {
                            Text("Judgment version \(evaluationCase.judgmentVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Save") {
                                Task { await model.saveJudgments() }
                            }
                            .disabled(model.isMutating)
                        }
                        Text("Missed Evidence")
                            .font(.subheadline.weight(.semibold))
                        Menu {
                            ForEach(detail.corpusResources) { resource in
                                Button(resource.path) {
                                    model.addMissedEvidence(resource)
                                }
                            }
                        } label: {
                            Label("Add Evidence", systemImage: "plus")
                        }
                        if missedDrafts.isEmpty {
                            Text("No missed evidence has been recorded.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(missedDrafts) { draft in
                                HStack {
                                    Text(
                                        detail.corpusResources.first {
                                            $0.resourceId == draft.resourceId
                                        }?.path ?? draft.resourceId
                                    )
                                    .lineLimit(2)
                                    Spacer()
                                    Picker(
                                        "Relevance",
                                        selection: Binding(
                                            get: { draft.relevance },
                                            set: { model.setMissedRelevance($0, draftId: draft.id) }
                                        )
                                    ) {
                                        ForEach(UInt8(0) ... UInt8(3), id: \.self) { value in
                                            Text(String(value)).tag(value)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    Button {
                                        model.removeMissedEvidence(draftId: draft.id)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove Missed Evidence")
                                }
                            }
                        }
                        if let report = detail.report, !report.variants.isEmpty {
                            Divider()
                            Text("Benchmark")
                                .font(.headline)
                            RetrievalBenchmarkSummary(report: report)
                        }
                    } else if detail.run.status == .succeeded {
                        Text("This Run is not in the Evaluation Set.")
                            .font(.subheadline.weight(.semibold))
                        Text("Freeze its Effective Memory corpus for relevance judgments.")
                            .foregroundStyle(.secondary)
                        Button("Add") {
                            Task { await model.createEvaluationCase() }
                        }
                        .disabled(model.isMutating)
                    } else {
                        Text("Only successful Retrieval Runs can become Evaluation Cases.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "Select a Retrieval Run",
                systemImage: "list.bullet.rectangle"
            )
        }
    }

    @ViewBuilder
    private func runDetail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .help(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private final class RetrievalRunDetailsWindowPresenter: NSObject, ObservableObject,
    NSWindowDelegate
{
    private var window: NSPanel?

    func present(model: RetrievalDiagnosticsModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(
            rootView: RetrievalRunDetailsView(model: model)
        )
        controller.sizingOptions = []
        let panel = NSPanel(
            contentRect: NSRect(
                origin: .zero,
                size: RetrievalRunDetailsWindowLayout.defaultContentSize
            ),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Run Details"
        panel.contentViewController = controller
        panel.contentMinSize = RetrievalRunDetailsWindowLayout.minimumContentSize
        panel.setContentSize(RetrievalRunDetailsWindowLayout.defaultContentSize)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private extension RetrievalRunStatus {
    var symbolName: String {
        switch self {
        case .running: "clock"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .running: .secondary
        case .succeeded: .green
        case .failed: .red
        }
    }
}

private struct RetrievalBenchmarkSummary: View {
    let report: RetrievalBenchmarkReport?

    var body: some View {
        if let report, !report.variants.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Variant")
                    Text("Recall@20")
                    Text("nDCG@10")
                    Text("MRR")
                }
                .font(.caption.weight(.semibold))
                ForEach(report.variants.keys.sorted(), id: \.self) { key in
                    if let metrics = report.variants[key] {
                        GridRow {
                            Text(key)
                            metric(metrics.recallAt20)
                            metric(metrics.ndcgAt10)
                            metric(metrics.mrr)
                        }
                    }
                }
            }
        }
    }

    private func metric(_ value: Double) -> some View {
        Text(value.formatted(.number.precision(.fractionLength(3))))
            .monospacedDigit()
    }
}

private func formatDuration(_ microseconds: UInt64) -> String {
    if microseconds >= 1_000_000 {
        return (Double(microseconds) / 1_000_000)
            .formatted(.number.precision(.fractionLength(2))) + " s"
    }
    if microseconds >= 1_000 {
        return (Double(microseconds) / 1_000)
            .formatted(.number.precision(.fractionLength(1))) + " ms"
    }
    return "\(microseconds) µs"
}

private extension NSSavePanel {
    var selectionResponse: NSApplication.ModalResponse {
        get async {
            await withCheckedContinuation { continuation in
                begin { continuation.resume(returning: $0) }
            }
        }
    }
}
