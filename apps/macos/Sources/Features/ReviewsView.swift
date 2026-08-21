import AppKit
import SwiftUI

enum ReviewStatusFilter: String, CaseIterable, Identifiable {
    case open
    case approved
    case rejected
    case merged
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "Open"
        case .approved: "Approved"
        case .rejected: "Rejected"
        case .merged: "Merged"
        case .all: "All"
        }
    }

    var symbolName: String {
        switch self {
        case .open: "clock"
        case .approved: "checkmark.circle"
        case .rejected: "xmark.circle"
        case .merged: "arrow.triangle.merge"
        case .all: "tray.full"
        }
    }

    func matches(_ review: ReviewRecord) -> Bool {
        self == .all || review.status == rawValue
    }

    func count(in reviews: [ReviewRecord]) -> Int {
        reviews.lazy.filter(matches).count
    }
}

struct ReviewRoute: Hashable {
    let reviewId: String
}

struct ReviewToolbarOwnership: Equatable {
    enum Surface: Equatable {
        case list
        case detail
    }

    enum Item: Equatable {
        case filter
        case decision(ReviewMenuAction)
        case search
    }

    let surface: Surface
    let items: [Item]

    static func resolve(
        surface: Surface,
        review: ReviewRecord?,
        canDecideReviews: Bool,
        canMergeReviews: Bool,
        isAuthor: Bool
    ) -> Self {
        guard surface == .detail else {
            return .init(surface: .list, items: [.filter, .search])
        }

        let actions = review.map { review in
            [
                ReviewMenuAction.reject,
                .approve,
                .merge,
                .resubmit,
            ].filter {
                $0.isAvailable(
                    for: review,
                    canDecideReviews: canDecideReviews,
                    canMergeReviews: canMergeReviews,
                    isAuthor: isAuthor
                )
            }
        } ?? []

        return .init(
            surface: .detail,
            items: actions.map(Item.decision)
        )
    }

    func contains(_ item: Item) -> Bool {
        items.contains(item)
    }

    var hasDecisionActions: Bool {
        items.contains {
            if case .decision = $0 { return true }
            return false
        }
    }
}

struct ReviewStatusFilterControl: View {
    let reviews: [ReviewRecord]
    @Binding var selection: ReviewStatusFilter

    var body: some View {
        ToolbarFilterMenu(selectionTitle: selection.title) {
            ForEach(ReviewStatusFilter.allCases) { filter in
                Toggle(
                    label(for: filter),
                    isOn: Binding(
                        get: { selection == filter },
                        set: { isSelected in
                            guard isSelected else { return }
                            selection = filter
                        }
                    )
                )
            }
        }
        .help("Filter Reviews: \(label(for: selection))")
        .accessibilityLabel("Filter Reviews")
        .accessibilityValue(label(for: selection))
        .accessibilityIdentifier("review-toolbar-filter")
    }

    private func label(for filter: ReviewStatusFilter) -> String {
        "\(filter.title) (\(filter.count(in: reviews)))"
    }
}

struct ReviewListPage: View {
    @ObservedObject var store: WorkspaceStore
    let reviews: [ReviewRecord]
    @Binding var statusFilter: ReviewStatusFilter
    let toolbarOwnership: ReviewToolbarOwnership

    var body: some View {
        Group {
            switch ReviewListContentState.resolve(
                phase: store.phase,
                totalCount: store.reviews.count,
                visibleCount: reviews.count
            ) {
            case .loading:
                ProgressView("Loading Reviews…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView(
                    "No Reviews",
                    systemImage: "checkmark.bubble",
                    description: Text("Reviews created from synchronized drafts appear here.")
                )
            case .filteredEmpty:
                ContentUnavailableView {
                    Label("No \(statusFilter.title) Reviews", systemImage: statusFilter.symbolName)
                } description: {
                    Text("No Reviews match the current status filter.")
                } actions: {
                    Button("Show All Reviews") {
                        statusFilter = .all
                    }
                }
            case .content:
                List {
                    ForEach(reviews) { review in
                        let route = ReviewRoute(reviewId: review.id)
                        let state = ReviewQueueStatePresentation.resolve(
                            review: review,
                            isAuthor: store.isReviewAuthor(review),
                            canMerge: store.canMergeReviews
                        )
                        NavigationLink(value: route) {
                            ReviewRow(
                                review: review,
                                projectName: projectName(for: review),
                                state: state,
                                showsState: statusFilter == .all || state.isQueueSignal
                            )
                        }
                        .accessibilityIdentifier("review-row-\(review.id)")
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Reviews")
        .toolbar {
            if toolbarOwnership.contains(.filter) {
                ToolbarItem(id: "review.filter", placement: .navigation) {
                    ReviewStatusFilterControl(
                        reviews: store.reviews,
                        selection: $statusFilter
                    )
                }
            }
        }
    }

    private func projectName(for review: ReviewRecord) -> String? {
        store.projects.first { $0.id == review.projectId }?.name
    }

}

enum ReviewListContentState: Equatable {
    case loading
    case empty
    case filteredEmpty
    case content

    static func resolve(
        phase: ApplicationPhase,
        totalCount: Int,
        visibleCount: Int
    ) -> ReviewListContentState {
        if totalCount == 0 {
            return phase == .loading || phase == .launching ? .loading : .empty
        }
        return visibleCount == 0 ? .filteredEmpty : .content
    }
}

struct ReviewQueueStatePresentation: Equatable {
    enum Tone: Equatable {
        case neutral
        case positive
        case warning
        case negative

        var color: Color {
            switch self {
            case .neutral: .secondary
            case .positive: .green
            case .warning: .orange
            case .negative: .red
            }
        }
    }

    let title: String
    let symbolName: String
    let tone: Tone
    let isQueueSignal: Bool

    static func resolve(
        review: ReviewRecord,
        isAuthor: Bool,
        canMerge: Bool
    ) -> ReviewQueueStatePresentation {
        if review.status == "merged" {
            return .init(
                title: "Merged",
                symbolName: "arrow.triangle.merge",
                tone: .neutral,
                isQueueSignal: false
            )
        }
        if review.freshness == .behind, review.reconciliation == .conflicts {
            return .init(
                title: "Conflicts",
                symbolName: "exclamationmark.triangle",
                tone: .warning,
                isQueueSignal: true
            )
        }
        if review.freshness == .behind {
            return .init(
                title: isAuthor ? "Update Required" : "Out of Date",
                symbolName: "arrow.trianglehead.2.clockwise.rotate.90",
                tone: .warning,
                isQueueSignal: true
            )
        }

        switch review.status {
        case "open":
            return .init(
                title: "Needs Review",
                symbolName: "clock",
                tone: .neutral,
                isQueueSignal: false
            )
        case "approved"
            where canMerge && review.approvedResultHash?.isEmpty == false:
            return .init(
                title: "Ready to Merge",
                symbolName: "arrow.triangle.merge",
                tone: .positive,
                isQueueSignal: true
            )
        case "approved":
            return .init(
                title: "Approved",
                symbolName: "checkmark.circle",
                tone: .positive,
                isQueueSignal: false
            )
        case "rejected" where isAuthor:
            return .init(
                title: "Resubmit",
                symbolName: "arrow.clockwise.circle",
                tone: .negative,
                isQueueSignal: true
            )
        case "rejected":
            return .init(
                title: "Awaiting Author",
                symbolName: "clock",
                tone: .neutral,
                isQueueSignal: true
            )
        default:
            return .init(
                title: review.status.capitalized,
                symbolName: "circle",
                tone: .neutral,
                isQueueSignal: false
            )
        }
    }
}

struct ReviewRow: View {
    let review: ReviewRecord
    let projectName: String?
    let state: ReviewQueueStatePresentation
    let showsState: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(review.title)
                    .font(.body)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                if showsState {
                    ViewThatFits(in: .horizontal) {
                        Label(state.title, systemImage: state.symbolName)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Image(systemName: state.symbolName)
                    }
                    .font(.caption)
                    .foregroundStyle(state.tone.color)
                    .help(state.title)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(state.title)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let updatedAt = IssueTiming.date(from: review.updatedAt) {
                    Text(updatedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(IssueTiming.absoluteText(review.updatedAt) ?? "")
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var context: String {
        let author = review.author.displayName ?? review.author.email
        guard let projectName, !projectName.isEmpty else { return author }
        return "\(projectName) · \(author)"
    }

    private var accessibilityText: String {
        let relative = IssueTiming.relativeText(review.updatedAt, relativeTo: .now)
        let time = relative.map { ", updated \($0)" } ?? ""
        return "\(review.title), \(state.title), \(context)\(time)"
    }
}

struct ReviewStatusIndicator: View {
    let status: String
    var iconOnly = false

    @ViewBuilder
    var body: some View {
        if iconOnly {
            label
                .labelStyle(.iconOnly)
        } else {
            label
        }
    }

    private var label: some View {
        Label {
            Text(status.capitalized)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
        .font(.caption)
        .help("Status: \(status.capitalized)")
        .accessibilityLabel("Status: \(status.capitalized)")
    }

    private var symbol: String {
        switch status {
        case "open": "clock"
        case "approved": "checkmark.circle"
        case "rejected": "xmark.circle"
        case "merged": "arrow.triangle.merge"
        default: "circle"
        }
    }

    private var color: Color {
        switch status {
        case "open": .secondary
        case "approved": .green
        case "rejected": .red
        case "merged": .secondary
        default: .secondary
        }
    }
}

private enum ReviewCommentTarget: Hashable {
    case general
    case line(Int)
}

struct ReviewCommentPlacement: Equatable {
    let general: [ReviewComment]
    let byLine: [Int: [ReviewComment]]
    let unplaced: [ReviewComment]

    static func resolve(
        comments: [ReviewComment],
        activePath: String?,
        renderableLines: Set<Int>,
        minimumInlineVersion: Int
    ) -> ReviewCommentPlacement {
        var general: [ReviewComment] = []
        var byLine: [Int: [ReviewComment]] = [:]
        var unplaced: [ReviewComment] = []

        for comment in comments {
            switch (comment.anchorPath, comment.anchorLine) {
            case (nil, nil):
                general.append(comment)
            case let (path?, line?)
                where path == activePath
                    && renderableLines.contains(line)
                    && comment.reviewVersion >= minimumInlineVersion:
                byLine[line, default: []].append(comment)
            default:
                unplaced.append(comment)
            }
        }

        return .init(general: general, byLine: byLine, unplaced: unplaced)
    }

    static func minimumInlineVersion(reviewVersion: Int, status: String) -> Int {
        let lifecycleVersionsAfterContent: Int
        switch status {
        case "approved", "rejected":
            lifecycleVersionsAfterContent = 1
        case "merged":
            lifecycleVersionsAfterContent = 2
        default:
            lifecycleVersionsAfterContent = 0
        }
        return max(1, reviewVersion - lifecycleVersionsAfterContent)
    }
}

struct ReviewFileDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let path: String

    static func resolve(
        reviewId: String,
        detail: ReviewDetail,
        sources: ReviewChangeSources
    ) -> ReviewFileDescriptor {
        let path = sources.proposedPath ?? detail.draft.resource.path ?? "Untitled"
        let id = detail.draft.resource.id ?? "review-file:\(reviewId):\(path)"
        return .init(id: id, path: path)
    }
}

struct ReviewDetailPage: View {
    @ObservedObject var store: WorkspaceStore
    let reviewId: String
    let loadsRemoteContent: Bool

    @State private var detail: ReviewDetail?
    @State private var changeSources: ReviewChangeSources?
    @State private var diffModel: SplitDiffModel?
    @State private var loading = true
    @State private var loadError: String?
    @State private var composing: ReviewCommentTarget?
    @State private var commentDraft = ""
    @State private var isSubmittingComment = false
    @State private var reconciliationCandidate: DraftReconciliationCandidate?
    @State private var loadsReconciliation = false
    @State private var selectedFileId: String?
    @State private var showsGeneralComments = false
    @State private var detailRequestGeneration = UUID()

    private struct DetailRequest {
        let generation: UUID
        let baseline: ReviewDecisionReadiness?
    }

    private var review: ReviewRecord? {
        let loadedReview = detail.map { WorkspaceLoader.mapReview($0.review) }
        let storedReview = store.reviews.first { $0.id == reviewId }
        if let loadedReview, let storedReview {
            return storedReview.version >= loadedReview.version ? storedReview : loadedReview
        }
        return storedReview ?? loadedReview
    }

    private var storedReviewDecisionSignature: ReviewDecisionReadiness? {
        store.reviews.first { $0.id == reviewId }.map(ReviewDecisionReadiness.init)
    }

    private var commentPlacement: ReviewCommentPlacement {
        let loadedReview = detail?.review
        return ReviewCommentPlacement.resolve(
            comments: detail?.comments ?? [],
            activePath: changeSources?.proposedPath,
            renderableLines: Set(diffModel?.rows.compactMap { $0.modified?.lineNumber } ?? []),
            minimumInlineVersion: ReviewCommentPlacement.minimumInlineVersion(
                reviewVersion: loadedReview?.version ?? 1,
                status: loadedReview?.status ?? "open"
            )
        )
    }

    private var generalComments: [ReviewComment] {
        commentPlacement.general
    }

    private var commentsByLine: [Int: [ReviewComment]] {
        commentPlacement.byLine
    }

    private var unplacedComments: [ReviewComment] {
        commentPlacement.unplaced
    }

    var body: some View {
        Group {
            if let candidate = reconciliationCandidate {
                DraftReconciliationView(
                    candidate: candidate,
                    onCancel: {
                        reconciliationCandidate = nil
                        markCurrentDetailDecisionReady()
                    },
                    onApplied: {
                        reconciliationCandidate = nil
                        Task { await refreshDetail() }
                    }
                ) { resolvedState in
                    guard let detail else {
                        throw ServerClientError.invalidResponse("Review detail is unavailable.")
                    }
                    try await store.applyReconciliation(
                        draftId: detail.draft.draftId,
                        candidate: candidate,
                        resolvedState: resolvedState
                    )
                }
            } else if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView {
                    Label("Unable to Load Review", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") {
                        Task { await load() }
                    }
                }
            } else if let review, let detail, let changeSources {
                content(review, detail: detail, sources: changeSources)
            } else {
                ContentUnavailableView(
                    "Review Unavailable",
                    systemImage: "checkmark.bubble",
                    description: Text("This Review is no longer in the workspace.")
                )
            }
        }
        .task(id: reviewId) {
            guard loadsRemoteContent else {
                loading = false
                return
            }
            await load()
        }
        .onDisappear {
            invalidateDetailRequests()
        }
        .navigationTitle(review?.title ?? "Review")
        .onChange(of: store.pendingReviewReconciliationId) { _, reviewId in
            handlePendingReconciliation(reviewId)
        }
        .onChange(of: storedReviewDecisionSignature) { _, signature in
            guard let signature,
                  detail.map({ ReviewDecisionReadiness(review: WorkspaceLoader.mapReview($0.review)) })
                    != signature else { return }
            invalidateDetailRequests()
            Task { await refreshDetail() }
        }
    }

    private func content(
        _ review: ReviewRecord,
        detail: ReviewDetail,
        sources: ReviewChangeSources
    ) -> some View {
        let file = ReviewFileDescriptor.resolve(
            reviewId: reviewId,
            detail: detail,
            sources: sources
        )
        return HSplitView {
            ReviewFileNavigator(
                files: [file],
                selection: $selectedFileId
            )
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

            Group {
                if selectedFileId == nil || selectedFileId == file.id {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            reviewHeader(review)

                            if review.freshness == .behind {
                                readinessChip(review, detail: detail)
                            }

                            if showsGeneralComments {
                                generalCommentsPanel
                            }

                            diffPanel(detail: detail)
                        }
                        .frame(maxWidth: 1180, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .padding(.bottom, 48)
                    }
                } else {
                    ContentUnavailableView(
                        "Select a File",
                        systemImage: "doc.text",
                        description: Text("Choose a changed file from the file navigator.")
                    )
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear {
            if selectedFileId == nil {
                selectedFileId = file.id
            }
        }
    }

    private func reviewHeader(_ review: ReviewRecord) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(review.title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                Spacer(minLength: 16)

                ReviewStatusIndicator(status: review.status)

                Button(action: toggleGeneralComments) {
                    Image(systemName: reviewWideCommentCount == 0 ? "bubble.badge.plus" : "bubble")
                }
                .buttonStyle(.borderless)
                .help(reviewWideCommentCount == 0
                    ? "Add a review-wide comment"
                    : "Show \(reviewWideCommentCount) review-wide comments")
                .accessibilityLabel(reviewWideCommentCount == 0
                    ? "Add a review-wide comment"
                    : "Show \(reviewWideCommentCount) review-wide comments")
            }

            metadata(review)

            let description = review.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty {
                Text(description)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if review.status != "open" {
                decisionSummary(review)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadata(_ review: ReviewRecord) -> some View {
        let author = review.author.displayName ?? review.author.email
        let project = store.projects.first { $0.id == review.projectId }?.name
        let context = [author, project]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let updated = IssueTiming.relativeText(review.updatedAt, relativeTo: .now)
            .map { " · Updated \($0)" } ?? ""
        return Text("\(context)\(updated)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readinessChip(_ review: ReviewRecord, detail: ReviewDetail) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(
                review.reconciliation == .conflicts
                    ? "Resolve conflicts before deciding"
                    : "The shared version changed",
                systemImage: review.reconciliation == .conflicts
                    ? "exclamationmark.triangle"
                    : "arrow.trianglehead.2.clockwise.rotate.90"
            )
            .foregroundStyle(review.reconciliation == .conflicts ? Color.orange : Color.secondary)

            Spacer(minLength: 8)

            Button("Review Changes…") {
                loadReconciliation(detail: detail)
            }
            .controlSize(.small)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .help(
            review.reconciliation == .conflicts
                ? "Draft conflicts with the shared version; resolve before deciding"
                : "Review base is behind the shared version; review changes before deciding"
        )
    }

    private func decisionSummary(_ review: ReviewRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: decisionSymbol(review.status))
                    .foregroundStyle(decisionColor(review.status))
                Text(decisionTitle(review.status))
                    .font(.callout.weight(.semibold))
                if let decider = review.decidedBy {
                    Text("· Decision by \(decider.displayName ?? decider.email)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let decidedAt = review.decidedAt,
                   let relativeDecisionTime = IssueTiming.relativeText(decidedAt, relativeTo: .now) {
                    Text("· \(relativeDecisionTime)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(IssueTiming.absoluteText(decidedAt).map {
                            "Decision recorded at \($0)"
                        } ?? "Decision time")
                }
            }

            if let body = review.decisionBody?.trimmingCharacters(in: .whitespacesAndNewlines),
               !body.isEmpty {
                Text(body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let hash = review.approvedResultHash, !hash.isEmpty {
                HStack(spacing: 6) {
                    Text("Result")
                        .foregroundStyle(.secondary)
                    Text(hash)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        copy(hash)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy result hash")
                    .accessibilityLabel("Copy result hash")
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var generalCommentsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Review comments")
                    .font(.headline)

                Spacer()

                if composing != .general {
                    Button {
                        composing = .general
                        commentDraft = ""
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add a review-wide comment")
                    .accessibilityLabel("Add a review-wide comment")
                }
            }

            if composing == .general {
                ReviewCommentComposer(
                    text: $commentDraft,
                    isSubmitting: isSubmittingComment,
                    onCancel: { composing = nil; commentDraft = "" },
                    onSubmit: { Task { await submitComment(line: nil) } }
                )
            }

            ForEach(generalComments) { comment in
                ReviewCommentRow(comment: comment) {
                    composing = .general
                    commentDraft = ""
                }
            }

            if !unplacedComments.isEmpty {
                Text("Comments from an earlier revision or file path")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(unplacedComments) { comment in
                    VStack(alignment: .leading, spacing: 4) {
                        if let path = comment.anchorPath, let line = comment.anchorLine {
                            Text("\(path):\(line)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        ReviewCommentRow(comment: comment) {
                            composing = .general
                            commentDraft = ""
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func diffPanel(detail: ReviewDetail) -> some View {
        if detail.operations.last?.action == "delete" {
            Label {
                Text("This Review deletes the selected memory. There is no proposed file to render.")
            } icon: {
                Image(systemName: "trash")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 20)
        } else if let diffModel {
            UnifiedDiffView(
                model: diffModel,
                commentsByLine: commentsByLine,
                composingLine: composingLine,
                commentDraft: $commentDraft,
                isSubmittingComment: isSubmittingComment,
                onRequestComment: { composing = .line($0) },
                onCancelComment: { composing = nil; commentDraft = "" },
                onSubmitComment: { line in Task { await submitComment(line: line) } },
                onReply: { line in composing = .line(line) }
            )
        } else {
            Text("This Review changes metadata without changing text content.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 20)
        }
    }

    private var reviewWideCommentCount: Int {
        generalComments.count + unplacedComments.count
    }

    private func toggleGeneralComments() {
        if showsGeneralComments {
            showsGeneralComments = false
            return
        }

        showsGeneralComments = true
        if reviewWideCommentCount == 0 {
            composing = .general
            commentDraft = ""
        }
    }

    private var composingLine: Int? {
        if case .line(let line) = composing { return line }
        return nil
    }

    private func load() async {
        let request = beginDetailRequest()
        loading = true
        loadError = nil
        detail = nil
        changeSources = nil
        diffModel = nil
        composing = nil
        commentDraft = ""
        selectedFileId = nil
        showsGeneralComments = false
        defer {
            if detailRequestGeneration == request.generation {
                loading = false
            }
        }
        do {
            let loadedDetail = try await store.reviewDetail(reviewId)
            let loadedSources = try await store.reviewChangeSources(for: loadedDetail)
            applyLoadedDetail(
                loadedDetail,
                sources: loadedSources,
                request: request
            )
        } catch {
            guard !Task.isCancelled,
                  detailRequestGeneration == request.generation else { return }
            clearDecisionReadiness()
            loadError = error.localizedDescription
            store.errorMessage = error.localizedDescription
        }
    }

    private func refreshDetail() async {
        let request = beginDetailRequest()
        do {
            let loadedDetail = try await store.reviewDetail(reviewId)
            let loadedSources = try await store.reviewChangeSources(for: loadedDetail)
            applyLoadedDetail(
                loadedDetail,
                sources: loadedSources,
                request: request
            )
        } catch {
            guard !Task.isCancelled,
                  detailRequestGeneration == request.generation else { return }
            clearDecisionReadiness()
            if detail == nil {
                loading = false
                loadError = error.localizedDescription
            }
            store.errorMessage = error.localizedDescription
        }
    }

    private func beginDetailRequest() -> DetailRequest {
        clearDecisionReadiness()
        let generation = UUID()
        detailRequestGeneration = generation
        return DetailRequest(
            generation: generation,
            baseline: storedReviewDecisionSignature
        )
    }

    private func invalidateDetailRequests() {
        detailRequestGeneration = UUID()
        clearDecisionReadiness()
    }

    private func clearDecisionReadiness() {
        if store.reviewDecisionReadiness?.reviewId == reviewId {
            store.reviewDecisionReadiness = nil
        }
    }

    private func applyLoadedDetail(
        _ loadedDetail: ReviewDetail,
        sources loadedSources: ReviewChangeSources,
        request: DetailRequest
    ) {
        guard !Task.isCancelled,
              detailRequestGeneration == request.generation,
              storedReviewDecisionSignature == request.baseline else { return }
        let loadedReview = WorkspaceLoader.mapReview(loadedDetail.review)
        let loadedSignature = ReviewDecisionReadiness(review: loadedReview)
        if let baseline = request.baseline,
           loadedReview.version < baseline.reviewVersion {
            loading = false
            loadError = "The Review changed while its detail was loading. Try again."
            return
        }

        detail = loadedDetail
        changeSources = loadedSources
        diffModel = makeDiffModel(from: loadedSources)
        loading = false
        loadError = nil
        selectedFileId = ReviewFileDescriptor.resolve(
            reviewId: reviewId,
            detail: loadedDetail,
            sources: loadedSources
        ).id
        store.replaceReview(with: loadedReview)
        store.reviewDecisionReadiness = loadedSignature
    }

    private func markCurrentDetailDecisionReady() {
        guard let detail else {
            clearDecisionReadiness()
            return
        }
        let loadedReview = WorkspaceLoader.mapReview(detail.review)
        guard storedReviewDecisionSignature == ReviewDecisionReadiness(review: loadedReview) else {
            clearDecisionReadiness()
            return
        }
        store.reviewDecisionReadiness = ReviewDecisionReadiness(review: loadedReview)
    }

    private func submitComment(line: Int?) async {
        guard let detail,
              !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let renderedReview = WorkspaceLoader.mapReview(detail.review)
        let anchorPath = line == nil ? nil : changeSources?.proposedPath
        guard line == nil || anchorPath != nil else {
            store.errorMessage = "The proposed file path is unavailable for this line comment."
            return
        }
        isSubmittingComment = true
        defer { isSubmittingComment = false }
        do {
            try await store.addComment(
                commentDraft,
                to: renderedReview,
                anchorPath: anchorPath,
                anchorLine: line
            )
            composing = nil
            commentDraft = ""
            await refreshDetail()
        } catch {
            store.errorMessage = error.localizedDescription
            if let serverError = error as? ServerClientError,
               case .response(let status, _) = serverError,
               status == 409 {
                await refreshDetail()
            }
        }
    }

    private func loadReconciliation(detail: ReviewDetail?) {
        guard let detail, !loadsReconciliation else { return }
        clearDecisionReadiness()
        loadsReconciliation = true
        Task {
            defer { loadsReconciliation = false }
            do {
                reconciliationCandidate = try await store.reconciliationCandidate(for: detail)
            } catch {
                markCurrentDetailDecisionReady()
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func handlePendingReconciliation(_ reviewId: String?) {
        guard reviewId == self.reviewId, let detail else { return }
        store.pendingReviewReconciliationId = nil
        loadReconciliation(detail: detail)
    }

    private func makeDiffModel(from sources: ReviewChangeSources) -> SplitDiffModel? {
        guard let proposed = sources.draftContent else { return nil }
        return SplitDiffModel.make(
            original: sources.baseContent ?? "",
            modified: proposed
        )
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func decisionTitle(_ status: String) -> String {
        switch status {
        case "approved": "Approved"
        case "rejected": "Changes requested"
        case "merged": "Merged"
        default: status.capitalized
        }
    }

    private func decisionSymbol(_ status: String) -> String {
        switch status {
        case "approved": "checkmark.circle.fill"
        case "rejected": "xmark.circle.fill"
        case "merged": "arrow.triangle.merge"
        default: "circle.fill"
        }
    }

    private func decisionColor(_ status: String) -> Color {
        switch status {
        case "approved": .green
        case "rejected": .red
        default: .secondary
        }
    }

}

private struct ReviewFileNavigator: View {
    let files: [ReviewFileDescriptor]
    @Binding var selection: String?

    var body: some View {
        PathTreeView(
            items: files.map { PathTreeItem(id: $0.id, path: $0.path) },
            selection: $selection
        )
        .accessibilityIdentifier("review-file-tree")
    }
}

struct ReviewCommentRow: View {
    let comment: ReviewComment
    let onReply: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            AvatarView(account: comment.author)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author.displayName ?? comment.author.email)
                        .font(.caption.weight(.semibold))
                    Text(
                        IssueTiming.relativeText(comment.createdAt, relativeTo: .now)
                            ?? comment.createdAt
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                    Spacer(minLength: 8)

                    Button(action: onReply) {
                        Image(systemName: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Reply")
                    .accessibilityLabel("Reply")
                }
                Text(comment.body)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReviewCommentComposer: View {
    @Binding var text: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                "Write a comment…",
                text: $text,
                axis: .vertical
            )
            .lineLimit(2...6)
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button {
                    onSubmit()
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Comment")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
