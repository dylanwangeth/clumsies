import AppKit
import SwiftUI

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
            count == 1 ? "Syncing 1 change" : count > 1 ? "Syncing \(count) changes" : "Syncing"
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
            return "Clumsies is synchronizing changes in the background."
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
        self = section == .issues ? .sidebarDetail : .sidebarContentDetail
    }
}

struct IssueBoardRoute: Hashable {
    let issueId: String
}

struct WorkspaceView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpenSettings: () -> Void
    let onOpenDiagnostics: (DiagnosticsDestination) -> Void
    let onShowLogs: () -> Void
    @StateObject private var issueBoardModel: IssueBoardModel
    @State private var reviewStatusFilter = "open"
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @State private var issueSplitVisibility: NavigationSplitViewVisibility = .all
    @State private var showsBundleResourcePicker = false
    @State private var confirmsBundleDeletion = false
    @State private var showsSyncIssuePopover = false
    @State private var showsUnlinkedActivity = false
    @State private var showsIssueWorkflowHelp = false
    @State private var issueNavigationPath: [IssueBoardRoute] = []

    init(
        store: WorkspaceStore,
        onOpenSettings: @escaping () -> Void,
        onOpenDiagnostics: @escaping (DiagnosticsDestination) -> Void,
        onShowLogs: @escaping () -> Void
    ) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.onOpenDiagnostics = onOpenDiagnostics
        self.onShowLogs = onShowLogs
        _issueBoardModel = StateObject(wrappedValue: IssueBoardModel(daemon: store.daemon))
    }

    private var showsDocumentTabs: Bool {
        (store.selectedSection == .hub || store.selectedSection == .local)
            && !store.visibleTabs.isEmpty
            && !store.showsProjectSettings
    }

    private var documentReconciliationState: DocumentReconciliationToolbarState? {
        guard let state = store.documentReconciliationToolbarState,
              state.itemId == store.currentItem?.id else { return nil }
        return state
    }

    var body: some View {
        if WorkspaceColumnLayout(section: store.selectedSection) == .sidebarDetail {
            issuesWorkspace
        } else {
            regularWorkspace
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
                                        itemId: state.itemId
                                    )
                                } else {
                                    store.goBack()
                                }
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .disabled(documentReconciliationState == nil && !store.canGoBack)
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
                            ToolbarSpacer(.fixed)
                        }

                        if #available(macOS 26.0, *) {
                            ToolbarItem {
                                documentPath
                            }
                            .sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem {
                                documentPath
                            }
                        }

                        if #available(macOS 26.0, *) {
                            ToolbarSpacer(.flexible)
                        }
                    }

                    if #available(macOS 26.0, *), !showsDocumentTabs {
                        ToolbarSpacer(.flexible)
                    }

                    ToolbarItemGroup {
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
                                        store: store,
                                        isPresented: $showsSyncIssuePopover
                                    )
                                }
                            }
                        }

                        Button {
                            store.showsGlobalSearch.toggle()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .help("Search")
                        .accessibilityLabel("Search")
                        .popover(isPresented: $store.showsGlobalSearch, arrowEdge: .top) {
                            WorkspaceSearchPopover(
                                store: store,
                                results: searchResults,
                                onOpen: open
                            )
                        }

                        if showsDocumentTabs, let item = store.currentItem {
                            if let state = documentReconciliationState {
                                if state.isLoading || state.isUpdating {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 24, height: 24)
                                        .help(state.isLoading ? "Reviewing changes" : "Updating draft")
                                        .accessibilityLabel(
                                            state.isLoading ? "Reviewing changes" : "Updating draft"
                                        )
                                } else {
                                    Button {
                                        store.pendingDocumentCommand = .applyReconciliation(
                                            itemId: state.itemId
                                        )
                                    } label: {
                                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                                    }
                                    .disabled(!state.canUpdate)
                                    .help("Update Draft")
                                    .accessibilityLabel("Update Draft")
                                }
                            }

                            if item.supportsMarkdownPreview {
                                let mode = store.currentTabMode ?? .source
                                Button {
                                    store.open(item, mode: mode == .preview ? .source : .preview)
                                } label: {
                                    Image(systemName: mode == .preview ? "doc.plaintext" : "eye")
                                }
                                .help(mode == .preview ? "Open Source" : "Open Preview")
                                .accessibilityLabel(mode == .preview ? "Open Source" : "Open Preview")
                            }

                            Menu {
                                if item.inherited {
                                    Button("Open in Hub") {
                                        Task { await store.reveal(item) }
                                    }
                                }
                                if let draft = item.draft, draft.status == .open {
                                    Button("Request Review") {
                                        store.pendingDocumentCommand = .requestReview(
                                            itemId: item.id,
                                            draft: draft
                                        )
                                    }
                                    Divider()
                                }
                                if let draft = item.draft {
                                    Button("Discard Draft") {
                                        store.pendingDocumentCommand = .discardDraft(
                                            itemId: item.id,
                                            draft: draft
                                        )
                                    }
                                }
                                if !item.inherited {
                                    Button("Move to Trash", role: .destructive) {
                                        store.pendingDocumentCommand = .moveToTrash(itemId: item.id)
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuIndicator(.hidden)
                            .help("Document Actions")
                            .accessibilityLabel("Document Actions")
                        }
                    }
                }
            }
        .onAppear {
            let target: NavigationSplitViewVisibility = store.sidebarExpanded ? .all : .doubleColumn
            if splitVisibility != target {
                splitVisibility = target
            }
        }
        .onChange(of: store.searchQuery) { _, query in
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { await store.prepareWorkspaceIndex(includeContent: true) }
        }
        .onChange(of: store.selectedSection) { _, section in
            if section != .local {
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
        .alert(
            "Clumsies",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
                .textSelection(.enabled)
        }
        .sheet(isPresented: $store.showsProjectCreation) {
            ProjectCreationSheet(store: store)
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
                    onOpenDetails: { issue in
                        issueNavigationPath = [IssueBoardRoute(issueId: issue.id)]
                    }
                )
                .navigationDestination(for: IssueBoardRoute.self) { route in
                    IssueDetailView(
                        issueId: route.issueId,
                        model: issueBoardModel,
                        onGate: { action, issue in
                            Task {
                                do {
                                    try await issueBoardModel.applyGate(action, to: issue)
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
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                if issueNavigationPath.isEmpty {
                    ToolbarItem(placement: .navigation) {
                        IssueProjectFilter(store: store)
                    }

                    ToolbarItemGroup(placement: .primaryAction) {
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
                                        store: store,
                                        isPresented: $showsSyncIssuePopover
                                    )
                                }
                            }
                        }

                        Button {
                            store.showsGlobalSearch.toggle()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .help("Search")
                        .accessibilityLabel("Search")
                        .popover(isPresented: $store.showsGlobalSearch, arrowEdge: .top) {
                            WorkspaceSearchPopover(
                                store: store,
                                results: searchResults,
                                onOpen: open
                            )
                        }
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
        .onChange(of: store.searchQuery) { _, query in
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { await store.prepareWorkspaceIndex(includeContent: true) }
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
        .alert(
            "Clumsies",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
                .textSelection(.enabled)
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
        case .hub, .local:
            ToolbarItem {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(.secondary)
                    Picker("Memory Type", selection: $store.selectedKind) {
                        ForEach(MemoryKind.allCases) { kind in
                            Label(kind.title, systemImage: kind.symbol)
                                .tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .help("Memory Type: \(store.selectedKind.title)")
                    .accessibilityLabel("Memory Type")
                }
            }

            if store.selectedSection == .local {
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
                Picker("Status", selection: $reviewStatusFilter) {
                    Text("Open").tag("open")
                    Text("Approved").tag("approved")
                    Text("Rejected").tag("rejected")
                    Text("Merged").tag("merged")
                    Text("All").tag("all")
                }
                .labelsHidden()
                .frame(width: 110)
                .help("Review Status")
            }
        }
    }

    @ViewBuilder
    private var navigator: some View {
        switch store.selectedSection {
        case .hub, .local:
            MemoryNavigator(store: store)
        case .bundles:
            BundleNavigator(store: store)
        case .issues:
            EmptyView()
        case .reviews:
            ReviewNavigator(store: store, statusFilter: $reviewStatusFilter)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selectedSection {
        case .hub, .local:
            if store.selectedSection == .local, store.activeProjectId == nil {
                ProjectUnavailableView(store: store)
            } else if store.selectedSection == .local, store.showsProjectSettings {
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
            ReviewDetailPane(store: store, review: selectedReview)
        }
    }

    private var selectedReview: ReviewRecord? {
        filteredReviews.first { $0.id == store.selectedReviewId } ?? filteredReviews.first
    }

    @ViewBuilder
    private var documentPath: some View {
        if let path = store.currentDocumentPath {
            DocumentPathBreadcrumb(path: path)
                .frame(minWidth: 120, maxWidth: 360, alignment: .leading)
                .accessibilityLabel("Path: \(path)")
        }
    }

    private var filteredReviews: [ReviewRecord] {
        reviewStatusFilter == "all"
            ? store.reviews
            : store.reviews.filter { $0.status == reviewStatusFilter }
    }

    private var searchResults: [SearchEntry] {
        let needle = store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !needle.isEmpty else { return [] }
        var entries: [SearchEntry] = []
        let resourceItems = store.resources.map { resource -> MemoryListItem in
            let draft = store.drafts.first {
                $0.targetId == resource.id && $0.status != .discarded && $0.status != .merged
            }
            return .init(id: resource.id, resource: resource, draft: draft, inherited: false)
        }
        let newDrafts = store.drafts.filter { $0.targetId == nil }.map {
            MemoryListItem(id: $0.id, resource: nil, draft: $0, inherited: false)
        }
        for item in resourceItems + newDrafts {
            let document = item.document
            let haystack = "\(document.title) \(document.path) \(document.body) \(item.kind.title)".localizedLowercase
            if haystack.contains(needle) {
                entries.append(.memory(item))
            }
        }
        for bundle in store.bundles where "\(bundle.name) \(bundle.description)".localizedLowercase.contains(needle) {
            entries.append(.bundle(bundle))
        }
        for review in store.reviews where "\(review.title) \(review.description) \(review.author.email) \(review.status)".localizedLowercase.contains(needle) {
            entries.append(.review(review))
        }
        return Array(entries.prefix(30))
    }

    private func open(_ entry: SearchEntry) {
        switch entry.destination {
        case .memory(let item):
            Task { await store.reveal(item) }
        case .bundle(let bundle):
            store.selectedSection = .bundles
            store.selectedBundleId = bundle.id
        case .review(let review):
            store.selectedSection = .reviews
            store.selectedReviewId = review.id
        }
        store.searchQuery = ""
        store.showsGlobalSearch = false
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
        Menu {
            if store.projects.isEmpty {
                Button("No Projects") {}
                    .disabled(true)
            } else {
                ForEach(store.projects) { project in
                    Button {
                        guard project.id != store.activeProjectId else { return }
                        Task { await store.selectProject(project.id) }
                    } label: {
                        if project.id == store.activeProjectId {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                    .disabled(store.loadingProjectId != nil)
                }
            }
        } label: {
            HStack(spacing: 6) {
                if store.loadingProjectId == nil {
                    Image(systemName: "line.3.horizontal.decrease")
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(store.activeProject?.name ?? "Select Project")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .leading)
            }
        }
        .frame(maxWidth: 220, alignment: .leading)
        .help("Filter Kanban by Project")
        .accessibilityLabel("Project Filter")
        .accessibilityValue(store.activeProject?.name ?? "No Project Selected")
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

private struct SyncIssuePopover: View {
    let presentation: SyncToolbarPresentation
    @ObservedObject var store: WorkspaceStore
    @Binding var isPresented: Bool
    @State private var isRetrying = false

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

            Divider()

            HStack {
                Spacer()
                switch presentation {
                case .failed, .unavailable:
                    Button {
                        isRetrying = true
                        Task {
                            await store.retrySync()
                            isRetrying = false
                            isPresented = false
                        }
                    } label: {
                        if isRetrying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Try Again")
                        }
                    }
                    .disabled(isRetrying)
                    .keyboardShortcut(.defaultAction)
                case .stale:
                    Button {
                        isRetrying = true
                        Task {
                            await store.reload()
                            isRetrying = false
                            isPresented = false
                        }
                    } label: {
                        if isRetrying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Refresh")
                        }
                    }
                    .disabled(isRetrying)
                    .keyboardShortcut(.defaultAction)
                case .syncing:
                    EmptyView()
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct WorkspaceSearchPopover: View {
    @ObservedObject var store: WorkspaceStore
    let results: [SearchEntry]
    let onOpen: (SearchEntry) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $store.searchQuery)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if store.isPreparingWorkspaceIndex {
                        Label("Preparing search", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }

                    if store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Search Hub, Local, Bundles, and Reviews")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    } else if results.isEmpty && !store.isPreparingWorkspaceIndex {
                        Text("No Results")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(results) { entry in
                            Button {
                                onOpen(entry)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title)
                                            .lineLimit(1)
                                        Text(entry.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                } icon: {
                                    Image(systemName: entry.symbol)
                                        .frame(width: 18)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(6)
            }
            .frame(minHeight: 88, maxHeight: 300)
        }
        .frame(width: 380)
        .onAppear {
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
    }
}

private struct GlobalSidebar: View {
    @ObservedObject var store: WorkspaceStore
    let onOpenSettings: () -> Void
    let onOpenDiagnostics: (DiagnosticsDestination) -> Void
    let onShowLogs: () -> Void
    @State private var localExpanded = true

    var body: some View {
        List(selection: selection) {
            Section {
                SidebarDestinationLabel(section: .hub)
                    .tag(GlobalSidebarDestination.section(.hub))

                HStack(spacing: 4) {
                    Button {
                        store.selectedSection = .local
                        store.selectedItemId = nil
                        withAnimation(.snappy(duration: 0.16)) {
                            localExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: WorkspaceSection.local.symbol)
                                .frame(width: 16)
                            Text(WorkspaceSection.local.title)
                            Spacer(minLength: 8)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if store.canManageProjects {
                        Button {
                            store.presentProjectCreation()
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 16, height: 16, alignment: .center)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 20, height: 20, alignment: .center)
                        .contentShape(Rectangle())
                        .help("New Project")
                        .accessibilityLabel("New Project")
                    }
                }
                .tag(GlobalSidebarDestination.section(.local))

                if localExpanded {
                    ForEach(store.projects) { project in
                        HStack {
                            Text(project.name)
                                .lineLimit(1)
                            Spacer()
                            if store.loadingProjectId == project.id {
                                ProgressView()
                                    .controlSize(.mini)
                            } else if store.drafts.contains(where: {
                                $0.projectId == project.id
                                    && $0.status != .discarded
                                    && $0.status != .merged
                                    && $0.freshness == .behind
                            }) {
                                DraftBaseBehindIndicator()
                            }
                        }
                        .padding(.leading, 24)
                        .tag(GlobalSidebarDestination.project(project.id))
                        .accessibilityLabel(project.name)
                        .contextMenu {
                            Button("Project Settings…") {
                                Task {
                                    await store.selectProject(project.id)
                                    store.showsProjectSettings = true
                                }
                            }
                        }
                    }
                }

                SidebarDestinationLabel(section: .issues)
                    .tag(GlobalSidebarDestination.section(.issues))

                SidebarDestinationLabel(section: .bundles)
                    .tag(GlobalSidebarDestination.section(.bundles))
                SidebarDestinationLabel(section: .reviews)
                    .tag(GlobalSidebarDestination.section(.reviews))
            } header: {
                HStack(spacing: 7) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
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
            get: {
                if store.selectedSection == .local, let projectId = store.activeProjectId {
                    return .project(projectId)
                }
                return .section(store.selectedSection)
            },
            set: { destination in
                guard let destination else { return }
                switch destination {
                case .section(let section):
                    store.selectedSection = section
                    store.selectedItemId = nil
                case .project(let projectId):
                    store.selectedSection = .local
                    store.showsProjectSettings = false
                    Task { await store.selectProject(projectId) }
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
    case project(String)
}

private struct SearchEntry: Identifiable {
    enum Destination {
        case memory(MemoryListItem)
        case bundle(PersonalBundle)
        case review(ReviewRecord)
    }

    let id: String
    let title: String
    let detail: String
    let symbol: String
    let destination: Destination

    static func memory(_ item: MemoryListItem) -> Self {
        .init(
            id: "memory:\(item.id)",
            title: item.document.title,
            detail: "\(item.scope == .org ? "Hub" : "Local") · \(item.kind.title) · \(item.document.path)",
            symbol: item.kind.symbol,
            destination: .memory(item)
        )
    }

    static func bundle(_ bundle: PersonalBundle) -> Self {
        .init(
            id: "bundle:\(bundle.id)",
            title: bundle.name,
            detail: "Bundle · \(bundle.resourceIds.count) resources",
            symbol: "shippingbox",
            destination: .bundle(bundle)
        )
    }

    static func review(_ review: ReviewRecord) -> Self {
        .init(
            id: "review:\(review.id)",
            title: review.title,
            detail: "Review · \(review.status.capitalized)",
            symbol: "checkmark.bubble",
            destination: .review(review)
        )
    }
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
