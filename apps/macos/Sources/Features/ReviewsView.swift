import SwiftUI

private enum ReviewReconciliationPurpose {
    case updateDraft
    case resubmit
}

struct ReviewNavigator: View {
    @ObservedObject var store: WorkspaceStore
    @Binding var statusFilter: String

    private var filteredReviews: [ReviewRecord] {
        statusFilter == "all" ? store.reviews : store.reviews.filter { $0.status == statusFilter }
    }

    var body: some View {
        List(selection: $store.selectedReviewId) {
            ForEach(filteredReviews) { review in
                VStack(alignment: .leading, spacing: 3) {
                    Text(review.title)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(review.status.capitalized)
                        Text("·")
                        Text(review.author.displayName ?? review.author.email)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .tag(review.id)
            }
        }
        .listStyle(.inset)
    }
}

struct ReviewDetailPane: View {
    @ObservedObject var store: WorkspaceStore
    let review: ReviewRecord?

    var body: some View {
        if let review {
            ReviewEditor(store: store, review: review)
                .id("\(review.id):\(review.version)")
        } else {
            ContentUnavailableView(
                "No Reviews",
                systemImage: "checkmark.bubble",
                description: Text("Reviews created from synchronized drafts appear here.")
            )
        }
    }
}

private struct ReviewEditor: View {
    @ObservedObject var store: WorkspaceStore
    let review: ReviewRecord

    @State private var detail: ReviewDetail?
    @State private var comment = ""
    @State private var decisionNote = ""
    @State private var loading = true
    @State private var changeSources: ReviewChangeSources?
    @State private var reconciliationCandidate: DraftReconciliationCandidate?
    @State private var loadsReconciliation = false
    @State private var reconciliationPurpose = ReviewReconciliationPurpose.updateDraft
    @State private var reconciliationInitialComparison = DraftReconciliationComparison.shared

    var body: some View {
        Group {
            if let candidate = reconciliationCandidate {
                DraftReconciliationView(
                    candidate: candidate,
                    initialComparison: reconciliationInitialComparison,
                    onCancel: { reconciliationCandidate = nil }
                ) { resolvedState in
                    guard let detail else {
                        throw ServerClientError.invalidResponse("Review detail is unavailable.")
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
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(review.title)
                                .font(.title2.weight(.semibold))
                                .lineLimit(2)
                            Spacer(minLength: 16)
                            Text(review.status.capitalized)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(review.description.isEmpty ? "No description" : review.description)
                            Text("Requested by \(review.author.displayName ?? review.author.email)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if review.freshness == .behind, let detail {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Shared memory has changed")
                                        .font(.callout.weight(.medium))
                                    Text("This review is based on an older shared version.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Review") {
                                    loadReconciliation(detail, comparison: .shared)
                                }
                                if store.isReviewAuthor(review) {
                                    Button("Update…") {
                                        loadReconciliation(detail, comparison: .result)
                                    }
                                        .buttonStyle(.borderedProminent)
                                }
                                if loadsReconciliation {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .padding(10)
                            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        }

                        GroupBox("Changes") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(changeSources?.operationLabels ?? [], id: \.self) { label in
                                    Text(label)
                                        .foregroundStyle(.secondary)
                                }
                                if let proposed = changeSources?.draftContent {
                                    ReviewDiffView(base: changeSources?.baseContent ?? "", proposed: proposed)
                                } else if changeSources?.operationLabels.isEmpty != false {
                                    Text("No content change")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }

                        if let detail {
                            GroupBox("Discussion") {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(detail.comments) { comment in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(comment.author.displayName ?? comment.author.email)
                                                .font(.caption.weight(.semibold))
                                            Text(comment.body)
                                        }
                                    }
                                    HStack(alignment: .bottom) {
                                        TextField("Add a comment", text: $comment, axis: .vertical)
                                        Button("Comment") { submitComment() }
                                            .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                            }
                        }

                        if review.status == "open" {
                            GroupBox("Decision") {
                                VStack(alignment: .leading, spacing: 10) {
                                    TextField("Optional note", text: $decisionNote, axis: .vertical)
                                    HStack {
                                        Button("Reject") { decide("rejected") }
                                        Button("Approve") { decide("approved") }
                                            .buttonStyle(.borderedProminent)
                                    }
                                }
                                .padding(6)
                            }
                        } else if review.status == "rejected", let detail, store.isReviewAuthor(review) {
                            Button("Resubmit") { resubmit(detail) }
                                .buttonStyle(.borderedProminent)
                        } else if review.status == "approved" && review.freshness == .current && store.canMergeReviews {
                            Button("Merge") { merge() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(24)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        do {
            let loadedDetail = try await store.reviewDetail(review.id)
            detail = loadedDetail
            let sources = try await store.reviewChangeSources(for: loadedDetail)
            changeSources = sources
        } catch {
            store.errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func submitComment() {
        let body = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        Task {
            do {
                try await store.addComment(body, to: review)
                comment = ""
                await load()
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func decide(_ decision: String) {
        Task {
            do {
                try await store.decide(review, decision: decision, note: decisionNote)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func merge() {
        Task {
            do {
                try await store.merge(review)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func resubmit(_ detail: ReviewDetail) {
        if detail.draft.coordination.freshness == .behind {
            loadReconciliation(detail, purpose: .resubmit, comparison: .result)
            return
        }
        Task {
            do {
                try await store.resubmit(review, detail: detail)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func loadReconciliation(
        _ detail: ReviewDetail,
        purpose: ReviewReconciliationPurpose = .updateDraft,
        comparison: DraftReconciliationComparison = .shared
    ) {
        guard !loadsReconciliation else { return }
        loadsReconciliation = true
        reconciliationPurpose = purpose
        reconciliationInitialComparison = comparison
        Task {
            defer { loadsReconciliation = false }
            do {
                reconciliationCandidate = try await store.reconciliationCandidate(for: detail)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }
}
