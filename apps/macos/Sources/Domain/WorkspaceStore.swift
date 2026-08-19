import Combine
import Foundation

enum DocumentSessionCommand: Equatable, Sendable {
    case requestReview(itemId: String, draft: LocalDraft)
    case discardDraft(itemId: String, draft: LocalDraft)
    case reviewSharedChanges(itemId: String, draft: LocalDraft)
    case applyReconciliation(itemId: String)
    case closeReconciliation(itemId: String)
    case moveToTrash(itemId: String)

    var itemId: String {
        switch self {
        case .requestReview(let itemId, _),
             .discardDraft(let itemId, _),
             .reviewSharedChanges(let itemId, _),
             .applyReconciliation(let itemId),
             .closeReconciliation(let itemId),
             .moveToTrash(let itemId):
            itemId
        }
    }
}

struct DocumentReconciliationToolbarState: Equatable, Sendable {
    let itemId: String
    let isLoading: Bool
    let canUpdate: Bool
    let isUpdating: Bool
}

enum ApplicationPhase: Equatable, Sendable {
    case launching
    case authenticationRequired
    case loading
    case ready
    case failed(String)
}

struct WorkspaceSnapshot: Sendable {
    let account: UserReference
    let organization: OrganizationReference
    let capabilities: Set<String>
    let projects: [ProjectState]
    let activeProjectId: String?
    let orgRefCommitId: String?
    let orgRefEtag: String
    let resources: [MemoryResource]
    let drafts: [LocalDraft]
    let bundles: [PersonalBundle]
    let reviews: [ReviewRecord]
    let runtime: RuntimeState
    let legacyAgentAdapterConflicts: [DaemonLegacyAgentAdapterConflict]
    let legacyAgentAdapterInspectionWarning: String?
}

struct LocalAgentAdapterReconciliationResult: Equatable, Sendable {
    let conflicts: [DaemonLegacyAgentAdapterConflict]
    let inspectionWarning: String?
}

enum WorkspaceLoadError: LocalizedError, Sendable {
    case authenticationRequired
    case noProjects

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: "Sign in to connect Clumsies to your organization."
        case .noProjects: "The signed-in account has no accessible project."
        }
    }
}

enum MemoryValidationError: LocalizedError, Sendable {
    case invalidPath(String)
    case emptyRule

    var errorDescription: String? {
        switch self {
        case .invalidPath(let message): message
        case .emptyRule: "A Rule needs content."
        }
    }
}

enum ReviewRequestError: LocalizedError, Sendable {
    case draftNotSynchronized
    case reconciliationRequired

    var errorDescription: String? {
        switch self {
        case .draftNotSynchronized:
            "Wait for this draft to finish syncing before requesting a review."
        case .reconciliationRequired:
            "Merge the latest shared version before requesting a review."
        }
    }
}

enum ReviewMenuAction: Sendable, Equatable {
    case approve
    case reject
    case merge
    case resubmit

    func isAvailable(
        for review: ReviewRecord,
        canMergeReviews: Bool,
        isAuthor: Bool
    ) -> Bool {
        switch self {
        case .approve, .reject:
            return review.status == "open"
        case .merge:
            return review.status == "approved"
                && review.approvedResultHash?.isEmpty == false
                && canMergeReviews
        case .resubmit:
            return review.status == "rejected" && isAuthor
        }
    }
}

struct ReviewDecisionReadiness: Equatable, Sendable {
    let reviewId: String
    let reviewVersion: Int
    let status: String
    let approvedResultHash: String?
    let freshness: DraftFreshness
    let reconciliation: DraftReconciliationStatus
    let currentCommitId: String?

    init(review: ReviewRecord) {
        reviewId = review.id
        reviewVersion = review.version
        status = review.status
        approvedResultHash = review.approvedResultHash
        freshness = review.freshness
        reconciliation = review.reconciliation
        currentCommitId = review.currentCommitId
    }

    func matches(_ review: ReviewRecord) -> Bool {
        self == ReviewDecisionReadiness(review: review)
    }
}

enum ProjectSetupError: LocalizedError, Sendable {
    case noRepositories
    case bundledAgentRuntimeMissing
    case bundleNotFound
    case bundleContainsUnavailableMemory

    var errorDescription: String? {
        switch self {
        case .noRepositories:
            "Choose at least one local repository."
        case .bundledAgentRuntimeMissing:
            "The clumsiesd Agent runtime is missing from this app build."
        case .bundleNotFound:
            "The selected Bundle is no longer available."
        case .bundleContainsUnavailableMemory:
            "The selected Bundle contains memory that is not available in the Organization."
        }
    }
}

enum ProjectMemorySelectionError: LocalizedError, Sendable {
    case invalidOrgResources
    case projectUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidOrgResources:
            "Only current Organization memory can be added to or removed from a Project."
        case .projectUnavailable:
            "The selected Project is no longer available."
        }
    }
}

enum ProjectOrgSelectionMutation: Sendable {
    case add
    case remove

    func applying(_ resourceIds: Set<String>, to current: Set<String>) -> Set<String> {
        switch self {
        case .add:
            current.union(resourceIds)
        case .remove:
            current.subtracting(resourceIds)
        }
    }
}

struct DraftInventoryPlan: Equatable, Sendable {
    let refreshIds: Set<String>
    let terminalIds: Set<String>
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var phase: ApplicationPhase = .launching
    @Published private(set) var account: UserReference?
    @Published private(set) var organization: OrganizationReference?
    @Published private(set) var capabilities: Set<String> = []
    @Published private(set) var projects: [ProjectState] = []
    @Published private(set) var projectMetadata: [String: ProjectRecord] = [:]
    @Published private(set) var orgRefCommitId: String?
    @Published private(set) var orgRefEtag = ""
    @Published private(set) var resources: [MemoryResource] = []
    @Published private(set) var drafts: [LocalDraft] = []
    @Published private(set) var bundles: [PersonalBundle] = []
    @Published private(set) var reviews: [ReviewRecord] = []
    @Published private(set) var runtime: RuntimeState?
    @Published private(set) var syncStatusAvailable = true
    @Published private(set) var legacyAgentAdapterConflicts: [DaemonLegacyAgentAdapterConflict] = []
    @Published private(set) var legacyAgentAdapterInspectionWarning: String?

    @Published var activeProjectId: String?
    @Published var selectedSection: WorkspaceSection = .memory
    @Published var selectedKind: MemoryKind = .context
    @Published var selectedItemId: String?
    @Published var selectedBundleId: String?
    @Published var selectedReviewId: String?
    @Published var searchQuery = ""
    @Published var showsGlobalSearch = false
    @Published var issueSearchFocusToken = UUID()
    @Published var reviewSearchFocusToken = UUID()
    @Published var showsProjectCreation = false
    @Published var showsProjectSettings = false
    @Published var sidebarExpanded = true
    @Published var errorMessage: String?
    @Published var tabs: [WorkbenchTab] = []
    @Published var activeTabId: String?
    @Published private(set) var navigationBackStack: [String] = []
    @Published private(set) var navigationForwardStack: [String] = []
    @Published var pendingDocumentCommand: DocumentSessionCommand?
    @Published var pendingReviewReconciliationId: String?
    @Published var reviewDecisionReadiness: ReviewDecisionReadiness?
    @Published var documentReconciliationToolbarState: DocumentReconciliationToolbarState?
    @Published private(set) var loadingResourceIds: Set<String> = []
    @Published private(set) var loadingProjectId: String?
    @Published private(set) var isPreparingWorkspaceIndex = false

    let daemon = DaemonXPCClient()
    private let bootstrap = DaemonBootstrapController()
    private lazy var authentication = AuthenticationClient(daemon: daemon)
    private lazy var server = ServerClient(daemon: daemon)
    private var projectSelectionGeneration = UUID()
    private let draftMutationGate = AsyncMutex()
    private let bundleMutationGate = AsyncMutex()
    private let projectOrgSelectionMutationGate = AsyncMutex()
    private var pendingDocumentSaves: [String: PendingDocumentSave] = [:]
    private var documentSaveTasks: [String: Task<Void, Never>] = [:]
    private var pendingBundleSaves: [String: PendingBundleSave] = [:]
    private var bundleSaveTasks: [String: Task<Void, Never>] = [:]

    var activeProject: ProjectState? {
        projects.first { $0.id == activeProjectId }
    }

    var canManageOrgSelection: Bool {
        capabilities.contains("admin:write")
    }

    var canManageProjects: Bool {
        capabilities.contains("admin:write")
    }

    var canMergeReviews: Bool {
        capabilities.contains("review:merge")
    }

    var hasPendingChanges: Bool {
        !pendingDocumentSaves.isEmpty || !pendingBundleSaves.isEmpty
    }

    func isReviewAuthor(_ review: ReviewRecord) -> Bool {
        account?.userId == review.author.userId
    }

    func canCreateMemory(kind: MemoryKind, scope: MemoryScope) -> Bool {
        scope == .org || activeProjectId != nil
    }

    var selectedItem: MemoryListItem? {
        let itemId = activeVisibleTab?.itemId ?? selectedItemId
        return visibleMemoryItems.first { $0.id == itemId } ?? visibleMemoryItems.first
    }

    var visibleTabs: [WorkbenchTab] {
        tabs.filter { $0.isVisible(in: selectedSection, projectId: activeProjectId) }
    }

    var activeVisibleTab: WorkbenchTab? {
        visibleTabs.first { $0.id == activeTabId } ?? visibleTabs.last
    }

    var canGoBack: Bool {
        navigationBackStack.contains(where: isVisibleTab)
    }

    var canGoForward: Bool {
        navigationForwardStack.contains(where: isVisibleTab)
    }

    var currentDocumentPath: String? {
        guard let tab = activeVisibleTab,
              let item = item(for: tab) else { return nil }
        return item.document.path
    }

    var currentItem: MemoryListItem? {
        guard let tab = activeVisibleTab else { return nil }
        return item(for: tab)
    }

    var currentTabMode: WorkbenchTabMode? {
        activeVisibleTab?.mode
    }

    var selectedBundle: PersonalBundle? {
        bundles.first { $0.id == selectedBundleId } ?? bundles.first
    }

    var selectedReview: ReviewRecord? {
        reviews.first { $0.id == selectedReviewId } ?? reviews.first
    }

    func canPerformReviewMenuAction(_ action: ReviewMenuAction) -> Bool {
        guard phase == .ready,
              selectedSection == .reviews,
              let selectedReviewId,
              let review = reviews.first(where: { $0.id == selectedReviewId }),
              reviewDecisionReadiness?.matches(review) == true,
              review.freshness == .current else {
            return false
        }
        return action.isAvailable(
            for: review,
            canMergeReviews: canMergeReviews,
            isAuthor: isReviewAuthor(review)
        )
    }

    func performReviewMenuAction(_ action: ReviewMenuAction) async {
        guard canPerformReviewMenuAction(action),
              let selectedReviewId,
              let review = reviews.first(where: { $0.id == selectedReviewId }),
              let readiness = reviewDecisionReadiness else { return }
        reviewDecisionReadiness = nil
        do {
            switch action {
            case .approve:
                try await decide(review, decision: "approved", note: "")
            case .reject:
                try await decide(review, decision: "rejected", note: "")
            case .merge:
                try await merge(review)
            case .resubmit:
                let detail = try await reviewDetail(review.id)
                if detail.draft.coordination.freshness == .behind {
                    pendingReviewReconciliationId = review.id
                } else {
                    try await resubmit(review, detail: detail)
                }
            }
        } catch {
            if self.selectedReviewId == selectedReviewId,
               selectedSection == .reviews,
               let currentReview = reviews.first(where: { $0.id == selectedReviewId }),
               readiness.matches(currentReview) {
                reviewDecisionReadiness = readiness
            }
            errorMessage = error.localizedDescription
        }
    }

    var visibleMemoryItems: [MemoryListItem] {
        let authoritative: [MemoryResource]
        switch selectedSection {
        case .memory:
            // Unified Memory: org-scope (Hub) memories are always visible;
            // the active project's project-scope memories are merged in.
            let orgResources = resources.filter { $0.scope == .org }
            let projectResources = resources.filter {
                $0.scope == .project && $0.projectId == activeProjectId
            }
            authoritative = orgResources + projectResources
        case .issues, .bundles, .reviews:
            return []
        }

        let activeDrafts = drafts.filter { draft in
            guard draft.status != .discarded && draft.status != .merged else {
                return false
            }
            if draft.scope == .org {
                return true
            }
            return draft.projectId == activeProjectId
        }
        let draftByTarget = Dictionary(
            activeDrafts.compactMap { draft in draft.targetId.map { ($0, draft) } },
            uniquingKeysWith: { _, latest in latest }
        )
        var items = authoritative.map { resource in
            MemoryListItem(
                id: resource.id,
                resource: resource,
                draft: draftByTarget[resource.id],
                inherited: resource.scope == .org
                    && activeProjectId != nil
                    && (activeProject?.selectedOrgResourceIds.contains(resource.id) ?? false)
            )
        }
        items.append(contentsOf: activeDrafts.filter { $0.targetId == nil }.map {
            MemoryListItem(id: $0.id, resource: nil, draft: $0, inherited: false)
        })
        return items.sorted { $0.document.path.localizedStandardCompare($1.document.path) == .orderedAscending }
    }

    func start() {
        Task { await reload() }
    }

    func reload() async {
        if phase == .ready, hasPendingChanges, !(await flushPendingChanges()) {
            return
        }
        phase = .loading
        errorMessage = nil
        do {
            let snapshot = try await WorkspaceLoader(
                daemon: daemon,
                bootstrap: bootstrap,
                server: server
            ).load { [weak self] result in
                self?.applyLocalAgentAdapterResult(result)
            }
            apply(snapshot)
            phase = .ready
        } catch WorkspaceLoadError.authenticationRequired {
            phase = .authenticationRequired
        } catch {
            let messages = [error.localizedDescription, errorMessage]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            phase = .failed(messages.joined(separator: "\n\n"))
        }
    }

    func signIn() async {
        phase = .loading
        errorMessage = nil
        do {
            _ = try await authentication.signIn()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            phase = .authenticationRequired
        }
    }

    func presentProjectCreation() {
        guard canManageProjects else { return }
        showsProjectCreation = true
    }

    func createProject(
        name: String,
        description: String,
        idempotencyKey: String,
        repositoryPaths: [String],
        bundleId: String?,
        adapters: Set<ProjectAgentAdapterKind>
    ) async throws {
        let repositoryPaths = normalizedRepositoryPaths(repositoryPaths)
        guard !repositoryPaths.isEmpty else { throw ProjectSetupError.noRepositories }
        let created: ProjectRecord = try await server.send(
            method: "POST",
            path: "/api/v1/projects",
            headers: ["idempotency-key": idempotencyKey],
            body: CreateProjectRequest(
                name: name,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : description
            )
        )
        let initialSelection = try await initializeProjectMemory(
            projectId: created.id,
            bundleId: bundleId
        )
        projectMetadata[created.id] = created
        let project = ProjectState(
            id: created.id,
            name: created.name,
            refCommitId: nil,
            refEtag: "",
            selectedOrgResourceIds: projectOrgResourceIds(initialSelection),
            orgSelectionRevision: initialSelection.revision,
            isLoaded: false
        )
        if let index = projects.firstIndex(where: { $0.id == created.id }) {
            projects[index] = project
        } else {
            projects.insert(project, at: 0)
        }
        for repositoryPath in repositoryPaths {
            _ = try await daemon.replaceProjectBinding(
                .init(
                    workspaceRoot: repositoryPath,
                    projectId: created.id,
                    expectedRevision: nil
                )
            )
        }
        if !adapters.isEmpty {
            let agentRuntimePath = try bundledAgentRuntimePath()
            for repositoryPath in repositoryPaths {
                for adapter in adapters.sorted(by: { $0.rawValue < $1.rawValue }) {
                    _ = try await daemon.installProjectAgentAdapter(
                        .init(
                            projectId: created.id,
                            workspaceRoot: repositoryPath,
                            adapter: adapter,
                            runtimeBinaryPath: agentRuntimePath,
                            expectedRevision: nil
                        )
                    )
                }
            }
        }
        selectedSection = .memory
        showsProjectSettings = false
        await selectProject(created.id)
    }

    func projectRecord(_ projectId: String, refresh: Bool = false) async throws -> ProjectRecord {
        if !refresh, let cached = projectMetadata[projectId] {
            return cached
        }
        let project: ProjectRecord = try await server.get("/api/v1/projects/\(projectId)")
        projectMetadata[projectId] = project
        return project
    }

    func updateProject(
        _ projectId: String,
        expectedRevision: Int,
        name: String,
        description: String
    ) async throws -> ProjectRecord {
        let updated: ProjectRecord = try await server.send(
            method: "PATCH",
            path: "/api/v1/projects/\(projectId)",
            headers: ["if-match": String(expectedRevision)],
            body: UpdateProjectRequest(name: name, description: description)
        )
        projectMetadata[projectId] = updated
        if let index = projects.firstIndex(where: { $0.id == projectId }) {
            let current = projects[index]
            projects[index] = ProjectState(
                id: current.id,
                name: updated.name,
                refCommitId: current.refCommitId,
                refEtag: current.refEtag,
                selectedOrgResourceIds: current.selectedOrgResourceIds,
                orgSelectionRevision: current.orgSelectionRevision,
                isLoaded: current.isLoaded
            )
        }
        return updated
    }

    func projectBindings(_ projectId: String) async throws -> [DaemonProjectBinding] {
        try await daemon.projectBindings(projectId)
    }

    func addProjectRepositories(
        _ repositoryPaths: [String],
        projectId: String
    ) async throws -> [DaemonProjectBinding] {
        var bindings: [DaemonProjectBinding] = []
        for repositoryPath in normalizedRepositoryPaths(repositoryPaths) {
            bindings.append(try await daemon.replaceProjectBinding(
                .init(
                    workspaceRoot: repositoryPath,
                    projectId: projectId,
                    expectedRevision: nil
                )
            ))
        }
        return bindings
    }

    func removeProjectRepository(
        _ binding: DaemonProjectBinding,
        adapters: [DaemonProjectAgentAdapter]
    ) async throws {
        for adapter in adapters where adapter.workspaceRoot == binding.workspaceRoot {
            _ = try await daemon.removeProjectAgentAdapter(
                .init(
                    workspaceRoot: binding.workspaceRoot,
                    adapter: adapter.adapter,
                    expectedRevision: adapter.revision
                )
            )
        }
        _ = try await daemon.removeProjectBinding(
            .init(
                workspaceRoot: binding.workspaceRoot,
                expectedRevision: binding.revision
            )
        )
    }

    func projectAgentAdapters(_ projectId: String) async throws -> [DaemonProjectAgentAdapter] {
        try await daemon.projectAgentAdapters(projectId)
    }

    func setProjectAgentAdapter(
        _ adapter: ProjectAgentAdapterKind,
        enabled: Bool,
        projectId: String,
        workspaceRoot: String,
        current: DaemonProjectAgentAdapter?
    ) async throws {
        if enabled {
            _ = try await daemon.installProjectAgentAdapter(
                .init(
                    projectId: projectId,
                    workspaceRoot: workspaceRoot,
                    adapter: adapter,
                    runtimeBinaryPath: try bundledAgentRuntimePath(),
                    expectedRevision: current?.revision
                )
            )
        } else if let current {
            _ = try await daemon.removeProjectAgentAdapter(
                .init(
                    workspaceRoot: workspaceRoot,
                    adapter: adapter,
                    expectedRevision: current.revision
                )
            )
        }
    }

    func showOrgMemory() {
        guard activeProjectId != nil else { return }
        activeProjectId = nil
        showsProjectSettings = false
        selectedItemId = nil
        let tab = visibleTabs.last
        activeTabId = tab?.id
    }

    func selectProject(_ projectId: String) async {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        guard projectId != activeProjectId || !project.isLoaded else { return }
        guard await flushPendingDocumentChanges() else { return }
        let generation = UUID()
        projectSelectionGeneration = generation
        loadingProjectId = projectId
        defer {
            if projectSelectionGeneration == generation {
                loadingProjectId = nil
            }
        }
        do {
            _ = try await daemon.selectProject(projectId)
            guard projectSelectionGeneration == generation else { return }
            activeProjectId = projectId
            let tab = visibleTabs.last
            activeTabId = tab?.id
            selectedItemId = tab?.itemId

            let loader = WorkspaceLoader(daemon: daemon, bootstrap: bootstrap, server: server)
            var loadedProject: (state: ProjectState, resources: [MemoryResource])?
            var needsBackgroundRefresh = project.isLoaded
            if !project.isLoaded {
                if let cached = try await loader.loadCachedProject(id: project.id, name: project.name) {
                    loadedProject = cached
                    needsBackgroundRefresh = true
                } else {
                    loadedProject = try await loader.loadProject(id: project.id, name: project.name)
                }
            }
            guard projectSelectionGeneration == generation else { return }
            if let loadedProject {
                if let index = projects.firstIndex(where: { $0.id == projectId }) {
                    projects[index] = loadedProject.state
                }
                resources.removeAll { $0.projectId == projectId }
                resources += loadedProject.resources
                try await remapDrafts(projectId: projectId)
            }
            guard projectSelectionGeneration == generation else { return }
            if needsBackgroundRefresh {
                Task { [weak self] in
                    await self?.refreshProjectFromServer(
                        projectId: project.id,
                        projectName: project.name,
                        generation: generation
                    )
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func focusIssueSearch() {
        issueSearchFocusToken = UUID()
    }

    func focusReviewSearch() {
        reviewSearchFocusToken = UUID()
    }

    func prepareWorkspaceIndex(includeContent: Bool) async {
        while isPreparingWorkspaceIndex {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let needsProjects = projects.contains { !$0.isLoaded }
        let needsContent = includeContent && resources.contains { !$0.contentLoaded }
        guard needsProjects || needsContent else { return }

        isPreparingWorkspaceIndex = true
        defer { isPreparingWorkspaceIndex = false }
        do {
            let loader = WorkspaceLoader(daemon: daemon, bootstrap: bootstrap, server: server)
            let unloadedProjects = projects.filter { !$0.isLoaded }
            let loadedProjects = try await concurrentMap(unloadedProjects, maxConcurrent: 4) { project in
                try await loader.loadProject(id: project.id, name: project.name)
            }
            for loaded in loadedProjects {
                if let index = projects.firstIndex(where: { $0.id == loaded.state.id }) {
                    projects[index] = loaded.state
                }
                resources.removeAll { $0.projectId == loaded.state.id }
                resources += loaded.resources
            }

            if includeContent {
                let unloadedResources = resources.filter { !$0.contentLoaded }
                let loadedResources = try await concurrentMap(unloadedResources) {
                    try await loader.loadContent(for: $0)
                }
                for loaded in loadedResources {
                    if let index = resources.firstIndex(where: { $0.id == loaded.id }) {
                        resources[index] = loaded
                    }
                }
            }

            for projectId in Set(drafts.map(\.projectId)) {
                try await remapDrafts(projectId: projectId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(_ item: MemoryListItem, mode: WorkbenchTabMode? = nil) {
        showsProjectSettings = false
        let previousTabId = activeVisibleTab?.id
        let resolvedMode = mode ?? (item.supportsMarkdownPreview ? .preview : .source)
        // Org-scope tabs are always visible regardless of the active project,
        // so the tab's projectId must reflect scope (nil for Org), not the
        // carrying project of an Org-scope draft. Reusing item.projectId here
        // leaked the draft's carrying project and hid Org documents while the
        // Org view (or another project) was active.
        let tab = WorkbenchTab(
            section: selectedSection,
            projectId: item.scope == .org ? nil : item.projectId,
            itemId: item.id,
            mode: resolvedMode,
            title: item.document.title
        )
        if !tabs.contains(where: { $0.id == tab.id }) {
            tabs.append(tab)
        }
        selectedItemId = item.id
        if let previousTabId, previousTabId != tab.id {
            navigationBackStack.append(previousTabId)
            navigationForwardStack.removeAll()
        }
        activeTabId = tab.id
        Task { await loadContentIfNeeded(item) }
    }

    func reveal(_ item: MemoryListItem) async {
        selectedSection = .memory
        selectedKind = item.kind
        // Only project-scope items need a project switch; Org-scope items stay
        // in the Org view even when their draft is carried by a project.
        if item.scope == .project, let projectId = item.projectId {
            await selectProject(projectId)
        }
        open(item)
    }

    func item(for tab: WorkbenchTab) -> MemoryListItem? {
        if let resource = resources.first(where: { $0.id == tab.itemId }) {
            let draft = drafts.first {
                $0.targetId == resource.id && $0.status != .discarded && $0.status != .merged
            }
            return .init(
                id: resource.id,
                resource: resource,
                draft: draft,
                inherited: resource.scope == .org
                    && activeProjectId != nil
                    && (activeProject?.selectedOrgResourceIds.contains(resource.id) ?? false)
            )
        }
        if let draft = drafts.first(where: { $0.id == tab.itemId }) {
            let resource = draft.targetId.flatMap { target in resources.first { $0.id == target } }
            return .init(
                id: resource?.id ?? draft.id,
                resource: resource,
                draft: draft,
                inherited: false
            )
        }
        return nil
    }

    func loadContentIfNeeded(_ item: MemoryListItem) async {
        guard item.draft == nil,
              let resource = item.resource,
              !resource.contentLoaded,
              !loadingResourceIds.contains(resource.id) else { return }
        loadingResourceIds.insert(resource.id)
        defer { loadingResourceIds.remove(resource.id) }
        do {
            let loaded = try await WorkspaceLoader(
                daemon: daemon,
                bootstrap: bootstrap,
                server: server
            ).loadContent(for: resource)
            if let index = resources.firstIndex(where: { $0.id == loaded.id }) {
                resources[index] = loaded
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeTab(_ tab: WorkbenchTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        let visibleIndex = visibleTabs.firstIndex(of: tab)
        tabs.remove(at: index)
        navigationBackStack.removeAll { $0 == tab.id }
        navigationForwardStack.removeAll { $0 == tab.id }
        if activeTabId == tab.id {
            let remaining = visibleTabs
            let replacementIndex = min(visibleIndex ?? remaining.count, remaining.count - 1)
            activeTabId = replacementIndex >= 0 ? remaining[replacementIndex].id : nil
            selectedItemId = tabs.first { $0.id == activeTabId }?.itemId
        }
    }

    func selectTab(_ tab: WorkbenchTab) {
        let previousTabId = activeVisibleTab?.id
        guard tab.id != previousTabId else {
            activeTabId = tab.id
            selectedItemId = tab.itemId
            return
        }
        if let previousTabId {
            navigationBackStack.append(previousTabId)
            navigationForwardStack.removeAll()
        }
        activeTabId = tab.id
        selectedItemId = tab.itemId
    }

    func goBack() {
        while let previousId = navigationBackStack.popLast() {
            guard isVisibleTab(previousId) else { continue }
            if let currentId = activeVisibleTab?.id {
                navigationForwardStack.append(currentId)
            }
            activateTab(previousId)
            return
        }
    }

    func goForward() {
        while let nextId = navigationForwardStack.popLast() {
            guard isVisibleTab(nextId) else { continue }
            if let currentId = activeVisibleTab?.id {
                navigationBackStack.append(currentId)
            }
            activateTab(nextId)
            return
        }
    }

    private func isVisibleTab(_ tabId: String) -> Bool {
        visibleTabs.contains { $0.id == tabId }
    }

    private func activateTab(_ tabId: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        activeTabId = tab.id
        selectedItemId = tab.itemId
    }

    @discardableResult
    func closeActiveTab() -> Bool {
        guard let tab = activeVisibleTab else { return false }
        closeTab(tab)
        return true
    }

    func signOut() async {
        guard await flushPendingChanges() else { return }
        _ = try? await server.raw(method: "DELETE", path: "/api/v1/auth/session")
        do {
            _ = try await daemon.replaceProjectConfig(
                .init(
                    serverUrl: AuthenticationClient.serverURL.absoluteString,
                    projectId: nil,
                    accessToken: nil,
                    refreshToken: nil
                )
            )
            account = nil
            organization = nil
            capabilities = []
            projects = []
            resources = []
            drafts = []
            bundles = []
            reviews = []
            tabs = []
            phase = .authenticationRequired
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createMemory(kind: MemoryKind, scope: MemoryScope) async {
        // Org-scope drafts are carried by a project in the daemon; when the
        // user is browsing the Org view without an active project, fall back
        // to the first project as the carrying project.
        let projectId = activeProjectId ?? (scope == .org ? projects.first?.id : nil)
        guard let projectId else { return }
        guard canCreateMemory(kind: kind, scope: scope) else { return }
        let path = uniqueDefaultPath(for: kind, scope: scope)
        let document = defaultDocument(kind: kind, path: path)
        do {
            try await withDraftMutation {
                let response = try await daemon.store(
                    .init(
                        draftId: nil,
                        baseCommitId: scope == .org ? orgRefCommitId : activeProject?.refCommitId,
                        projectId: projectId,
                        scope: scope == .org ? .org : .project,
                        resource: kind.daemonKind,
                        op: .create(
                            path: path,
                            content: daemonContent(kind: kind, document: document),
                            description: nil
                        ),
                        source: .desktop
                    )
                )
                try await refreshDraft(response.draftId)
                selectedItemId = response.draftId
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stageDocumentSave(_ item: MemoryListItem, document: EditableMemoryDocument) {
        let generation = UUID()
        pendingDocumentSaves[item.id] = .init(item: item, document: document, generation: generation)
        documentSaveTasks[item.id]?.cancel()
        documentSaveTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.persistDocumentSave(item.id, generation: generation)
        }
    }

    func flushDocumentSave(_ itemId: String) async throws {
        documentSaveTasks[itemId]?.cancel()
        documentSaveTasks[itemId] = nil
        guard let pending = pendingDocumentSaves[itemId] else { return }
        try await save(pending.item, document: pending.document)
        if pendingDocumentSaves[itemId]?.generation == pending.generation {
            pendingDocumentSaves[itemId] = nil
        }
    }

    func cancelDocumentSave(_ itemId: String) {
        documentSaveTasks[itemId]?.cancel()
        documentSaveTasks[itemId] = nil
        pendingDocumentSaves[itemId] = nil
    }

    func stageBundleSave(
        _ bundle: PersonalBundle,
        name: String,
        description: String,
        resourceIds: Set<String>
    ) {
        let generation = UUID()
        pendingBundleSaves[bundle.id] = .init(
            bundle: bundle,
            name: name,
            description: description,
            resourceIds: resourceIds,
            generation: generation
        )
        bundleSaveTasks[bundle.id]?.cancel()
        bundleSaveTasks[bundle.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.persistBundleSave(bundle.id, generation: generation)
        }
    }

    func flushBundleSave(_ bundleId: String) async throws {
        bundleSaveTasks[bundleId]?.cancel()
        bundleSaveTasks[bundleId] = nil
        guard let pending = pendingBundleSaves[bundleId] else { return }
        try await updateBundle(
            pending.bundle,
            name: pending.name,
            description: pending.description,
            resourceIds: pending.resourceIds
        )
        if pendingBundleSaves[bundleId]?.generation == pending.generation {
            pendingBundleSaves[bundleId] = nil
        }
    }

    func cancelBundleSave(_ bundleId: String) {
        bundleSaveTasks[bundleId]?.cancel()
        bundleSaveTasks[bundleId] = nil
        pendingBundleSaves[bundleId] = nil
    }

    func flushPendingChanges() async -> Bool {
        guard await flushPendingDocumentChanges() else { return false }
        do {
            for bundleId in Array(pendingBundleSaves.keys) {
                try await flushBundleSave(bundleId)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func flushPendingDocumentChanges() async -> Bool {
        do {
            for itemId in Array(pendingDocumentSaves.keys) {
                try await flushDocumentSave(itemId)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func save(_ item: MemoryListItem, document: EditableMemoryDocument) async throws {
        try validate(kind: item.kind, document: document)
        try await withDraftMutation {
            let resource = item.resource
            let draft = currentDraft(for: item)
            guard let projectId = draft?.projectId ?? item.projectId ?? activeProjectId else {
                throw WorkspaceLoadError.noProjects
            }
            guard item.draft == nil || draft != nil else { return }
            guard draft?.isDeletion != true else { return }
            let draftId = draft?.id
            let projectRefCommitId = projects.first { $0.id == projectId }?.refCommitId
            let baseCommitId = draft?.baseCommitId
                ?? resource?.refCommitId
                ?? (item.scope == .org ? orgRefCommitId : projectRefCommitId)
            var response: DaemonDraftOperationResponse?

            if let resource, document.path != (draft?.document.path ?? resource.document.path) {
                response = try await daemon.store(
                    .init(
                        draftId: draftId,
                        baseCommitId: baseCommitId,
                        projectId: projectId,
                        scope: item.scope == .org ? .org : .project,
                        resource: item.kind.daemonKind,
                        op: .rename(id: resource.id, newPath: document.path, description: nil),
                        source: .desktop
                    )
                )
            }

            let targetId = resource?.id ?? draft?.targetId
            let operation: DaemonDraftOperation
            if let targetId {
                operation = .update(
                    id: targetId,
                    content: daemonContent(kind: item.kind, document: document),
                    description: nil
                )
            } else {
                operation = .create(
                    path: document.path,
                    content: daemonContent(kind: item.kind, document: document),
                    description: nil
                )
            }
            response = try await daemon.store(
                .init(
                    draftId: response?.draftId ?? draftId,
                    baseCommitId: baseCommitId,
                    projectId: projectId,
                    scope: item.scope == .org ? .org : .project,
                    resource: item.kind.daemonKind,
                    op: operation,
                    source: .desktop
                )
            )
            if let response {
                try await refreshDraft(response.draftId)
                selectedItemId = resource?.id ?? response.draftId
            }
        }
    }

    func delete(_ item: MemoryListItem) async {
        guard let projectId = item.projectId ?? activeProjectId,
              let targetId = item.resource?.id ?? item.draft?.targetId else { return }
        do {
            try await withDraftMutation {
                let draft = currentDraft(for: item)
                let response = try await daemon.store(
                    .init(
                        draftId: draft?.id,
                        baseCommitId: draft?.baseCommitId ?? item.resource?.refCommitId,
                        projectId: projectId,
                        scope: item.scope == .org ? .org : .project,
                        resource: item.kind.daemonKind,
                        op: .delete(id: targetId, description: nil),
                        source: .desktop
                    )
                )
                try await refreshDraft(response.draftId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func discard(_ draft: LocalDraft) async {
        do {
            try await withDraftMutation {
                _ = try await daemon.store(
                    .init(
                        draftId: draft.id,
                        baseCommitId: draft.baseCommitId,
                        projectId: draft.projectId,
                        scope: draft.scope == .org ? .org : .project,
                        resource: draft.kind.daemonKind,
                        op: .discard(id: draft.targetId ?? draft.id),
                        source: .desktop
                    )
                )
                drafts.removeAll { $0.id == draft.id }
                selectedItemId = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retrySync() async {
        do {
            _ = try await daemon.retrySync()
            await refreshSyncStatus()
        } catch {
            syncStatusAvailable = false
            errorMessage = error.localizedDescription
        }
    }

    func refreshSyncStatus() async {
        guard phase == .ready, let runtime else { return }
        do {
            let sync = try await daemon.syncStatus()
            self.runtime = .init(
                health: runtime.health,
                sync: sync,
                mcp: runtime.mcp,
                serverDataSource: server.dataSource
            )
            syncStatusAvailable = true
            await refreshDraftInventory(includeFailed: sync.pendingOperationCount > 0)
        } catch {
            syncStatusAvailable = false
        }
    }

    func addOrgMemories(resourceIds: Set<String>, toProject projectId: String) async throws {
        try await mutateProjectOrgSelection(
            projectId: projectId,
            resourceIds: resourceIds,
            mutation: .add
        )
    }

    func removeOrgMemoriesFromActiveProject(resourceIds: Set<String>) async throws {
        guard let projectId = activeProjectId else { throw WorkspaceLoadError.noProjects }
        try await mutateProjectOrgSelection(
            projectId: projectId,
            resourceIds: resourceIds,
            mutation: .remove
        )
    }

    private func mutateProjectOrgSelection(
        projectId: String,
        resourceIds: Set<String>,
        mutation: ProjectOrgSelectionMutation
    ) async throws {
        guard canManageOrgSelection else {
            throw ServerClientError.forbidden("Only Organization owners and admins can manage project memory.")
        }
        guard projects.contains(where: { $0.id == projectId }) else {
            throw ProjectMemorySelectionError.projectUnavailable
        }
        try validateOrgResourceIds(resourceIds)
        try await withProjectOrgSelectionMutation {
            let current: ProjectOrgSelection = try await server.get(
                "/api/v1/projects/\(projectId)/org-selections"
            )
            let currentIds = projectOrgResourceIds(current)
            let nextIds = mutation.applying(resourceIds, to: currentIds)
            guard nextIds != currentIds else { return }
            let selection = try await replaceProjectOrgSelection(
                projectId: projectId,
                expectedRevision: current.revision,
                resourceIds: nextIds
            )
            await applyProjectOrgSelection(selection, toProject: projectId)
        }
    }

    private func applyProjectOrgSelection(
        _ selection: ProjectOrgSelection,
        toProject projectId: String
    ) async {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let project = projects[index]
        let commit: (value: CommitStateResponse, response: DaemonServerResponse)? = try? await server.getWithMetadata(
            "/api/v1/projects/\(projectId)/commit-state"
        )
        projects[index] = ProjectState(
            id: project.id,
            name: project.name,
            refCommitId: commit?.value.ref.commitId ?? project.refCommitId,
            refEtag: commit?.response.headers.first {
                $0.key.caseInsensitiveCompare("etag") == .orderedSame
            }?.value ?? project.refEtag,
            selectedOrgResourceIds: projectOrgResourceIds(selection),
            orgSelectionRevision: selection.revision,
            isLoaded: project.isLoaded
        )
        if projectId == activeProjectId {
            _ = try? await daemon.retrySync(channel: "commits")
        }
    }

    private func replaceProjectOrgSelection(
        projectId: String,
        expectedRevision: Int,
        resourceIds: Set<String>
    ) async throws -> ProjectOrgSelection {
        let selected = resources.filter { $0.scope == .org && resourceIds.contains($0.id) }
        let request = ReplaceProjectOrgSelectionRequest(resourceIds: selected.map(\.id))
        return try await server.send(
            method: "PUT",
            path: "/api/v1/projects/\(projectId)/org-selections",
            headers: ["If-Match": String(expectedRevision)],
            body: request
        )
    }

    private func initializeProjectMemory(
        projectId: String,
        bundleId: String?
    ) async throws -> ProjectOrgSelection {
        let current: ProjectOrgSelection = try await server.get(
            "/api/v1/projects/\(projectId)/org-selections"
        )
        guard let bundleId else { return current }
        guard let bundle = bundles.first(where: { $0.id == bundleId }) else {
            throw ProjectSetupError.bundleNotFound
        }
        let resourceIds = Set(bundle.resourceIds)
        do {
            try validateOrgResourceIds(resourceIds)
        } catch {
            throw ProjectSetupError.bundleContainsUnavailableMemory
        }
        guard projectOrgResourceIds(current) != resourceIds else { return current }
        return try await replaceProjectOrgSelection(
            projectId: projectId,
            expectedRevision: current.revision,
            resourceIds: resourceIds
        )
    }

    private func validateOrgResourceIds(_ resourceIds: Set<String>) throws {
        let available = Set(resources.lazy.filter { $0.scope == .org }.map(\.id))
        guard resourceIds.isSubset(of: available) else {
            throw ProjectMemorySelectionError.invalidOrgResources
        }
    }

    private func projectOrgResourceIds(_ selection: ProjectOrgSelection) -> Set<String> {
        Set(selection.memories.map(\.memoryId))
    }

    func createBundle() async {
        do {
            try await withBundleMutation {
                let detail: PersonalBundleDetail = try await server.send(
                    method: "POST",
                    path: "/api/v1/me/bundles",
                    body: PersonalBundleRequest(
                        name: "Untitled Bundle",
                        description: "",
                        resourceIds: []
                    )
                )
                let bundle = PersonalBundle(
                    id: detail.bundle.bundleId,
                    name: detail.bundle.name,
                    description: detail.bundle.description,
                    resourceIds: [],
                    revision: detail.bundle.revision,
                    updatedAt: detail.bundle.updatedAt
                )
                bundles.insert(bundle, at: 0)
                selectedBundleId = bundle.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateBundle(
        _ bundle: PersonalBundle,
        name: String,
        description: String,
        resourceIds: Set<String>
    ) async throws {
        try await withBundleMutation {
            guard let current = bundles.first(where: { $0.id == bundle.id }) else { return }
            try validateOrgResourceIds(resourceIds)
            let selected = resources.filter {
                $0.scope == .org && resourceIds.contains($0.id)
            }
            let request = PersonalBundleRequest(
                name: name,
                description: description,
                resourceIds: selected.map(\.id)
            )
            let detail: PersonalBundleDetail = try await server.send(
                method: "PATCH",
                path: "/api/v1/me/bundles/\(bundle.id)",
                headers: ["If-Match": String(current.revision)],
                body: request
            )
            let updated = PersonalBundle(
                id: detail.bundle.bundleId,
                name: detail.bundle.name,
                description: detail.bundle.description,
                resourceIds: detail.memories.map(\.memoryId),
                revision: detail.bundle.revision,
                updatedAt: detail.bundle.updatedAt
            )
            if let index = bundles.firstIndex(where: { $0.id == updated.id }) {
                bundles[index] = updated
            }
        }
    }

    func deleteBundle(_ bundle: PersonalBundle) async {
        do {
            try await withBundleMutation {
                guard let current = bundles.first(where: { $0.id == bundle.id }) else { return }
                let response = try await server.raw(
                    method: "DELETE",
                    path: "/api/v1/me/bundles/\(bundle.id)",
                    headers: ["If-Match": String(current.revision)]
                )
                guard (200..<300).contains(response.status) else {
                    throw ServerClientError.response(status: response.status, message: response.body)
                }
                bundles.removeAll { $0.id == bundle.id }
                selectedBundleId = bundles.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestReview(
        for draft: LocalDraft,
        title: String,
        description: String,
        candidate: DraftReconciliationCandidate? = nil,
        resolvedState: ReconciliationResourceState? = nil
    ) async throws {
        guard let serverId = draft.serverId else {
            throw ReviewRequestError.draftNotSynchronized
        }
        guard draft.freshness == .current || candidate != nil else {
            throw ReviewRequestError.reconciliationRequired
        }
        let detail: ReviewDetail = try await server.send(
            method: "POST",
            path: "/api/v1/reviews",
            headers: ["If-Match": Self.refETag(candidate?.currentCommitId ?? draft.currentCommitId)],
            body: CreateReviewRequest(
                draftId: serverId,
                expectedDraftVersion: candidate?.draftVersion ?? draft.serverVersion,
                title: title,
                description: description,
                candidateId: candidate?.candidateId,
                resolvedState: resolvedState
            )
        )
        let record = WorkspaceLoader.mapReview(detail)
        reviews.insert(record, at: 0)
        selectedReviewId = record.id
        selectedSection = .reviews
    }

    func resubmit(
        _ review: ReviewRecord,
        detail: ReviewDetail,
        candidate: DraftReconciliationCandidate? = nil,
        resolvedState: ReconciliationResourceState? = nil
    ) async throws {
        guard isReviewAuthor(review) else {
            throw ServerClientError.forbidden("Only the draft author can resubmit this Review.")
        }
        guard detail.draft.coordination.freshness == .current || candidate != nil else {
            throw ReviewRequestError.reconciliationRequired
        }
        let updated: ReviewDetail = try await server.send(
            method: "POST",
            path: "/api/v1/reviews/\(review.id)/submissions",
            headers: [
                "If-Match": Self.refETag(
                    candidate?.currentCommitId ?? detail.draft.coordination.currentCommitId
                )
            ],
            body: CreateReviewSubmissionRequest(
                expectedReviewVersion: review.version,
                expectedDraftVersion: candidate?.draftVersion ?? detail.draft.version,
                title: review.title,
                description: review.description,
                candidateId: candidate?.candidateId,
                resolvedState: resolvedState
            )
        )
        replaceReview(with: WorkspaceLoader.mapReview(updated))
    }

    func reviewChangeSources(for detail: ReviewDetail) async throws -> ReviewChangeSources {
        async let baseRequest: CommitPayload? = loadCommit(detail.draft.baseCommitId)
        async let currentRequest: CommitPayload? = loadCommit(detail.draft.coordination.currentCommitId)
        let (base, current) = try await (baseRequest, currentRequest)
        return try WorkspaceLoader.mapReviewChangeSources(detail: detail, base: base, current: current)
    }

    func reconciliationCandidate(for draft: LocalDraft) async throws -> DraftReconciliationCandidate {
        guard let serverId = draft.serverId else {
            throw ReviewRequestError.draftNotSynchronized
        }
        return try await server.send(
            method: "POST",
            path: "/api/v1/drafts/\(serverId)/reconciliation-candidates",
            body: CreateDraftReconciliationCandidateRequest(
                expectedDraftVersion: draft.serverVersion
            )
        )
    }

    func reconciliationCandidate(for detail: ReviewDetail) async throws -> DraftReconciliationCandidate {
        try await server.send(
            method: "POST",
            path: "/api/v1/drafts/\(detail.draft.draftId)/reconciliation-candidates",
            body: CreateDraftReconciliationCandidateRequest(
                expectedDraftVersion: detail.draft.version
            )
        )
    }

    func applyReconciliation(
        draftId: String,
        draftVersion: Int,
        candidate: DraftReconciliationCandidate,
        resolvedState: ReconciliationResourceState?
    ) async throws {
        let _: DraftRebaseResult = try await server.send(
            method: "POST",
            path: "/api/v1/drafts/\(draftId)/rebases",
            headers: ["If-Match": Self.refETag(candidate.currentCommitId)],
            body: CreateDraftRebaseRequest(
                candidateId: candidate.candidateId,
                expectedDraftVersion: draftVersion,
                resolvedState: resolvedState
            )
        )
        _ = try? await daemon.retrySync(channel: "drafts")
        await reload()
    }

    func reviewDetail(_ reviewId: String) async throws -> ReviewDetail {
        try await server.get("/api/v1/reviews/\(reviewId)")
    }

    func addComment(
        _ body: String,
        to review: ReviewRecord,
        anchorPath: String? = nil,
        anchorLine: Int? = nil
    ) async throws {
        let _: ReviewComment = try await server.send(
            method: "POST",
            path: "/api/v1/reviews/\(review.id)/comments",
            body: CreateReviewCommentRequest(
                body: body,
                expectedReviewVersion: review.version,
                anchorPath: anchorPath,
                anchorLine: anchorLine
            )
        )
        try await refreshReview(review.id)
    }

    func decide(_ review: ReviewRecord, decision: String, note: String) async throws {
        let detail: ReviewDetail = try await server.send(
            method: "POST",
            path: "/api/v1/reviews/\(review.id)/decisions",
            body: CreateReviewDecisionRequest(
                decision: decision,
                expectedReviewVersion: review.version,
                body: note
            )
        )
        replaceReview(with: WorkspaceLoader.mapReview(detail))
    }

    func merge(_ review: ReviewRecord) async throws {
        guard canMergeReviews else {
            throw ServerClientError.forbidden("Your account cannot merge Reviews.")
        }
        guard let project = projects.first(where: { $0.id == review.projectId }), !project.refEtag.isEmpty else {
            throw ServerClientError.invalidResponse("The project Ref ETag is unavailable.")
        }
        let _: ReviewMergeResponse = try await server.send(
            method: "POST",
            path: "/api/v1/reviews/\(review.id)/merges",
            headers: ["If-Match": project.refEtag],
            body: CreateReviewMergeRequest(expectedReviewVersion: review.version)
        )
        await reload()
    }

    private func currentDraft(for item: MemoryListItem) -> LocalDraft? {
        if let draftId = item.draft?.id,
           let draft = drafts.first(where: { $0.id == draftId }) {
            return draft
        }
        guard let resourceId = item.resource?.id else { return item.draft }
        return drafts.first {
            $0.targetId == resourceId && $0.status != .discarded && $0.status != .merged
        }
    }

    private func withDraftMutation<T>(_ operation: () async throws -> T) async throws -> T {
        await draftMutationGate.lock()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await draftMutationGate.unlock()
            return result
        } catch {
            await draftMutationGate.unlock()
            throw error
        }
    }

    private func withBundleMutation<T>(_ operation: () async throws -> T) async throws -> T {
        await bundleMutationGate.lock()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await bundleMutationGate.unlock()
            return result
        } catch {
            await bundleMutationGate.unlock()
            throw error
        }
    }

    private func withProjectOrgSelectionMutation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        await projectOrgSelectionMutationGate.lock()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await projectOrgSelectionMutationGate.unlock()
            return result
        } catch {
            await projectOrgSelectionMutationGate.unlock()
            throw error
        }
    }

    private func persistDocumentSave(_ itemId: String, generation: UUID) async {
        guard let pending = pendingDocumentSaves[itemId], pending.generation == generation else { return }
        do {
            try await save(pending.item, document: pending.document)
            if pendingDocumentSaves[itemId]?.generation == generation {
                pendingDocumentSaves[itemId] = nil
                documentSaveTasks[itemId] = nil
            }
        } catch is CancellationError {
            return
        } catch {
            if pendingDocumentSaves[itemId]?.generation == generation {
                documentSaveTasks[itemId] = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func persistBundleSave(_ bundleId: String, generation: UUID) async {
        guard let pending = pendingBundleSaves[bundleId], pending.generation == generation else { return }
        do {
            try await updateBundle(
                pending.bundle,
                name: pending.name,
                description: pending.description,
                resourceIds: pending.resourceIds
            )
            if pendingBundleSaves[bundleId]?.generation == generation {
                pendingBundleSaves[bundleId] = nil
                bundleSaveTasks[bundleId] = nil
            }
        } catch is CancellationError {
            return
        } catch {
            if pendingBundleSaves[bundleId]?.generation == generation {
                bundleSaveTasks[bundleId] = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ snapshot: WorkspaceSnapshot) {
        account = snapshot.account
        organization = snapshot.organization
        capabilities = snapshot.capabilities
        projects = snapshot.projects
        projectMetadata = projectMetadata.filter { projectId, _ in
            projects.contains { $0.id == projectId }
        }
        orgRefCommitId = snapshot.orgRefCommitId
        orgRefEtag = snapshot.orgRefEtag
        activeProjectId = snapshot.activeProjectId
        resources = snapshot.resources
        drafts = snapshot.drafts
        bundles = snapshot.bundles
        reviews = snapshot.reviews
        runtime = snapshot.runtime
        applyLocalAgentAdapterResult(.init(
            conflicts: snapshot.legacyAgentAdapterConflicts,
            inspectionWarning: snapshot.legacyAgentAdapterInspectionWarning
        ))
        syncStatusAvailable = true
        selectedBundleId = selectedBundleId ?? bundles.first?.id
        if let selectedReviewId,
           !reviews.contains(where: { $0.id == selectedReviewId }) {
            self.selectedReviewId = nil
        }
        if projects.isEmpty {
            selectedSection = .memory
            showsProjectSettings = false
            tabs = []
            activeTabId = nil
            selectedItemId = nil
        }
    }

    private func applyLocalAgentAdapterResult(_ result: LocalAgentAdapterReconciliationResult) {
        legacyAgentAdapterConflicts = result.conflicts
        legacyAgentAdapterInspectionWarning = result.inspectionWarning
        errorMessage = Self.localAgentAdapterWarning(result)
    }

    static func localAgentAdapterWarning(
        _ result: LocalAgentAdapterReconciliationResult
    ) -> String? {
        var messages: [String] = []
        if let inspectionWarning = result.inspectionWarning {
            messages.append(inspectionWarning)
        }
        let visible = result.conflicts.prefix(3).map { conflict in
            let adapter = conflict.adapter == .claudeCode ? "Claude Code" : conflict.adapter.rawValue
            return "\(adapter) \(conflict.scope) integration at \(conflict.targetRoot): \(conflict.message)"
        }
        messages.append(contentsOf: visible)
        if result.conflicts.count > visible.count {
            messages.append("\(result.conflicts.count - visible.count) more legacy integrations need review.")
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private func refreshDraft(_ draftId: String) async throws {
        let detail = try await daemon.draft(draftId)
        let mapped = WorkspaceLoader.mapDraft(detail, resources: resources)
        if let index = drafts.firstIndex(where: { $0.id == mapped.id }) {
            drafts[index] = mapped
        } else {
            drafts.append(mapped)
        }
    }

    private func remapDrafts(projectId: String) async throws {
        let projectDrafts = drafts.filter { $0.projectId == projectId }
        let targetIds = Set(projectDrafts.compactMap(\.targetId))
        let baselines = resources.filter { targetIds.contains($0.id) && !$0.contentLoaded }
        let loader = WorkspaceLoader(daemon: daemon, bootstrap: bootstrap, server: server)
        let loadedBaselines = try await concurrentMap(baselines) { try await loader.loadContent(for: $0) }
        for loaded in loadedBaselines {
            if let index = resources.firstIndex(where: { $0.id == loaded.id }) {
                resources[index] = loaded
            }
        }
        let resourceSnapshot = resources
        let mapped = try await concurrentMap(projectDrafts) { draft in
            WorkspaceLoader.mapDraft(
                try await self.daemon.draft(draft.id),
                resources: resourceSnapshot
            )
        }
        drafts.removeAll { $0.projectId == projectId }
        drafts += mapped
    }

    nonisolated static func draftInventoryPlan(
        summaries: [DaemonDraftSummary],
        currentDrafts: [LocalDraft],
        includeFailed: Bool
    ) -> DraftInventoryPlan {
        let currentById = Dictionary(
            currentDrafts.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var refreshIds = Set<String>()
        var terminalIds = Set<String>()

        for summary in summaries {
            guard summary.status == .open || summary.status == .submitted else {
                terminalIds.insert(summary.draftId)
                continue
            }
            guard let current = currentById[summary.draftId] else {
                refreshIds.insert(summary.draftId)
                continue
            }
            let summaryChanged = current.projectId != summary.projectId
                || current.serverId != summary.serverDraftId
                || current.serverVersion != summary.serverVersion
                || current.baseCommitId != summary.baseCommitId
                || current.currentCommitId != summary.currentCommitId
                || current.freshness != summary.freshness
                || current.hasUpstreamResourceChanges != summary.hasUpstreamResourceChanges
                || current.reconciliation != summary.reconciliation
                || current.reconciliationCandidateId != summary.reconciliationCandidateId
                || current.scope != (summary.scope == .org ? .org : .project)
                || current.kind.daemonKind != summary.resourceKind
                || current.targetId != summary.targetId
                || current.status != summary.status
                || current.updatedAt != summary.updatedAt
                || (summary.path != nil && current.document.path != summary.path)
            let syncUnsettled = [.queued, .syncing, .retrying].contains(current.syncStatus)
                || (includeFailed && current.syncStatus == .failed)
            if summaryChanged || syncUnsettled {
                refreshIds.insert(summary.draftId)
            }
        }

        return .init(refreshIds: refreshIds, terminalIds: terminalIds)
    }

    private func refreshDraftInventory(includeFailed: Bool) async {
        guard let page = try? await daemon.listDrafts(.init(limit: 500)) else { return }
        let plan = Self.draftInventoryPlan(
            summaries: page.items,
            currentDrafts: drafts,
            includeFailed: includeFailed
        )
        let pendingDraftIds = Set(drafts.compactMap { draft in
            if pendingDocumentSaves[draft.id] != nil {
                return draft.id
            }
            if let targetId = draft.targetId, pendingDocumentSaves[targetId] != nil {
                return draft.id
            }
            return nil
        })
        drafts.removeAll {
            plan.terminalIds.contains($0.id) && !pendingDraftIds.contains($0.id)
        }

        let refreshIds = plan.refreshIds.subtracting(pendingDraftIds)
        guard !refreshIds.isEmpty else { return }
        let summaries = page.items.filter { refreshIds.contains($0.draftId) }
        let targetIds = Set(summaries.compactMap(\.targetId))
        let baselines = resources.filter { targetIds.contains($0.id) && !$0.contentLoaded }
        let loader = WorkspaceLoader(daemon: daemon, bootstrap: bootstrap, server: server)
        let loadedBaselines = try? await concurrentMap(baselines) {
            try await loader.loadContent(for: $0)
        }
        if let loadedBaselines {
            for loaded in loadedBaselines {
                if let index = resources.firstIndex(where: { $0.id == loaded.id }) {
                    resources[index] = loaded
                }
            }
        }

        let resourceSnapshot = resources
        let mappedDrafts = try? await concurrentMap(summaries) { summary in
            WorkspaceLoader.mapDraft(
                try await self.daemon.draft(summary.draftId),
                resources: resourceSnapshot
            )
        }
        guard let mappedDrafts else { return }
        for mapped in mappedDrafts {
            if let index = drafts.firstIndex(where: { $0.id == mapped.id }) {
                drafts[index] = mapped
            } else {
                drafts.append(mapped)
            }
        }
    }

    private func refreshProjectFromServer(
        projectId: String,
        projectName: String,
        generation: UUID
    ) async {
        do {
            let loaded = try await WorkspaceLoader(
                daemon: daemon,
                bootstrap: bootstrap,
                server: server
            ).loadProject(id: projectId, name: projectName)
            guard projectSelectionGeneration == generation, activeProjectId == projectId else { return }
            if let index = projects.firstIndex(where: { $0.id == projectId }) {
                projects[index] = loaded.state
            }
            resources.removeAll { $0.projectId == projectId }
            resources += loaded.resources
            try await remapDrafts(projectId: projectId)
        } catch {
            // The installed Commit remains usable; commit sync reports refresh failures separately.
        }
    }

    private func refreshReview(_ reviewId: String) async throws {
        let detail: ReviewDetail = try await server.get("/api/v1/reviews/\(reviewId)")
        replaceReview(with: WorkspaceLoader.mapReview(detail))
    }

    func replaceReview(with review: ReviewRecord) {
        if let index = reviews.firstIndex(where: { $0.id == review.id }) {
            reviews[index] = review
        } else {
            reviews.insert(review, at: 0)
        }
    }

    private func loadCommit(_ commitId: String?) async throws -> CommitPayload? {
        guard let commitId else { return nil }
        return try await server.get("/api/v1/commits/\(commitId)")
    }

    private static func refETag(_ commitId: String?) -> String {
        "\"\(commitId ?? "ref-none")\""
    }

    private func uniqueDefaultPath(for kind: MemoryKind, scope: MemoryScope) -> String {
        let base: String
        switch kind {
        case .context: base = "untitled.md"
        case .rules: base = "untitled.md"
        case .workflows: base = "workflow/untitled.md"
        }
        let paths = Set(resources.filter { $0.kind == kind && $0.scope == scope }.map(\.document.path))
            .union(drafts.filter { $0.kind == kind && $0.scope == scope }.map(\.document.path))
        guard paths.contains(base) else { return base }
        let extensionStart = base.lastIndex(of: ".") ?? base.endIndex
        let stem = String(base[..<extensionStart])
        let suffix = String(base[extensionStart...])
        var index = 2
        while paths.contains("\(stem)-\(index)\(suffix)") { index += 1 }
        return "\(stem)-\(index)\(suffix)"
    }

    private func normalizedRepositoryPaths(_ paths: [String]) -> [String] {
        Array(
            Set(
                paths.compactMap { path in
                    let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
                    return normalized.isEmpty ? nil : URL(fileURLWithPath: normalized).standardized.path
                }
            )
        )
        .sorted()
    }

    private func bundledAgentRuntimePath() throws -> String {
        try AppBundleRuntimeLocation.requireStable(Bundle.main.bundleURL)
        guard let path = Bundle.main.resourceURL?.appending(path: "clumsiesd").path,
              FileManager.default.isExecutableFile(atPath: path) else {
            throw ProjectSetupError.bundledAgentRuntimeMissing
        }
        return path
    }

    private func defaultDocument(kind: MemoryKind, path: String) -> EditableMemoryDocument {
        switch kind {
        case .context:
            .init(title: "Untitled", path: path, body: "")
        case .rules:
            .init(title: "Untitled rule", path: path, body: "# Untitled rule\n")
        case .workflows:
            .init(
                title: "Untitled workflow",
                path: path,
                body: "# Untitled workflow\n"
            )
        }
    }

    private func daemonContent(kind: MemoryKind, document: EditableMemoryDocument) -> DaemonDraftContent {
        .init(description: nil, content: document.body)
    }

    private func validate(kind: MemoryKind, document: EditableMemoryDocument) throws {
        let path = document.path
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        if path.isEmpty
            || path.hasPrefix("/")
            || path.hasSuffix("/")
            || segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            throw MemoryValidationError.invalidPath("Use a normalized relative path with / separators.")
        }
        if kind == .workflows && !path.hasPrefix("workflow/") {
            throw MemoryValidationError.invalidPath("Workflow paths must use the workflow/ namespace.")
        }
        if kind == .rules && path.lowercased().hasPrefix("workflow/") {
            throw MemoryValidationError.invalidPath("Rule paths cannot use the workflow/ namespace.")
        }
        if kind == .rules && document.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MemoryValidationError.emptyRule
        }
    }
}

struct WorkspaceLoader: Sendable {
    let daemon: DaemonXPCClient
    let bootstrap: DaemonBootstrapController
    let server: ServerClient

    func load(
        onLocalAgentAdapters: @MainActor @Sendable (LocalAgentAdapterReconciliationResult) async
            -> Void = { _ in }
    ) async throws -> WorkspaceSnapshot {
        server.resetDataSource()
        let health = try await ensureDaemon()
        let (config, me, localAgentAdapters) = try await Self.loadAuthenticatedWorkspaceIdentity(
            reconcileLocalAgentAdapters: {
                try await reconcileInstalledAgentAdapters()
            },
            projectConfig: {
                try await daemon.projectConfig()
            },
            retrySync: {
                _ = try? await daemon.retrySync()
            },
            currentUser: {
                try await server.get("/api/v1/me")
            },
            onLocalAgentAdapters: { result in
                await onLocalAgentAdapters(result)
            }
        )
        let activeProjectId = configuredProject(config, me: me)
        if let activeProjectId, config.projectId != activeProjectId {
            _ = try await daemon.selectProject(activeProjectId)
        }

        async let orgCommitRequest: (value: CommitStateResponse, response: DaemonServerResponse) = server.getWithMetadata(
            "/api/v1/org/commit-state"
        )
        let projectStates: [ProjectState]
        if let activeProjectId {
            projectStates = try await loadProjectStates(
                me.projects,
                activeProjectId: activeProjectId
            )
        } else {
            projectStates = []
        }
        let orgCommit = try await orgCommitRequest

        async let draftPageRequest = daemon.listDrafts(.init(limit: 500))
        async let bundlesRequest = loadBundles()
        async let reviewsRequest = loadReviews()
        async let syncRequest = daemon.syncStatus()
        async let mcpRequest = daemon.mcpStatus()

        var scopes = [
            ResourceLoadScope(projectId: nil, projectName: nil, refCommitId: orgCommit.value.ref.commitId),
        ]
        if let activeProjectId,
           let activeProject = projectStates.first(where: { $0.id == activeProjectId }) {
            scopes.append(ResourceLoadScope(
                projectId: activeProject.id,
                projectName: activeProject.name,
                refCommitId: activeProject.refCommitId
            ))
        }
        let resourceGroups = try await concurrentMap(scopes, maxConcurrent: 2) { scope in
            try await loadResources(
                projectId: scope.projectId,
                projectName: scope.projectName,
                refCommitId: scope.refCommitId
            )
        }
        var resources = resourceGroups.flatMap { $0 }

        let draftPage = try await draftPageRequest
        let accessibleProjectIds = Set(me.projects.map(\.projectId))
        let activeDrafts = draftPage.items.filter {
            $0.status != .discarded
                && $0.status != .merged
                && accessibleProjectIds.contains($0.projectId)
        }
        let targetIds = Set(activeDrafts.compactMap(\.targetId))
        let baselines = resources.filter { targetIds.contains($0.id) && !$0.contentLoaded }
        let loadedBaselines = try await concurrentMap(baselines) { try await loadContent(for: $0) }
        for loaded in loadedBaselines {
            if let index = resources.firstIndex(where: { $0.id == loaded.id }) {
                resources[index] = loaded
            }
        }
        let resourceSnapshot = resources
        let drafts = try await concurrentMap(activeDrafts) { summary in
            Self.mapDraft(try await daemon.draft(summary.draftId), resources: resourceSnapshot)
        }

        let (bundles, reviews, syncStatus, mcpStatus) = try await (
            bundlesRequest,
            reviewsRequest,
            syncRequest,
            mcpRequest
        )
        return .init(
            account: me.user,
            organization: me.org,
            capabilities: Set(me.capabilities),
            projects: projectStates,
            activeProjectId: activeProjectId,
            orgRefCommitId: orgCommit.value.ref.commitId,
            orgRefEtag: etag(from: orgCommit.response),
            resources: resources,
            drafts: drafts,
            bundles: bundles,
            reviews: reviews,
            runtime: .init(
                health: health,
                sync: syncStatus,
                mcp: mcpStatus,
                serverDataSource: server.dataSource
            ),
            legacyAgentAdapterConflicts: localAgentAdapters.conflicts,
            legacyAgentAdapterInspectionWarning: localAgentAdapters.inspectionWarning
        )
    }

    func loadProject(id: String, name: String) async throws -> (state: ProjectState, resources: [MemoryResource]) {
        let state = try await loadProjectState(.init(projectId: id, name: name))
        let resources = try await loadResources(
            projectId: state.id,
            projectName: state.name,
            refCommitId: state.refCommitId
        )
        return (state, resources)
    }

    func loadCachedProject(
        id: String,
        name: String
    ) async throws -> (state: ProjectState, resources: [MemoryResource])? {
        let checkout = try await daemon.projectCheckout(id)
        guard checkout.ready else { return nil }
        return Self.mapProjectCheckout(checkout, projectName: name)
    }

    static func mapProjectCheckout(
        _ checkout: DaemonProjectCheckout,
        projectName: String
    ) -> (state: ProjectState, resources: [MemoryResource]) {
        let resources = checkout.resources.compactMap { resource -> MemoryResource? in
            guard resource.scope == .project else { return nil }
            let kind = MemoryKind(resource.resourceKind)
            var document = EditableMemoryDocument(
                title: title(from: resource.path),
                path: resource.path,
                body: ""
            )
            document = apply(content: resource.content, to: document)
            return .init(
                id: resource.resourceId,
                scope: .project,
                projectId: checkout.projectId,
                projectName: projectName,
                kind: kind,
                contentHash: resource.contentHash,
                updatedAt: checkout.commitCreatedAt ?? "",
                refCommitId: checkout.commitId,
                contentLoaded: true,
                document: document
            )
        }
        return (
            .init(
                id: checkout.projectId,
                name: projectName,
                refCommitId: checkout.commitId,
                refEtag: checkout.refEtag ?? "",
                selectedOrgResourceIds: Set(checkout.selectedOrgResourceIds),
                orgSelectionRevision: checkout.orgSelectionRevision,
                isLoaded: true
            ),
            resources
        )
    }

    func loadContent(for resource: MemoryResource) async throws -> MemoryResource {
        guard !resource.contentLoaded else { return resource }
        let prefix = resource.projectId.map { "/api/v1/projects/\($0)" } ?? "/api/v1/org"
        var loaded = resource
        let detail: MemoryDetail = try await server.get("\(prefix)/memories/\(resource.id)")
        loaded.document.body = detail.content
        loaded.contentLoaded = true
        return loaded
    }

    private func ensureDaemon() async throws -> DaemonHealth {
        let readiness = DaemonStartupReadiness()
        if ProcessInfo.processInfo.environment["CLUMSIES_SKIP_DAEMON_BUILD"] != "1" {
            _ = try await bootstrap.ensureRunning()
        }

        do {
            return try await readiness.waitForHealth { timeout in
                try await daemon.health(timeout: timeout)
            }
        } catch is DaemonXPCError {
            let status = await bootstrap.status()
            var details: [String] = []
            if status.installed {
                details.append("installed: true")
            } else {
                details.append("installed: false")
            }
            if status.running {
                details.append("running: true")
            } else {
                details.append("running: false")
            }
            if let pid = status.pid {
                details.append("pid: \(pid)")
            }
            if let lastError = status.error, !lastError.isEmpty {
                details.append("error: \(lastError)")
            }
            let detailString = details.joined(separator: ", ")
            throw DaemonXPCError.connectionFailed(detail: detailString.isEmpty ? nil : detailString)
        }
    }

    /// Move every daemon-owned integration to the runtime embedded in the
    /// currently running App before authentication or Server access. Adapter
    /// files deliberately point at the App bundle, so an App update must
    /// reconcile existing installations even while the user is signed out or
    /// the Hub is unreachable.
    private func reconcileInstalledAgentAdapters() async throws
        -> LocalAgentAdapterReconciliationResult {
        let runtimePath = try Self.bundledAgentRuntimePath()
        // Daemon-owned integrations are the safety-critical cutover and must
        // never wait on advisory inspection of the archived external store.
        let installed = try await daemon.allProjectAgentAdapters()
        let requests = Self.agentAdapterReconciliationPlan(
            installed: installed,
            runtimePath: runtimePath,
            workspaceExists: { FileManager.default.fileExists(atPath: $0) }
        )
        for request in requests {
            _ = try await daemon.installProjectAgentAdapter(request)
        }
        do {
            let legacyInspection = try await daemon.inspectLegacyAgentAdapters(
                runtimeBinaryPath: runtimePath
            )
            return .init(conflicts: legacyInspection.conflicts, inspectionWarning: nil)
        } catch {
            return .init(
                conflicts: [],
                inspectionWarning: "Clumsies updated its managed integrations, but could not inspect the archived Zig CLI integration store. Review any old global or repository MCP and hook entries manually. \(error.localizedDescription)"
            )
        }
    }

    static func loadAuthenticatedWorkspaceIdentity(
        reconcileLocalAgentAdapters: () async throws
            -> LocalAgentAdapterReconciliationResult,
        projectConfig: () async throws -> DaemonProjectConfig,
        retrySync: () async -> Void,
        currentUser: () async throws -> CurrentUserResponse,
        onLocalAgentAdapters: @MainActor @Sendable (LocalAgentAdapterReconciliationResult) async
            -> Void = { _ in }
    ) async throws -> (
        DaemonProjectConfig,
        CurrentUserResponse,
        LocalAgentAdapterReconciliationResult
    ) {
        let localAgentAdapters = try await reconcileLocalAgentAdapters()
        await onLocalAgentAdapters(localAgentAdapters)
        let config = try await projectConfig()
        guard config.hasAccessToken && config.hasRefreshToken else {
            throw WorkspaceLoadError.authenticationRequired
        }
        await retrySync()
        return (config, try await currentUser(), localAgentAdapters)
    }

    static func agentAdapterReconciliationPlan(
        installed: [DaemonProjectAgentAdapter],
        runtimePath: String,
        workspaceExists: (String) -> Bool
    ) -> [DaemonProjectAgentAdapterInstallRequest] {
        installed
            .filter { workspaceExists($0.workspaceRoot) }
            .sorted {
                if $0.workspaceRoot != $1.workspaceRoot {
                    return $0.workspaceRoot < $1.workspaceRoot
                }
                return $0.adapter.rawValue < $1.adapter.rawValue
            }
            .map {
                .init(
                    projectId: $0.projectId,
                    workspaceRoot: $0.workspaceRoot,
                    adapter: $0.adapter,
                    runtimeBinaryPath: runtimePath,
                    expectedRevision: $0.revision
                )
            }
    }

    static func bundledAgentRuntimePath(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> String {
        try AppBundleRuntimeLocation.requireStable(bundle.bundleURL)
        guard let path = bundle.resourceURL?.appending(path: "clumsiesd").path,
              fileManager.isExecutableFile(atPath: path) else {
            throw ProjectSetupError.bundledAgentRuntimeMissing
        }
        return path
    }

    private func configuredProject(_ config: DaemonProjectConfig, me: CurrentUserResponse) -> String? {
        if let projectId = config.projectId, me.projects.contains(where: { $0.projectId == projectId }) {
            return projectId
        }
        return me.defaultProjectId ?? me.projects.first?.projectId
    }

    private func etag(from response: DaemonServerResponse) -> String {
        response.headers.first { $0.key.caseInsensitiveCompare("etag") == .orderedSame }?.value ?? ""
    }

    private func loadProjectStates(
        _ projects: [ProjectReference],
        activeProjectId: String
    ) async throws -> [ProjectState] {
        guard let active = projects.first(where: { $0.projectId == activeProjectId }) else {
            throw WorkspaceLoadError.noProjects
        }
        let loaded = try await loadProjectState(active)
        return projects.map { project in
            if project.projectId == loaded.id { return loaded }
            return .init(
                id: project.projectId,
                name: project.name,
                refCommitId: nil,
                refEtag: "",
                selectedOrgResourceIds: [],
                orgSelectionRevision: 0,
                isLoaded: false
            )
        }
    }

    private func loadProjectState(_ project: ProjectReference) async throws -> ProjectState {
        async let commitRequest: (value: CommitStateResponse, response: DaemonServerResponse) = server.getWithMetadata(
            "/api/v1/projects/\(project.projectId)/commit-state"
        )
        async let selectionRequest: ProjectOrgSelection = server.get(
            "/api/v1/projects/\(project.projectId)/org-selections"
        )
        let (commit, selection) = try await (commitRequest, selectionRequest)
        return .init(
            id: project.projectId,
            name: project.name,
            refCommitId: commit.value.ref.commitId,
            refEtag: etag(from: commit.response),
            selectedOrgResourceIds: Set(selection.memories.map(\.memoryId)),
            orgSelectionRevision: selection.revision,
            isLoaded: true
        )
    }

    private func loadResources(
        projectId: String?,
        projectName: String?,
        refCommitId: String?
    ) async throws -> [MemoryResource] {
        let prefix = projectId.map { "/api/v1/projects/\($0)" } ?? "/api/v1/org"
        let metadataItems: [MemoryMetadata] = try await loadAll("\(prefix)/memories")
        return metadataItems.map { metadata in
            .init(
                id: metadata.memoryId,
                scope: projectId == nil ? .org : .project,
                projectId: projectId,
                projectName: projectName,
                kind: .init(.memory),
                contentHash: metadata.contentHash,
                updatedAt: metadata.updatedAt,
                refCommitId: refCommitId,
                contentLoaded: false,
                document: .init(
                    title: metadata.name,
                    path: metadata.path,
                    body: ""
                )
            )
        }
    }

    private func loadBundles() async throws -> [PersonalBundle] {
        let items: [PersonalBundleMetadata] = try await loadAll("/api/v1/me/bundles")
        return try await concurrentMap(items) { metadata in
            let detail: PersonalBundleDetail = try await server.get("/api/v1/me/bundles/\(metadata.bundleId)")
            return .init(
                id: metadata.bundleId,
                name: metadata.name,
                description: metadata.description,
                resourceIds: detail.memories.map(\.memoryId),
                revision: metadata.revision,
                updatedAt: metadata.updatedAt
            )
        }
    }

    private func loadReviews() async throws -> [ReviewRecord] {
        let items: [ReviewMetadata] = try await loadAll("/api/v1/reviews")
        return items.map(Self.mapReview)
    }

    private func loadAll<Item: Decodable & Sendable>(_ path: String) async throws -> [Item] {
        var output: [Item] = []
        var cursor: String?
        repeat {
            var query = [URLQueryItem(name: "limit", value: "200")]
            if let cursor { query.append(.init(name: "cursor", value: cursor)) }
            let page: ListResponse<Item> = try await server.get(path, query: query)
            output += page.items
            cursor = page.pageInfo.hasMore ? page.pageInfo.nextCursor : nil
        } while cursor != nil
        return output
    }

    static func mapReview(_ detail: ReviewDetail) -> ReviewRecord {
        mapReview(detail.review)
    }

    static func mapReview(_ metadata: ReviewMetadata) -> ReviewRecord {
        return .init(
            id: metadata.reviewId,
            projectId: metadata.projectId,
            draftId: metadata.draftId,
            title: metadata.title,
            description: metadata.description,
            author: metadata.author,
            status: metadata.status,
            version: metadata.version,
            decisionBody: metadata.decisionBody,
            approvedResultHash: metadata.approvedResultHash,
            decidedBy: metadata.decidedBy,
            decidedAt: metadata.decidedAt,
            freshness: metadata.coordination.freshness,
            reconciliation: metadata.coordination.reconciliation,
            reconciliationCandidateId: metadata.coordination.candidateId,
            currentCommitId: metadata.coordination.currentCommitId,
            updatedAt: metadata.updatedAt
        )
    }

    static func mapReviewChangeSources(
        detail: ReviewDetail,
        base: CommitPayload?,
        current: CommitPayload?
    ) throws -> ReviewChangeSources {
        let terminalOperation = detail.operations.last
        let draftContent: String?
        let resolutionContent: String?
        if terminalOperation?.action == "delete" {
            draftContent = nil
            resolutionContent = nil
        } else {
            let content = detail.operations.reversed().first {
                ($0.action == "create" || $0.action == "update") && $0.content != nil
            }?.content
            draftContent = content?.renderedText
            resolutionContent = content?.primaryText
        }
        let initialPath = detail.operations.first?.resource.path ?? detail.draft.resource.path
        let finalPath = detail.operations.reduce(initialPath) { path, operation in
            if let newPath = operation.newPath { return newPath }
            if operation.action == "create", let createdPath = operation.resource.path { return createdPath }
            return path
        }
        let operationLabels: [String]
        if terminalOperation?.action == "delete" {
            operationLabels = ["Delete \(finalPath ?? "the selected memory")"]
        } else if detail.operations.first?.action == "create" {
            operationLabels = ["Create \(finalPath ?? "memory")"]
        } else if finalPath != initialPath, let finalPath {
            operationLabels = ["Rename to \(finalPath)"]
        } else {
            operationLabels = []
        }
        return try .init(
            baseContent: commitResourceText(base, resource: detail.draft.resource),
            currentContent: commitResourceText(current, resource: detail.draft.resource),
            draftContent: draftContent,
            resolutionContent: resolutionContent,
            proposedPath: finalPath,
            operationLabels: operationLabels
        )
    }

    private static func commitResourceText(
        _ payload: CommitPayload?,
        resource: ServerDraftResourceReference
    ) throws -> String? {
        guard let payload else { return nil }
        let entry = payload.tree.entries.first { candidate in
            guard candidate.type == .memory else { return false }
            if let resourceId = resource.id { return candidate.id == resourceId }
            return candidate.path == resource.path
        }
        guard let entry,
              let blob = payload.blobs.first(where: { $0.blobId == entry.blobId }) else { return nil }
        return blob.content
    }

    static func mapDraft(_ detail: DaemonDraftDetail, resources: [MemoryResource]) -> LocalDraft {
        let summary = detail.draft
        let base = summary.targetId.flatMap { id in resources.first { $0.id == id } }
        var document = base?.document ?? .init(
            title: title(from: summary.path ?? "Untitled"),
            path: summary.path ?? "untitled.md",
            body: ""
        )
        var deletion = false
        for operation in detail.operations {
            switch operation.operation {
            case .create(let path, let content, _):
                document.path = path
                document = apply(content: content, to: document)
                deletion = false
            case .update(_, let content, _):
                document = apply(content: content, to: document)
                deletion = false
            case .rename(_, let newPath, _):
                document.path = newPath
            case .delete:
                deletion = true
            case .discard:
                break
            }
        }
        return .init(
            id: summary.draftId,
            projectId: summary.projectId,
            serverId: summary.serverDraftId,
            serverVersion: summary.serverVersion,
            baseCommitId: summary.baseCommitId,
            currentCommitId: summary.currentCommitId,
            freshness: summary.freshness,
            hasUpstreamResourceChanges: summary.hasUpstreamResourceChanges,
            reconciliation: summary.reconciliation,
            reconciliationCandidateId: summary.reconciliationCandidateId,
            scope: summary.scope == .org ? .org : .project,
            kind: .init(summary.resourceKind),
            targetId: summary.targetId,
            status: summary.status,
            origin: detail.operations.last?.source ?? .desktop,
            syncStatus: detail.operations.last?.syncStatus ?? .synced,
            updatedAt: summary.updatedAt,
            document: document,
            isDeletion: deletion
        )
    }

    private static func apply(
        content: DaemonDraftContent,
        to document: EditableMemoryDocument
    ) -> EditableMemoryDocument {
        var document = document
        document.body = content.content
        return document
    }

    private static func title(from path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private func title(from path: String) -> String {
        Self.title(from: path)
    }
}

private struct ResourceLoadScope: Sendable {
    let projectId: String?
    let projectName: String?
    let refCommitId: String?
}

private struct IndexedValue<Value: Sendable>: Sendable {
    let index: Int
    let value: Value
}

private struct PendingDocumentSave {
    let item: MemoryListItem
    let document: EditableMemoryDocument
    let generation: UUID
}

private struct PendingBundleSave {
    let bundle: PersonalBundle
    let name: String
    let description: String
    let resourceIds: Set<String>
    let generation: UUID
}

private actor AsyncMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func unlock() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

private func concurrentMap<Input: Sendable, Output: Sendable>(
    _ values: [Input],
    maxConcurrent: Int = 12,
    transform: @escaping @Sendable (Input) async throws -> Output
) async throws -> [Output] {
    guard !values.isEmpty else { return [] }
    let limit = min(max(1, maxConcurrent), values.count)
    return try await withThrowingTaskGroup(of: IndexedValue<Output>.self) { group in
        var nextIndex = 0
        var output = [Output?](repeating: nil, count: values.count)

        func enqueue(_ index: Int) {
            let value = values[index]
            group.addTask {
                IndexedValue(index: index, value: try await transform(value))
            }
        }

        while nextIndex < limit {
            enqueue(nextIndex)
            nextIndex += 1
        }
        while let result = try await group.next() {
            output[result.index] = result.value
            if nextIndex < values.count {
                enqueue(nextIndex)
                nextIndex += 1
            }
        }
        return output.compactMap { $0 }
    }
}
