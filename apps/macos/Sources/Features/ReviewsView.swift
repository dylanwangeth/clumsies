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
    let onOpen: (ReviewRecord) -> Void

    var body: some View {
        Group {
            if store.reviews.isEmpty {
                ContentUnavailableView(
                    "No Reviews",
                    systemImage: "checkmark.bubble",
                    description: Text("Reviews created from synchronized drafts appear here.")
                )
            } else if reviews.isEmpty {
                ContentUnavailableView(
                    "No \(statusFilter.title) Reviews",
                    systemImage: "checkmark.bubble",
                    description: Text("Reviews with status \(statusFilter.title) will appear here.")
                )
            } else {
                List(reviews) { review in
                    ReviewRow(review: review, projectName: projectName(for: review))
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen(review) }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Reviews")
    }

    private func projectName(for review: ReviewRecord) -> String? {
        store.projects.first { $0.id == review.projectId }?.name
    }
}

struct ReviewRow: View {
    let review: ReviewRecord
    let projectName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(review.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                ReviewStatusBadge(status: review.status)
                if review.freshness == .behind {
                    DraftBaseBehindIndicator(reconciliation: review.reconciliation)
                }
                Spacer(minLength: 4)
            }
            Text(review.description.isEmpty ? "No description" : review.description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(meta)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
    }

    private var meta: String {
        let author = review.author.displayName ?? review.author.email
        let project = projectName ?? "—"
        let relative = IssueTiming.relativeText(review.updatedAt, relativeTo: .now) ?? "unknown"
        return "\(author) · \(project) · \(relative)"
    }
}

struct ReviewStatusBadge: View {
    let status: String

    var body: some View {
        Label {
            Text(status.capitalized)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(color)
        .labelStyle(.titleAndIcon)
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
        case "open": .accentColor
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

private enum ReviewReconciliationPurpose {
    case updateDraft
    case resubmit
}

struct ReviewDetailPage: View {
    @ObservedObject var store: WorkspaceStore
    let reviewId: String
    let orderedReviews: [ReviewRecord]
    let onNavigateToReview: (String) -> Void

    @State private var detail: ReviewDetail?
    @State private var changeSources: ReviewChangeSources?
    @State private var loading = true
    @State private var pendingAction: String?
    @State private var composing: ReviewCommentTarget?
    @State private var commentDraft = ""
    @State private var isSubmittingComment = false
    @State private var reconciliationCandidate: DraftReconciliationCandidate?
    @State private var loadsReconciliation = false
    @State private var reconciliationPurpose = ReviewReconciliationPurpose.updateDraft

    private var review: ReviewRecord? {
        store.reviews.first { $0.id == reviewId }
    }

    private var generalComments: [ReviewComment] {
        detail?.comments.filter { $0.anchorLine == nil } ?? []
    }

    private var commentsByLine: [Int: [ReviewComment]] {
        var result: [Int: [ReviewComment]] = [:]
        for comment in detail?.comments ?? [] {
            guard let line = comment.anchorLine else { continue }
            result[line, default: []].append(comment)
        }
        return result
    }

    var body: some View {
        Group {
            if let candidate = reconciliationCandidate {
                DraftReconciliationView(
                    candidate: candidate,
                    onCancel: { reconciliationCandidate = nil }
                ) { resolvedState in
                    guard let detail else {
                        throw ServerClientError.invalidResponse("Review detail is unavailable.")
                    }
                    guard let review else {
                        throw ServerClientError.invalidResponse("Review is unavailable.")
                    }
                    switch reconciliationPurpose {
                    case .updateDraft:
                        try await store.applyReconciliation(
                            draftId: detail.draft.draftId,
                            draftVersion: detail.draft.version,
                            candidate: candidate,
                            resolvedState: resolvedState
                        )
                    case .resubmit:
                        try await store.resubmit(
                            review,
                            detail: detail,
                            candidate: candidate,
                            resolvedState: resolvedState
                        )
                    }
                }
            } else if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let review {
                content(review)
            } else {
                ContentUnavailableView(
                    "Review Unavailable",
                    systemImage: "checkmark.bubble",
                    description: Text("This Review is no longer in the workspace.")
                )
            }
        }
        .task {
            await load()
        }
        .navigationTitle(review?.title ?? "Review")
        .onChange(of: store.pendingReviewReconciliationId) { _, reviewId in
            handlePendingReconciliation(reviewId)
        }
        .toolbar {
            if let review {
                decisionToolbar(review)
            }
        }
        .background {
            Button("Previous Review") { navigate(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            Button("Next Review") { navigate(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
    }

    private func content(_ review: ReviewRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(review)
                metaLine(review)
                Text(review.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(3)
                if !review.description.isEmpty {
                    Text(review.description)
                        .textSelection(.enabled)
                }
                Divider()
                changesSection(review)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
        }
    }

    private func header(_ review: ReviewRecord) -> some View {
        HStack(spacing: 10) {
            ReviewStatusBadge(status: review.status)
            Text("Version \(review.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let updated = IssueTiming.relativeText(review.updatedAt, relativeTo: .now) {
                Text("Updated \(updated)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func metaLine(_ review: ReviewRecord) -> some View {
        HStack(spacing: 8) {
            Text(metaText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if review.freshness == .behind {
                staleChip
            }
            Spacer(minLength: 0)
        }
    }

    private var metaText: String {
        let kind = detail.map { kindTitle($0.draft.resource.kind) } ?? ""
        let path = detail?.draft.resource.path ?? ""
        let author = review?.author.displayName ?? review?.author.email ?? ""
        let project = store.projects.first { $0.id == review?.projectId }?.name ?? "—"
        return "\(kind) · \(path) · by \(author) · \(project)"
    }

    private var staleChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(review?.reconciliation == .conflicts ? Color.orange : Color.secondary)
            Text(review?.reconciliation == .conflicts ? "Needs conflict resolution" : "Base is stale")
            Button("View Changes") {
                loadReconciliation(detail: detail, purpose: .updateDraft)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(
            review?.reconciliation == .conflicts
                ? "Draft conflicts with the shared version; resolve before deciding"
                : "Review base is behind the shared version; review changes before deciding"
        )
    }

    private func changesSection(_ review: ReviewRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Changes")
                .font(.headline)
            ForEach(changeSources?.operationLabels ?? [], id: \.self) { label in
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let proposed = changeSources?.draftContent {
                generalSlot
                UnifiedDiffView(
                    model: SplitDiffModel.make(
                        original: changeSources?.baseContent ?? "",
                        modified: proposed
                    ),
                    commentsByLine: commentsByLine,
                    composingLine: composingLine,
                    commentDraft: commentDraft,
                    isSubmittingComment: isSubmittingComment,
                    onCommentDraftChange: { commentDraft = $0 },
                    onRequestComment: { composing = .line($0) },
                    onCancelComment: { composing = nil; commentDraft = "" },
                    onSubmitComment: { line in Task { await submitComment(line: line) } },
                    onReply: { line in composing = .line(line) }
                )
                .frame(minHeight: 200)
            } else if changeSources?.operationLabels.isEmpty != false {
                Text("No content change")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var generalSlot: some View {
        VStack(alignment: .leading, spacing: 8) {
            if composing == .general {
                ReviewCommentComposer(
                    text: commentDraft,
                    isSubmitting: isSubmittingComment,
                    onTextChange: { commentDraft = $0 },
                    onCancel: { composing = nil; commentDraft = "" },
                    onSubmit: { Task { await submitComment(line: nil) } }
                )
            } else {
                Button {
                    composing = .general
                    commentDraft = ""
                } label: {
                    Label("Add a general comment", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .help("Comment on the review as a whole")
                .accessibilityLabel("Add a general comment")
            }
            ForEach(generalComments) { comment in
                ReviewCommentRow(comment: comment) {
                    composing = .general
                    commentDraft = ""
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composingLine: Int? {
        if case .line(let line) = composing { return line }
        return nil
    }

    private func decisionToolbar(_ review: ReviewRecord) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            switch review.status {
            case "open":
                Button {
                    decide("rejected")
                } label: {
                    if pendingAction == "rejected" {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Reject")
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(pendingAction != nil)
                .help("Reject this Review")
                .accessibilityLabel("Reject Review")
                Button {
                    decide("approved")
                } label: {
                    if pendingAction == "approved" {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Approve")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(pendingAction != nil)
                .help("Approve this Review")
                .accessibilityLabel("Approve Review")
            case "approved":
                if review.freshness == .current, store.canMergeReviews {
                    Button {
                        merge()
                    } label: {
                        if pendingAction == "merge" {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Merge")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(pendingAction != nil)
                    .help("Merge the approved changes")
                    .accessibilityLabel("Merge Review")
                }
            case "rejected":
                if store.isReviewAuthor(review) {
                    Button {
                        resubmit()
                    } label: {
                        if pendingAction == "resubmit" {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Resubmit")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(pendingAction != nil)
                    .help("Resubmit this Review")
                    .accessibilityLabel("Resubmit Review")
                }
            default:
                EmptyView()
            }
            Menu {
                Button("Copy Review ID") { copyReviewID() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .help("More Actions")
            .accessibilityLabel("More Actions")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let loadedDetail = try await store.reviewDetail(reviewId)
            detail = loadedDetail
            changeSources = try await store.reviewChangeSources(for: loadedDetail)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func refreshDetail() async {
        do {
            let loadedDetail = try await store.reviewDetail(reviewId)
            detail = loadedDetail
            changeSources = try await store.reviewChangeSources(for: loadedDetail)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func decide(_ decision: String) {
        guard let review else { return }
        pendingAction = decision
        Task {
            defer { pendingAction = nil }
            do {
                try await store.decide(review, decision: decision, note: "")
                await refreshDetail()
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func merge() {
        guard let review else { return }
        pendingAction = "merge"
        Task {
            defer { pendingAction = nil }
            do {
                try await store.merge(review)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func resubmit() {
        guard let detail else { return }
        guard let review else { return }
        if detail.draft.coordination.freshness == .behind {
            loadReconciliation(detail: detail, purpose: .resubmit)
            return
        }
        pendingAction = "resubmit"
        Task {
            defer { pendingAction = nil }
            do {
                try await store.resubmit(review, detail: detail)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func submitComment(line: Int?) async {
        guard let review, !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        isSubmittingComment = true
        defer { isSubmittingComment = false }
        do {
            try await store.addComment(
                commentDraft,
                to: review,
                anchorPath: detail?.draft.resource.path,
                anchorLine: line
            )
            composing = nil
            commentDraft = ""
            await refreshDetail()
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func loadReconciliation(detail: ReviewDetail?, purpose: ReviewReconciliationPurpose) {
        guard let detail, !loadsReconciliation else { return }
        loadsReconciliation = true
        reconciliationPurpose = purpose
        Task {
            defer { loadsReconciliation = false }
            do {
                reconciliationCandidate = try await store.reconciliationCandidate(for: detail)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func handlePendingReconciliation(_ reviewId: String?) {
        guard reviewId == self.reviewId, let detail else { return }
        store.pendingReviewReconciliationId = nil
        loadReconciliation(detail: detail, purpose: .updateDraft)
    }

    private func navigate(offset: Int) {
        guard let index = orderedReviews.firstIndex(where: { $0.id == reviewId }) else { return }
        let target = index + offset
        guard orderedReviews.indices.contains(target) else { return }
        let next = orderedReviews[target]
        store.selectedReviewId = next.id
        onNavigateToReview(next.id)
    }

    private func copyReviewID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reviewId, forType: .string)
    }

    private func kindTitle(_ kind: DaemonResourceKind) -> String {
        switch kind {
        case .context: "Context"
        case .rule: "Rule"
        case .workflow: "Workflow"
        }
    }
}

struct ReviewCommentRow: View {
    let comment: ReviewComment
    let onReply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(comment.author.displayName ?? comment.author.email)
                    .font(.caption.weight(.semibold))
                Text(IssueTiming.relativeText(comment.createdAt, relativeTo: .now) ?? comment.createdAt)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(comment.body)
                .font(.callout)
                .textSelection(.enabled)
            Button("Reply", action: onReply)
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReviewCommentComposer: View {
    let text: String
    let isSubmitting: Bool
    let onTextChange: (String) -> Void
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                "Write a comment…",
                text: Binding(get: { text }, set: onTextChange),
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
                .keyboardShortcut(.defaultAction)
                .disabled(
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
