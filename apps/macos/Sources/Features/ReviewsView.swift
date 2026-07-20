import SwiftUI

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
    @State private var resolvedContent = ""
    @State private var resolvingConflict = false
    @State private var confirmsDiscard = false

    var body: some View {
        Group {
            if loading {
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

                        if review.conflict != nil, let detail, let changeSources {
                            ReviewConflictResolver(
                                sources: changeSources,
                                resolvedContent: $resolvedContent,
                                isWorking: resolvingConflict,
                                canResolve: store.isReviewAuthor(review),
                                onResolve: { resolve(detail, sources: changeSources) },
                                onDiscard: store.isReviewAuthor(review) ? { confirmsDiscard = true } : nil
                            )
                        }

                        if review.conflict == nil {
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
                            Button("Resubmit Review") { resubmit(detail) }
                                .buttonStyle(.borderedProminent)
                        } else if review.status == "approved" && review.conflict == nil && store.canMergeReviews {
                            Button("Merge Review") { merge() }
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
        .confirmationDialog(
            "Discard this conflicted draft?",
            isPresented: $confirmsDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Draft", role: .destructive) {
                if let detail { discard(detail) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The draft and its unresolved changes will be discarded. This cannot be undone.")
        }
    }

    private func load() async {
        loading = true
        do {
            let loadedDetail = try await store.reviewDetail(review.id)
            detail = loadedDetail
            let sources = try await store.reviewChangeSources(for: loadedDetail)
            changeSources = sources
            resolvedContent = sources.resolutionContent ?? ""
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
        Task {
            do {
                try await store.resubmit(review, detail: detail)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func resolve(_ detail: ReviewDetail, sources: ReviewChangeSources) {
        Task {
            resolvingConflict = true
            defer { resolvingConflict = false }
            do {
                try await store.resolveConflict(
                    review,
                    detail: detail,
                    resolvedContent: sources.resolutionContent == nil ? nil : resolvedContent
                )
                await load()
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func discard(_ detail: ReviewDetail) {
        Task {
            resolvingConflict = true
            defer { resolvingConflict = false }
            do {
                try await store.discardConflict(review, detail: detail)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ReviewConflictResolver: View {
    let sources: ReviewChangeSources
    @Binding var resolvedContent: String
    let isWorking: Bool
    let canResolve: Bool
    let onResolve: () -> Void
    let onDiscard: (() -> Void)?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("The project Ref changed after this draft was created.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                ForEach(sources.operationLabels, id: \.self) { label in
                    Text(label)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 10) {
                    source("Base", content: sources.baseContent)
                    source("Current", content: sources.currentContent)
                    source("Draft", content: sources.draftContent)
                }
                GroupBox("Resolved") {
                    if sources.resolutionContent != nil {
                        NativeTextEditor(text: $resolvedContent)
                            .frame(minHeight: 180)
                    } else {
                        Text(sources.operationLabels.last ?? "No editable content")
                            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                            .padding(6)
                    }
                }
                HStack {
                    if let onDiscard {
                        Button("Discard Draft", role: .destructive, action: onDiscard)
                    }
                    Spacer()
                    if isWorking { ProgressView().controlSize(.small) }
                    if canResolve {
                        Button("Reopen Review", action: onResolve)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .disabled(isWorking)
            }
            .padding(6)
        } label: {
            Text("Resolve Conflict")
        }
    }

    private func source(_ title: String, content: String?) -> some View {
        GroupBox(title) {
            ScrollView {
                Text(content ?? "Resource not present")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(content == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(6)
            }
            .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 180)
        }
        .frame(maxWidth: .infinity)
    }
}
