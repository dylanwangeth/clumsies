import AppKit
import SwiftUI

extension ToolbarItemPlacement {
    /// Pins toolbar content to the trailing edge on both macOS 14 (where
    /// `.primaryAction` is trailing) and macOS 26 Liquid Glass (where
    /// primary-action items render centered and the trailing edge is reached
    /// with `.automatic` items pushed by a `ToolbarSpacer(.flexible)`).
    static var trailingPinned: ToolbarItemPlacement {
        if #available(macOS 26.0, *) { return .automatic }
        return .primaryAction
    }
}

enum SyncToolbarPresentation: Equatable {
    case syncing(changeCount: Int)
    case failed(changeCount: Int, message: String?)
    case unavailable(message: String?)
    case stale

    static func resolve(
        status: DaemonSyncStatus?,
        isAvailable: Bool,
        serverDataSource: String?
    ) -> Self? {
        guard isAvailable else { return .unavailable(message: nil) }

        if let status {
            if status.failedOperationCount > 0 || status.draftSync.state == "failed" {
                return .failed(
                    changeCount: status.failedOperationCount,
                    message: status.draftSync.lastError?.message
                )
            }
            if status.draftSync.state == "degraded" {
                return .unavailable(message: status.draftSync.lastError?.message)
            }
            if status.pendingOperationCount > 0
                || ["queued", "syncing", "retrying"].contains(status.draftSync.state) {
                return .syncing(changeCount: status.pendingOperationCount)
            }
            if ["failed", "degraded"].contains(status.commitSync.state) {
                return .unavailable(message: status.commitSync.lastError?.message)
            }
        }

        if serverDataSource == "stale" { return .stale }
        return nil
    }

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }

    var symbolName: String {
        switch self {
        case .syncing: "arrow.triangle.2.circlepath"
        case .failed: "cloud.exclamationmark"
        case .unavailable: "icloud.slash"
        case .stale: "icloud.slash"
        }
    }

    var label: String {
        switch self {
        case .syncing(let count):
            count == 1
                ? "Uploading 1 Draft change"
                : count > 1 ? "Uploading \(count) Draft changes" : "Uploading Draft changes"
        case .failed:
            "Sync failed"
        case .unavailable:
            "Sync unavailable"
        case .stale:
            "Showing cached data"
        }
    }

    var detail: String {
        switch self {
        case .syncing:
            return "Clumsies is uploading Project-carried Draft changes in the background."
        case .failed(let count, let message):
            if let message, !message.isEmpty { return message }
            return count == 1
                ? "One change could not be synchronized."
                : count > 1
                    ? "\(count) changes could not be synchronized."
                    : "Clumsies could not synchronize with the server."
        case .unavailable(let message):
            if let message, !message.isEmpty { return message }
            return "Clumsies could not read sync status from the background service."
        case .stale:
            return "Clumsies is showing cached Server data because the latest data could not be reached. Local edits remain saved."
        }
    }
}

enum WorkspaceColumnLayout: Equatable {
    case sidebarDetail
    case sidebarContentDetail

    init(section: WorkspaceSection) {
        self = section == .issues || section == .reviews
            ? .sidebarDetail
            : .sidebarContentDetail
    }
}

private enum DocumentSyncReadiness {
    case ready
    case pending
    case failed
    case unavailable
}

struct IssueBoardRoute: Hashable {
    let issueId: String
}

struct WorkspaceView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpenSettings: () -> Void
    let onOpenDiagnostics: (DiagnosticsDestination) -> Void
    let onShowLogs: () -> Void
    let loadsReviewDetail: Bool
    @StateObject private var issueBoardModel: IssueBoardModel
    @StateObject private var recallModel: RecallModel
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @State private var issueSplitVisibility: NavigationSplitViewVisibility = .all
    @State private var reviewSplitVisibility: NavigationSplitViewVisibility = .all
    @State private var recallSplitVisibility: NavigationSplitViewVisibility = .all
    @State private var showsBundleResourcePicker = false
    @State private var confirmsBundleDeletion = false
    @State private var showsSyncIssuePopover = false
    @State private var showsUnlinkedActivity = false
    @State private var showsIssueWorkflowHelp = false
    @State private var issueNavigationPath: [IssueBoardRoute] = []
    @State private var reviewNavigationPath: [ReviewRoute] = []
    @State private var workspaceSearchFocusRequest = 0
    @State private var issueSearchFocusRequest = 0
    @State private var reviewSearchQuery = ""
    @State private var reviewSearchFocusRequest = 0
    @State private var reviewStatusFilter: ReviewStatusFilter = .open
    @State private var pendingReviewToolbarAction: ReviewMenuAction?

    init(
        store: WorkspaceStore,
        onOpenSettings: @escaping () -> Void,
        onOpenDiagnostics: @escaping (DiagnosticsDestination) -> Void,
        onShowLogs: @escaping () -> Void,
        loadsReviewDetail: Bool = true
    ) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.onOpenDiagnostics = onOpenDiagnostics
        self.onShowLogs = onShowLogs
        self.loadsReviewDetail = loadsReviewDetail
        _issueBoardModel = StateObject(wrappedValue: IssueBoardModel(daemon: store.daemon))
        _recallModel = StateObject(wrappedValue: RecallModel(daemon: store.daemon))
    }

    private var showsDocumentTabs: Bool {
        store.selectedSection == .memory
            && !store.visibleTabs.isEmpty
            && !store.showsProjectSettings
    }

    private var documentReconciliationState: DocumentReconciliationToolbarState? {
        guard let state = store.documentReconciliationToolbarState,
              let currentItem = store.currentItem,
              state.sessionKey == store.documentSessionKey(for: currentItem) else { return nil }
        return state
    }

    var body: some View {
        Group {
            switch store.selectedSection {
            case .issues:
                issuesWorkspace
            case .reviews:
                reviewsWorkspace
            case .sessions:
                recallWorkspace
            default:
                regularWorkspace
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let message = store.errorMessage {
                WorkspaceOperationErrorBanner(message: message) {
                    store.dismissErrorMessage()
                }
            }
        }
        .onChange(of: store.selectedSection) { _, _ in
            store.searchQuery = ""
        }
    }

    private var regularWorkspace: some View {
        NavigationSplitView(columnVisibility: $splitVisibility) {
                GlobalSidebar(
                    store: store,
                    onOpenSettings: onOpenSettings,
                    onOpenDiagnostics: onOpenDiagnostics,
                    onShowLogs: onShowLogs
                )
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
            } content: {
                navigator
                    .navigationSplitViewColumnWidth(min: 288, ideal: 300, max: 380)
                    .toolbar {
                        navigationToolbarContent
                    }
            } detail: {
                VStack(spacing: 0) {
                    detail
                        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                }
                .toolbar {
                    if showsDocumentTabs {
                        ToolbarItemGroup {
                            Button {
                                if let state = documentReconciliationState {
                                    store.pendingDocumentCommand = .closeReconciliation(
                                        sessionKey: state.sessionKey
                                    )
                                } else {
                                    store.goBack()
                                }
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .disabled(
                                documentReconciliationState?.isUpdating == true
                                    || (documentReconciliationState == nil && !store.canGoBack)
                            )
                            .help(documentReconciliationState == nil ? "Go Back" : "Back to Document")
                            .accessibilityLabel(
                                documentReconciliationState == nil ? "Go Back" : "Back to Document"
                            )

                            Button {
                                store.goForward()
                            } label: {
                                Image(systemName: "chevron.right")
                            }
                            .disabled(documentReconciliationState != nil || !store.canGoForward)
                            .help("Go Forward")
                            .accessibilityLabel("Go Forward")
                        }

                        if #available(macOS 26.0, *) {
                            ToolbarSpacer(.flexible)
                        }
                    }

                    if #available(macOS 26.0, *), !showsDocumentTabs {
                        ToolbarSpacer(.flexible)
                    }

                    ToolbarItemGroup(placement: .trailingPinned) {
                        if store.selectedSection == .bundles, store.selectedBundle != nil {
                            Button {
                                showsBundleResourcePicker = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .help("Add Memory")

                            Menu {
                                Button("Delete Bundle", role: .destructive) {
                                    confirmsBundleDeletion = true
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuIndicator(.hidden)
                            .help("Bundle Actions")
                        }

                        if let syncToolbarPresentation {
                            switch syncToolbarPresentation {
                            case .syncing:
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 24, height: 24)
                                    .help(syncToolbarPresentation.label)
                                    .accessibilityLabel(syncToolbarPresentation.label)
                            case .failed, .unavailable, .stale:
                                Button {
                                    showsSyncIssuePopover.toggle()
                                } label: {
                                    Image(systemName: syncToolbarPresentation.symbolName)
                                        .foregroundStyle(syncToolbarPresentation.tint)
                                }
                                .help(syncToolbarPresentation.label)
                                .accessibilityLabel(syncToolbarPresentation.label)
                                .popover(isPresented: $showsSyncIssuePopover, arrowEdge: .top) {
                                    SyncIssuePopover(
                                        presentation: syncToolbarPresentation,
                                        store: store
                                    )
                                }
                            }
                        }

                        if showsDocumentTabs, let item = store.currentItem {
                            if let state = documentReconciliationState {
                                if state.isLoading || state.isUpdating {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 24, height: 24)
                                        .help(state.isLoading ? "Reviewing changes" : "Syncing")
                                        .accessibilityLabel(
                                            state.isLoading ? "Reviewing changes" : "Syncing"
                                        )
                                } else {
                                    Button {
                                        store.pendingDocumentCommand = .applyReconciliation(
                                            sessionKey: state.sessionKey
                                        )
                                    } label: {
                                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                                    }
                                    .disabled(!state.canUpdate)
                                    .help("Sync")
                                    .accessibilityLabel("Sync")
                                }
                            }

                            if documentReconciliationState == nil, documentNeedsSync {
                                switch documentSyncReadiness {
                                case .pending:
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 24, height: 24)
                                        .help("Saving draft changes before sync")
                                        .accessibilityLabel("Saving draft changes before sync")
                                case .failed:
                                    if store.isRetryingSync(
                                        channel: "drafts",
                                        projectId: item.draft?.projectId ?? store.activeProjectId
                                    ) {
                                        ProgressView()
                                            .controlSize(.small)
                                            .frame(width: 24, height: 24)
                                            .help("Retrying Draft Sync")
                                            .accessibilityLabel("Retrying Draft Sync")
                                    } else {
                                        Button {
                                            Task {
                                                _ = await store.retrySync(
                                                    channel: "drafts",
                                                    projectId: item.draft?.projectId
                                                        ?? store.activeProjectId
                                                )
                                            }
                                        } label: {
                                            Image(systemName: "arrow.clockwise")
                                        }
                                        .help("Retry Draft Sync")
                                        .accessibilityLabel("Retry Draft Sync")
                                    }
                                case .unavailable:
                                    Button {} label: {
                                        Image(systemName: "exclamationmark.triangle")
                                    }
                                    .disabled(true)
                                    .help("Draft is not available on the server yet")
                                    .accessibilityLabel("Draft is not available on the server yet")
                                case .ready:
                                    Button {
                                        store.syncDocument(item)
                                    } label: {
                                        Image(systemName: item.draft?.reconciliation == .conflicts
                                            ? "exclamationmark.triangle"
                                            : "arrow.trianglehead.2.clockwise.rotate.90")
                                    }
                                    .help("Sync")
                                    .accessibilityLabel("Sync")
                                }
                            }

                            Picker("Document View", selection: documentMode) {
                                ForEach(availableDocumentModes, id: \.self) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(
                                documentReconciliationState != nil
                                    || availableDocumentModes.count < 2
                                    || store.isSynchronizingDocument(item.id)
                            )
                            .help("Document View")
                            .accessibilityLabel("Document View")

                            if hasDocumentActions(item) {
                                Menu {
                                    if canRequestDocumentReview(item),
                                       let draft = item.draft,
                                       let sessionKey = store.documentSessionKey(for: item) {
                                        Button("Request Review") {
                                            store.pendingDocumentCommand = .requestReview(
                                                sessionKey: sessionKey,
                                                draft: draft
                                            )
                                        }
                                        Divider()
                                    }
                                    if canDiscardDocumentDraft(item),
                                       let draft = item.draft,
                                       let sessionKey = store.documentSessionKey(for: item) {
                                        Button("Discard Draft") {
                                            store.pendingDocumentCommand = .discardDraft(
                                                sessionKey: sessionKey,
                                                draft: draft
                                            )
                                        }
                                    }
                                    if canProposeOrganizationDeletion(item),
                                       let sessionKey = store.documentSessionKey(for: item) {
                                        Button(
                                            "Propose Organization Deletion",
                                            role: .destructive
                                        ) {
                                            store.pendingDocumentCommand = .moveToTrash(
                                                sessionKey: sessionKey
                                            )
                                        }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .disabled(store.isSynchronizingDocument(item.id))
                                .menuIndicator(.hidden)
                                .help("Document Actions")
                                .accessibilityLabel("Document Actions")
                            }
                        }
                    }

                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .automatic)
                    }

                    ToolbarItem(id: "workspace.search", placement: .trailingPinned) {
                        ClassicSearchField(
                            text: $store.searchQuery,
                            prompt: workspaceSearchPrompt,
                            accessibilityIdentifier: "workspace-toolbar-search",
                            accessibilityHelp: "Search across the current workspace",
                            focusToken: workspaceSearchFocusRequest
                        )
                    }
                }
            }
        .onAppear {
            let target: NavigationSplitViewVisibility = store.sidebarExpanded ? .all : .doubleColumn
            if splitVisibility != target {
                splitVisibility = target
            }
        }
        .onChange(of: store.workspaceSearchFocusToken) { _, _ in
            workspaceSearchFocusRequest += 1
        }
        .onChange(of: store.searchQuery) { _, query in
            guard store.selectedSection == .memory,
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { await store.prepareWorkspaceIndex(includeContent: true) }
        }
        .onChange(of: store.selectedSection) { _, section in
            if section != .memory {
                store.showsProjectSettings = false
            }
        }
        .onChange(of: splitVisibility) { _, visibility in
            if visibility == .all {
                store.sidebarExpanded = true
            } else if visibility == .doubleColumn || visibility == .detailOnly {
                store.sidebarExpanded = false
            }
        }
        .onChange(of: store.sidebarExpanded) { _, expanded in
            let target: NavigationSplitViewVisibility = expanded ? .all : .doubleColumn
            if splitVisibility != target {
                splitVisibility = target
            }
        }
        .onChange(of: syncToolbarPresentation) { _, presentation in
            if presentation == nil || presentation?.isSyncing == true {
                showsSyncIssuePopover = false
            }
        }
        .task {
            while !Task.isCancelled {
                await store.refreshSyncStatus()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
        .sheet(isPresented: $store.showsProjectCreation) {
            ProjectCreationSheet(store: store)
        }
    }

    private func issueDetailView(for route: IssueBoardRoute) -> some View {
        IssueDetailView(
            issueId: route.issueId,
            model: issueBoardModel,
            members: store.projectMembers,
            onGate: { action, issue in
                Task {
                    do {
                        try await issueBoardModel.applyGate(action, to: issue)
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                }
            },
            onAssign: { issue, member in
                try await store.assignIssue(issue, to: member)
                await issueBoardModel.refresh()
            },
            onUnclaim: { issue in
                Task {
                    do {
                        try await issueBoardModel.unclaim(issue)
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                }
            },
            onResume: { issue in
                Task {
                    do {
                        try await issueBoardModel.resume(issue)
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                }
            },
            onToggleVerificationStep: { issue, index, completed in
                Task {
                    do {
                        try await issueBoardModel.setVerificationStep(
                            completed,
                            stepIndex: index,
                            issue: issue
                        )
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                }
            },
            onArchive: nil,
            onDelete: nil
        )
    }

    private var reviewsWorkspace: some View {
        NavigationSplitView(columnVisibility: $reviewSplitVisibility) {
            GlobalSidebar(
                store: store,
                onOpenSettings: onOpenSettings,
                onOpenDiagnostics: onOpenDiagnostics,
                onShowLogs: onShowLogs
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            NavigationStack(path: $reviewNavigationPath) {
                ReviewListPage(
                    store: store,
                    reviews: filteredReviews,
                    searchQuery: reviewSearchQuery,
                    statusFilter: $reviewStatusFilter,
                    toolbarOwnership: reviewToolbarOwnership
                )
                .navigationDestination(for: ReviewRoute.self) { route in
                    ReviewDetailPage(
                        store: store,
                        reviewId: route.reviewId,
                        loadsRemoteContent: loadsReviewDetail
                    )
                    .toolbar {
                        if reviewToolbarOwnership.surface == .detail {
                            reviewDetailToolbarContent
                        }
                    }
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                if reviewToolbarOwnership.surface == .list {
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible, placement: .automatic)
                    }

                    reviewUtilityToolbarContent(hasLeadingActions: false)
                }
            }
        }
        .onAppear {
            store.showsProjectSettings = false
            let target: NavigationSplitViewVisibility = store.sidebarExpanded ? .all : .detailOnly
            if reviewSplitVisibility != target {
                reviewSplitVisibility = target
            }

            if let routedReviewId = reviewNavigationPath.last?.reviewId,
               !store.reviews.contains(where: { $0.id == routedReviewId }) {
                reviewNavigationPath.removeAll()
            }
            if reviewNavigationPath.isEmpty,
               let reviewId = store.selectedReviewId,
               store.reviews.contains(where: { $0.id == reviewId }) {
                reviewNavigationPath = [ReviewRoute(reviewId: reviewId)]
            }
        }
        .onChange(of: reviewSplitVisibility) { _, visibility in
            let expanded = visibility != .detailOnly
            if store.sidebarExpanded != expanded {
                store.sidebarExpanded = expanded
            }
        }
        .onChange(of: store.sidebarExpanded) { _, expanded in
            let target: NavigationSplitViewVisibility = expanded ? .all : .detailOnly
            if reviewSplitVisibility != target {
                reviewSplitVisibility = target
            }
        }
        .onChange(of: reviewNavigationPath) { _, path in
            let reviewId = path.last?.reviewId
            if store.selectedReviewId != reviewId {
                store.selectedReviewId = reviewId
            }
            if reviewId == nil {
                store.reviewDecisionReadiness = nil
                pendingReviewToolbarAction = nil
            }
        }
        .onChange(of: store.reviewSearchFocusToken) { _, _ in
            reviewNavigationPath.removeAll()
            DispatchQueue.main.async {
                reviewSearchFocusRequest += 1
            }
        }
        .onChange(of: store.selectedReviewId) { _, reviewId in
            guard store.selectedSection == .reviews else { return }
            guard let reviewId else {
                if !reviewNavigationPath.isEmpty {
                    reviewNavigationPath.removeAll()
                }
                return
            }
            guard reviewNavigationPath.last?.reviewId != reviewId else { return }
            guard store.reviews.contains(where: { $0.id == reviewId }) else { return }
            reviewNavigationPath = [ReviewRoute(reviewId: reviewId)]
        }
        .onChange(of: syncToolbarPresentation) { _, presentation in
            if presentation == nil || presentation?.isSyncing == true {
                showsSyncIssuePopover = false
            }
        }
        .task {
            while !Task.isCancelled {
                await store.refreshSyncStatus()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
        .sheet(isPresented: $store.showsProjectCreation) {
            ProjectCreationSheet(store: store)
        }
    }

    private var workspaceSearchPrompt: String {
        switch store.selectedSection {
        case .memory: "Search Memory"
        case .bundles: "Search Bundles"
        case .reviews: "Search Reviews"
        case .issues: "Search Issues"
        case .sessions: "Search Activity"
        }
    }

    private var filteredReviews: [ReviewRecord] {
        let byStatus = store.reviews.filter { reviewStatusFilter.matches($0) }
        let needle = reviewSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !needle.isEmpty else { return byStatus }
        return byStatus.filter {
            "\($0.title) \($0.description) \($0.author.email) \($0.status)"
                .localizedLowercase.contains(needle)
        }
    }

    private var reviewToolbarOwnership: ReviewToolbarOwnership {
        let review = selectedReviewForToolbar
        return .resolve(
            surface: reviewNavigationPath.isEmpty ? .list : .detail,
            review: review,
            canDecideReviews: store.canDecideReviews,
            canMergeReviews: store.canMergeReviews,
            isAuthor: review.map(store.isReviewAuthor) ?? false
        )
    }

    private var selectedReviewForToolbar: ReviewRecord? {
        guard let reviewId = store.selectedReviewId else { return nil }
        return store.reviews.first { $0.id == reviewId }
    }

    @ToolbarContentBuilder
    private var reviewDetailToolbarContent: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .automatic)
        }

        if let review = selectedReviewForToolbar {
            if reviewToolbarOwnership.contains(.decision(.reject)) {
                ToolbarItem(id: "review.reject", placement: .automatic) {
                    Button {
                        performReviewToolbarAction(.reject)
                    } label: {
                        reviewToolbarActionLabel(
                            systemImage: "xmark",
                            isPending: pendingReviewToolbarAction == .reject
                        )
                    }
                    .disabled(
                        pendingReviewToolbarAction != nil
                            || !store.canPerformReviewMenuAction(.reject)
                    )
                    .help(review.freshness == .behind
                        ? "Review the latest shared changes before deciding"
                        : "Reject this Review")
                    .accessibilityLabel("Reject Review")
                    .accessibilityIdentifier("review-toolbar-reject")
                }
            }

            if reviewToolbarOwnership.contains(.decision(.approve)) {
                ToolbarItem(id: "review.approve", placement: .automatic) {
                    Button {
                        performReviewToolbarAction(.approve)
                    } label: {
                        reviewToolbarActionLabel(
                            systemImage: "checkmark",
                            isPending: pendingReviewToolbarAction == .approve
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        pendingReviewToolbarAction != nil
                            || !store.canPerformReviewMenuAction(.approve)
                    )
                    .help(review.freshness == .behind
                        ? "Review the latest shared changes before deciding"
                        : "Approve and merge this Review")
                    .accessibilityLabel("Approve and Merge Review")
                    .accessibilityIdentifier("review-toolbar-approve")
                }
            }

            if reviewToolbarOwnership.contains(.decision(.merge)) {
                ToolbarItem(id: "review.merge", placement: .automatic) {
                    Button {
                        performReviewToolbarAction(.merge)
                    } label: {
                        reviewToolbarActionLabel(
                            systemImage: "arrow.triangle.merge",
                            isPending: pendingReviewToolbarAction == .merge
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        pendingReviewToolbarAction != nil
                            || !store.canPerformReviewMenuAction(.merge)
                    )
                    .help("Merge the approved changes")
                    .accessibilityLabel("Merge Review")
                    .accessibilityIdentifier("review-toolbar-merge")
                }
            }

            if reviewToolbarOwnership.contains(.decision(.resubmit)) {
                ToolbarItem(id: "review.resubmit", placement: .automatic) {
                    Button {
                        performReviewToolbarAction(.resubmit)
                    } label: {
                        reviewToolbarActionLabel(
                            systemImage: "arrow.clockwise",
                            isPending: pendingReviewToolbarAction == .resubmit
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        pendingReviewToolbarAction != nil
                            || !store.canPerformReviewMenuAction(.resubmit)
                    )
                    .help("Resubmit this Review")
                    .accessibilityLabel("Resubmit Review")
                    .accessibilityIdentifier("review-toolbar-resubmit")
                }
            }
        }

        reviewUtilityToolbarContent(hasLeadingActions: reviewToolbarOwnership.hasDecisionActions)
    }

    @ToolbarContentBuilder
    private func reviewUtilityToolbarContent(hasLeadingActions: Bool) -> some ToolbarContent {
        if #available(macOS 26.0, *),
           syncToolbarPresentation != nil,
           hasLeadingActions {
            ToolbarSpacer(.fixed, placement: .automatic)
        }

        if let syncToolbarPresentation {
            ToolbarItem(id: "review.sync", placement: .automatic) {
                switch syncToolbarPresentation {
                case .syncing:
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                        .help(syncToolbarPresentation.label)
                        .accessibilityLabel(syncToolbarPresentation.label)
                        .accessibilityIdentifier("review-toolbar-sync")
                case .failed, .unavailable, .stale:
                    Button {
                        showsSyncIssuePopover.toggle()
                    } label: {
                        Image(systemName: syncToolbarPresentation.symbolName)
                            .foregroundStyle(syncToolbarPresentation.tint)
                    }
                    .help(syncToolbarPresentation.label)
                    .accessibilityLabel(syncToolbarPresentation.label)
                    .accessibilityIdentifier("review-toolbar-sync")
                    .popover(isPresented: $showsSyncIssuePopover, arrowEdge: .top) {
                        SyncIssuePopover(
                            presentation: syncToolbarPresentation,
                            store: store
                        )
                    }
                }
            }
        }

        if #available(macOS 26.0, *),
           syncToolbarPresentation != nil || hasLeadingActions {
            ToolbarSpacer(.fixed, placement: .automatic)
        }

        if reviewToolbarOwnership.contains(.search) {
            ToolbarItem(id: "review.search", placement: .trailingPinned) {
                ClassicSearchField(
                    text: $reviewSearchQuery,
                    prompt: "Search Reviews",
                    accessibilityIdentifier: "review-toolbar-search",
                    accessibilityHelp: "Search Reviews by title, description or author",
                    focusToken: reviewSearchFocusRequest
                )
            }
        }
    }

    private func performReviewToolbarAction(_ action: ReviewMenuAction) {
        guard pendingReviewToolbarAction == nil else { return }
        pendingReviewToolbarAction = action
        Task {
            defer { pendingReviewToolbarAction = nil }
            await store.performReviewMenuAction(action)
        }
    }

    private func reviewToolbarActionLabel(systemImage: String, isPending: Bool) -> some View {
        ZStack {
            Image(systemName: systemImage)
                .opacity(isPending ? 0 : 1)
            if isPending {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 16, height: 16)
    }

    private var recallWorkspace: some View {
        NavigationSplitView(columnVisibility: $recallSplitVisibility) {
            GlobalSidebar(
                store: store,
                onOpenSettings: onOpenSettings,
                onOpenDiagnostics: onOpenDiagnostics,
                onShowLogs: onShowLogs
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } content: {
            RecallSessionList(model: recallModel)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            RecallSessionDetail(model: recallModel)
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    recallToolbarContent
                }
        }
        .onAppear {
            store.showsProjectSettings = false
            let target: NavigationSplitViewVisibility = store.sidebarExpanded ? .all : .doubleColumn
            if recallSplitVisibility != target {
                recallSplitVisibility = target
            }
            if recallModel.sessions.isEmpty {
                Task { await recallModel.load() }
            }
        }
        .onChange(of: recallSplitVisibility) { _, visibility in
            let expanded = visibility != .detailOnly
            if store.sidebarExpanded != expanded {
                store.sidebarExpanded = expanded
            }
        }
        .onChange(of: store.sidebarExpanded) { _, expanded in
            let target: NavigationSplitViewVisibility = expanded ? .all : .doubleColumn
            if recallSplitVisibility != target {
                recallSplitVisibility = target
            }
        }
    }

    @ToolbarContentBuilder
    private var recallToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ActivityProjectFilter(store: store, model: recallModel)
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .automatic)
        }

        ToolbarItem(placement: .trailingPinned) {
            Button {
                Task { await recallModel.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(recallModel.isLoading)
            .help("Refresh Activity")
            .accessibilityLabel("Refresh Activity")
        }
    }

    private var issuesWorkspace: some View {
        NavigationSplitView(columnVisibility: $issueSplitVisibility) {
            GlobalSidebar(
                store: store,
                onOpenSettings: onOpenSettings,
                onOpenDiagnostics: onOpenDiagnostics,
                onShowLogs: onShowLogs
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            NavigationStack(path: $issueNavigationPath) {
                IssueBoardView(
                    model: issueBoardModel,
                    projectId: store.activeProjectId,
                    projectName: store.activeProject?.name,
                    members: store.projectMembers,
                    onOpenDetails: { issue in
                        issueNavigationPath = [IssueBoardRoute(issueId: issue.id)]
                    },
                    onAssign: { issue, member in
                        try await store.assignIssue(issue, to: member)
                        await issueBoardModel.refresh()
                    }
                )
                .navigationDestination(for: IssueBoardRoute.self) { route in
                    issueDetailView(for: route)
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                if issueNavigationPath.isEmpty {
                    ToolbarItem(placement: .navigation) {
                        IssueProjectFilter(store: store)
                    }

                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible, placement: .automatic)
                    }

                    ToolbarItemGroup(placement: .trailingPinned) {
                        Toggle(isOn: $issueBoardModel.showsStaleOnly) {
                            Label("Stale", systemImage: "clock.badge.exclamationmark")
                        }
                        .toggleStyle(.button)
                        .disabled(issueBoardModel.response == nil)
                        .help("Show only stale In Progress Issues")

                        Toggle(isOn: $issueBoardModel.showsBlockedOnly) {
                            Label("Blocked", systemImage: "exclamationmark.triangle.fill")
                        }
                        .toggleStyle(.button)
                        .disabled(issueBoardModel.response == nil)
                        .help("Show only Issues blocked by unresolved dependencies or conditions")

                        IssueExternalReferenceFilterMenu(model: issueBoardModel)

                        if showsUnlinkedActivityButton {
                            Button {
                                showsUnlinkedActivity.toggle()
                            } label: {
                                Label(
                                    "\(issueBoardModel.unlinkedRuns.count)",
                                    systemImage: "bolt.circle"
                                )
                                .labelStyle(.titleAndIcon)
                            }
                            .help("Unlinked Activity")
                            .accessibilityLabel("Unlinked Activity")
                            .accessibilityValue(
                                "\(issueBoardModel.unlinkedRuns.count) Agent Runs"
                            )
                            .popover(isPresented: $showsUnlinkedActivity, arrowEdge: .top) {
                                IssueUnlinkedActivityPopover(runs: issueBoardModel.unlinkedRuns)
                            }
                        }

                        Button {
                            showsIssueWorkflowHelp.toggle()
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .help("How to use Kanban")
                        .accessibilityLabel("How to use Kanban")
                        .popover(isPresented: $showsIssueWorkflowHelp, arrowEdge: .top) {
                            IssueWorkflowHelpPopover()
                        }

                        if let syncToolbarPresentation {
                            switch syncToolbarPresentation {
                            case .syncing:
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 24, height: 24)
                                    .help(syncToolbarPresentation.label)
                                    .accessibilityLabel(syncToolbarPresentation.label)
                            case .failed, .unavailable, .stale:
                                Button {
                                    showsSyncIssuePopover.toggle()
                                } label: {
                                    Image(systemName: syncToolbarPresentation.symbolName)
                                        .foregroundStyle(syncToolbarPresentation.tint)
                                }
                                .help(syncToolbarPresentation.label)
                                .accessibilityLabel(syncToolbarPresentation.label)
                                .popover(isPresented: $showsSyncIssuePopover, arrowEdge: .top) {
                                    SyncIssuePopover(
                                        presentation: syncToolbarPresentation,
                                        store: store
                                    )
                                }
                            }
                        }
                    }

                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .automatic)
                    }

                    ToolbarItem(id: "issue.search", placement: .trailingPinned) {
                        ClassicSearchField(
                            text: $issueBoardModel.searchQuery,
                            prompt: "Search Issues",
                            accessibilityIdentifier: "issue-toolbar-search",
                            accessibilityHelp: "Search only the Issues on this board",
                            focusToken: issueSearchFocusRequest
                        )
                    }
                }
            }
        }
        .onAppear {
            store.showsProjectSettings = false
            let target: NavigationSplitViewVisibility = store.sidebarExpanded ? .all : .detailOnly
            if issueSplitVisibility != target {
                issueSplitVisibility = target
            }
        }
        .onChange(of: store.issueSearchFocusToken) { _, _ in
            issueNavigationPath.removeAll()
            DispatchQueue.main.async {
                issueSearchFocusRequest += 1
            }
        }
        .onChange(of: issueSplitVisibility) { _, visibility in
            let expanded = visibility != .detailOnly
            if store.sidebarExpanded != expanded {
                store.sidebarExpanded = expanded
            }
        }
        .onChange(of: store.sidebarExpanded) { _, expanded in
            let target: NavigationSplitViewVisibility = expanded ? .all : .detailOnly
            if issueSplitVisibility != target {
                issueSplitVisibility = target
            }
        }
        .onChange(of: store.activeProjectId) {
            showsUnlinkedActivity = false
            issueNavigationPath.removeAll()
        }
        .onChange(of: showsUnlinkedActivityButton) { _, isAvailable in
            if !isAvailable {
                showsUnlinkedActivity = false
            }
        }
        .onChange(of: syncToolbarPresentation) { _, presentation in
            if presentation == nil || presentation?.isSyncing == true {
                showsSyncIssuePopover = false
            }
        }
        .task {
            while !Task.isCancelled {
                await store.refreshSyncStatus()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
        .task(id: store.activeProjectId) {
            await store.refreshProjectMembers()
        }
        .sheet(isPresented: $store.showsProjectCreation) {
            ProjectCreationSheet(store: store)
        }
    }

    private var showsUnlinkedActivityButton: Bool {
        IssueBoardPresentation.showsUnlinkedActivity(
            activeProjectId: store.activeProjectId,
            responseProjectId: issueBoardModel.response?.projectId,
            runCount: issueBoardModel.unlinkedRuns.count
        )
    }

    @ToolbarContentBuilder
    private var navigationToolbarContent: some ToolbarContent {
        switch store.selectedSection {
        case .memory:
            ToolbarItem(placement: .navigation) {
                MemoryProjectFilter(store: store)
            }

            ToolbarItem {
                Button {
                    store.showsProjectSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .disabled(store.activeProjectId == nil)
                .help("Project Settings")
                .accessibilityLabel("Project Settings")
            }
        case .bundles:
            ToolbarItem {
                Button {
                    Task { await store.createBundle() }
                } label: {
                    Image(systemName: "plus")
                }
                .help("New Bundle")
                .accessibilityLabel("New Bundle")
            }
        case .issues:
            ToolbarItem {
                EmptyView()
            }
        case .reviews:
            ToolbarItem {
                EmptyView()
            }
        case .sessions:
            ToolbarItem {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var navigator: some View {
        switch store.selectedSection {
        case .memory:
            MemoryNavigator(store: store)
        case .bundles:
            BundleNavigator(store: store)
        case .issues:
            EmptyView()
        case .reviews:
            EmptyView()
        case .sessions:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selectedSection {
        case .memory:
            if store.projects.isEmpty, !store.resources.contains(where: { $0.scope == .org }) {
                ProjectUnavailableView(store: store)
            } else if store.showsProjectSettings, store.activeProjectId != nil {
                ProjectSettingsView(store: store)
            } else {
                MemoryMainPane(store: store)
            }
        case .bundles:
            BundleDetail(
                store: store,
                showsResourcePicker: $showsBundleResourcePicker,
                confirmsDeletion: $confirmsBundleDeletion
            )
        case .issues:
            EmptyView()
        case .reviews:
            EmptyView()
        case .sessions:
            EmptyView()
        }
    }

    private var availableDocumentModes: [WorkbenchTabMode] {
        if store.currentItem?.draft?.documentBaselineAvailable == false {
            return [.diff]
        }
        return store.currentItem?.supportsMarkdownPreview == true
            ? [.preview, .source, .diff]
            : [.source, .diff]
    }

    private func canRequestDocumentReview(_ item: MemoryListItem) -> Bool {
        guard store.activeProjectId != nil,
              let draft = item.draft else {
            return false
        }
        return draft.status == .open
            && draft.scope == .org
            && WorkspaceStore.canRequestReview(draft)
    }

    private func canProposeOrganizationDeletion(_ item: MemoryListItem) -> Bool {
        store.canEditMemory(item)
            && MemoryFileTreeMenu.canProposeOrganizationDeletion(
                item,
                inOrgView: store.activeProjectId == nil
            )
    }

    private func canDiscardDocumentDraft(_ item: MemoryListItem) -> Bool {
        store.activeProjectId != nil && item.draft != nil
    }

    private func hasDocumentActions(_ item: MemoryListItem) -> Bool {
        canRequestDocumentReview(item)
            || canDiscardDocumentDraft(item)
            || canProposeOrganizationDeletion(item)
    }

    private var documentMode: Binding<WorkbenchTabMode> {
        Binding(
            get: {
                let mode = store.currentTabMode ?? .preview
                return availableDocumentModes.contains(mode) ? mode : .source
            },
            set: { store.switchDocumentMode($0) }
        )
    }

    private var documentNeedsSync: Bool {
        guard let item = store.currentItem else { return false }
        if item.draft?.freshness == .behind { return true }
        return item.resource.map { store.staleResourceIds.contains($0.id) } == true
    }

    private var documentSyncReadiness: DocumentSyncReadiness {
        guard let item = store.currentItem else { return .ready }
        if store.isSynchronizingDocument(item.id) { return .pending }
        guard let draft = item.draft else {
            return .ready
        }
        switch draft.syncStatus {
        case .queued, .syncing, .retrying:
            return .pending
        case .failed:
            return .failed
        case .synced:
            return draft.serverId == nil ? .unavailable : .ready
        }
    }

    private var syncToolbarPresentation: SyncToolbarPresentation? {
        guard store.activeProjectId != nil else { return nil }
        return SyncToolbarPresentation.resolve(
            status: store.runtime?.sync,
            isAvailable: store.syncStatusAvailable,
            serverDataSource: store.runtime?.serverDataSource
        )
    }

}

private struct IssueProjectFilter: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ProjectFilterMenu(
            projects: store.projects,
            selectedProjectId: store.activeProjectId,
            unscopedTitle: nil,
            unscopedSystemImage: nil,
            isLoading: store.loadingProjectId != nil,
            help: "Filter Kanban by Project"
        ) { projectId in
            if let projectId {
                Task { await store.selectProject(projectId) }
            }
        }
    }
}

private struct MemoryProjectFilter: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ProjectFilterMenu(
            projects: store.projects,
            selectedProjectId: store.activeProjectId,
            unscopedTitle: "Org",
            unscopedSystemImage: "building.2",
            isLoading: store.isSwitchingMemoryContext,
            help: "Filter Memory by Project"
        ) { projectId in
            if let projectId {
                Task { await store.selectProject(projectId) }
            } else {
                Task { await store.showOrgMemory() }
            }
        }
    }
}

private struct ActivityProjectFilter: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var model: RecallModel

    var body: some View {
        ProjectFilterMenu(
            projects: store.projects,
            selectedProjectId: model.selectedProjectId,
            unscopedTitle: "All Projects",
            unscopedSystemImage: nil,
            isLoading: model.isLoading,
            help: "Filter Activity by Project"
        ) { projectId in
            Task { await model.selectProject(projectId) }
        }
    }
}

private extension SyncToolbarPresentation {
    var tint: Color {
        switch self {
        case .syncing: .secondary
        case .failed: .red
        case .unavailable: .secondary
        case .stale: .secondary
        }
    }
}

private struct WorkspaceOperationErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Operation Failed")
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Operation failed: \(message)")

            Spacer(minLength: 16)

            Button("Copy Details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss operation failure")
        }
        .padding(10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct SyncIssuePopover: View {
    let presentation: SyncToolbarPresentation
    @ObservedObject var store: WorkspaceStore
    @State private var isReloading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: presentation.symbolName)
                    .foregroundStyle(presentation.tint)
                Text(presentation.label)
                    .font(.headline)
            }

            Text(presentation.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = store.syncRetryErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Sync retry failed: \(message)")
            }

            Divider()

            HStack {
                Spacer()
                switch presentation {
                case .failed, .unavailable:
                    Button {
                        Task {
                            _ = await store.retrySync(projectId: store.activeProjectId)
                        }
                    } label: {
                        if store.isRetryingSync {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Retry Project Sync")
                        }
                    }
                    .disabled(store.isRetryingSync)
                    .keyboardShortcut(.defaultAction)
                case .stale:
                    Button {
                        isReloading = true
                        Task {
                            await store.reload()
                            isReloading = false
                        }
                    } label: {
                        if isReloading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Refresh Project")
                        }
                    }
                    .disabled(isReloading)
                    .keyboardShortcut(.defaultAction)
                case .syncing:
                    EmptyView()
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

private struct GlobalSidebar: View {
    @ObservedObject var store: WorkspaceStore
    let onOpenSettings: () -> Void
    let onOpenDiagnostics: (DiagnosticsDestination) -> Void
    let onShowLogs: () -> Void

    var body: some View {
        List(selection: selection) {
            Section {
                SidebarDestinationLabel(section: .memory)
                    .tag(GlobalSidebarDestination.section(.memory))

                SidebarDestinationLabel(section: .issues)
                    .tag(GlobalSidebarDestination.section(.issues))

                SidebarDestinationLabel(section: .bundles)
                    .tag(GlobalSidebarDestination.section(.bundles))
                SidebarDestinationLabel(section: .reviews)
                    .tag(GlobalSidebarDestination.section(.reviews))

                SidebarDestinationLabel(section: .sessions)
                    .tag(GlobalSidebarDestination.section(.sessions))
            } header: {
                HStack(spacing: 7) {
                    Image("BrandMark", bundle: .main)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                    Text(store.organization?.name ?? "Clumsies Lab")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                .textCase(nil)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                accountMenu
                    .frame(height: 40)
            }
        }
    }

    private var accountMenu: some View {
        NativeAccountMenu(
            account: store.account,
            displayName: accountDisplayName,
            onOpenSettings: onOpenSettings,
            onOpenDiagnostics: onOpenDiagnostics,
            onShowLogs: onShowLogs,
            onRefresh: { Task { await store.reload() } },
            onSignOut: { Task { await store.signOut() } }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accountDisplayName: String {
        if let displayName = store.account?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        return store.account?.email ?? "Account"
    }

    private var selection: Binding<GlobalSidebarDestination?> {
        Binding(
            get: { .section(store.selectedSection) },
            set: { destination in
                guard let destination else { return }
                if case .section(let section) = destination {
                    store.selectedSection = section
                    store.selectedItemId = nil
                }
            }
        )
    }

}

private struct SidebarDestinationLabel: View {
    let section: WorkspaceSection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: section.symbol)
                .frame(width: 16)
            Text(section.title)
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }
}

private enum GlobalSidebarDestination: Hashable {
    case section(WorkspaceSection)
}

struct AvatarView: View {
    let account: UserReference?

    var body: some View {
        Group {
            if let value = account?.avatarUrl, let url = URL(string: value) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 24, height: 24)
                        .clipped()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
    }

    private var fallback: some View {
        ZStack {
            Color.accentColor.opacity(0.2)
            Text(String((account?.displayName ?? account?.email ?? "C").prefix(1)).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: 24, height: 24)
    }
}
