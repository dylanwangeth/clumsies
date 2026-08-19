import AppKit
import SwiftUI

struct MemoryNavigator: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        FileTreeView(store: store, items: store.visibleMemoryItems)
        .onChange(of: store.selectedKind) { _, _ in
            store.selectedItemId = nil
        }
    }
}

struct MemoryMainPane: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            if let project = store.activeProject, !project.isLoaded {
                ProjectPreparationView(store: store)
            } else if !store.visibleTabs.isEmpty {
                DocumentTabStrip(
                    tabs: store.visibleTabs,
                    selectedTabId: store.activeVisibleTab?.id,
                    onSelect: { tab in store.selectTab(tab) },
                    onClose: store.closeTab
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: DocumentTabMetrics.height,
                    maxHeight: DocumentTabMetrics.height,
                    alignment: .leading
                )
                .background(.bar)

                if let tab = store.activeVisibleTab,
                   let item = store.item(for: tab) {
                    if item.contentLoaded {
                        DocumentSessionView(store: store, item: item, mode: tab.mode)
                            .id(tab.id)
                    } else {
                        ResourceLoadingView()
                            .task { await store.loadContentIfNeeded(item) }
                    }
                } else {
                    emptyState
                }
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.visibleMemoryItems.isEmpty {
            EmptyMemoryCollectionView(store: store)
        } else {
            EmptyWorkspaceView()
        }
    }
}

private struct ResourceLoadingView: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyWorkspaceView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Open a memory from the navigator")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyMemoryCollectionView: View {
    @ObservedObject var store: WorkspaceStore

    private var scope: MemoryScope {
        store.activeProjectId == nil ? .org : .project
    }

    var body: some View {
        ContentUnavailableView {
            Label("No Memory", systemImage: "doc")
        } description: {
            Text("Create the first memory here.")
        } actions: {
            Button("New Memory") {
                Task {
                    await store.createMemory(kind: store.selectedKind, scope: scope)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(
                !store.canCreateMemory(kind: store.selectedKind, scope: scope)
            )
        }
    }
}

private struct ProjectPreparationView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ContentUnavailableView {
            Label("Preparing Project", systemImage: "folder")
        } description: {
            Text("Clumsies is preparing the local workspace.")
        } actions: {
            if store.loadingProjectId == store.activeProjectId {
                ProgressView()
                    .controlSize(.small)
            } else if let projectId = store.activeProjectId {
                Button("Try Again") {
                    Task { await store.selectProject(projectId) }
                }
            }
        }
    }
}

private struct FileTreeView: View {
    @ObservedObject var store: WorkspaceStore
    let items: [MemoryListItem]
    @State private var expandedDirectoryIds: Set<String> = []
    @State private var selectedNodeIds: Set<String> = []
    @State private var selectionAnchorId: String?
    @State private var initializedExpansion = false
    @State private var itemToRename: MemoryListItem?
    @State private var proposedName = ""

    private var roots: [FileTreeNode] {
        FileTreeNode.build(items)
    }

    private var visibleNodes: [VisibleFileTreeNode] {
        FileTreeNode.visibleNodes(roots, expandedDirectoryIds: expandedDirectoryIds)
    }

    var body: some View {
        List(selection: selection) {
            ForEach(visibleNodes) { entry in
                FileTreeRow(
                    entry: entry,
                    isExpanded: expandedDirectoryIds.contains(entry.id),
                    isStale: entry.node.item.map {
                        $0.draft == nil
                            && $0.resource.map { store.staleResourceIds.contains($0.id) } == true
                    } == true,
                    onDirectoryClick: { modifierFlags in
                        handleDirectoryClick(entry.id, modifierFlags: modifierFlags)
                    }
                )
                .tag(entry.id)
                .listRowInsets(.init(top: 0, leading: 5, bottom: 0, trailing: 5))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
        .contextMenu(forSelectionType: String.self) { nodeIds in
            fileTreeMenu(for: nodeIds)
        }
        .onAppear {
            guard !initializedExpansion else { return }
            expandedDirectoryIds = FileTreeNode.directoryIds(in: roots)
            initializedExpansion = true
            synchronizeSelectionWithActiveItem()
        }
        .onChange(of: items.map { "\($0.id):\($0.document.path)" }) { _, _ in
            expandedDirectoryIds.formUnion(FileTreeNode.directoryIds(in: roots))
            selectedNodeIds.formIntersection(Set(FileTreeNode.allIds(in: roots)))
            if let selectionAnchorId,
               FileTreeNode.node(withId: selectionAnchorId, in: roots) == nil {
                self.selectionAnchorId = nil
            }
            synchronizeSelectionWithActiveItem()
        }
        .onChange(of: store.activeVisibleTab?.itemId ?? store.selectedItemId) { _, _ in
            synchronizeSelectionWithActiveItem()
        }
        .alert(
            "Rename Memory",
            isPresented: Binding(
                get: { itemToRename != nil },
                set: {
                    if !$0 {
                        itemToRename = nil
                        proposedName = ""
                    }
                }
            )
        ) {
            TextField("File name", text: $proposedName)
            Button("Cancel", role: .cancel) {
                itemToRename = nil
            }
            Button("Rename") {
                renameSelectedItem()
            }
            .disabled(!isValidProposedName)
        }
    }

    private var isValidProposedName: Bool {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private func beginRenaming(_ item: MemoryListItem) {
        proposedName = item.document.path.split(separator: "/").last.map(String.init)
            ?? item.document.path
        itemToRename = item
    }

    private func renameSelectedItem() {
        guard let item = itemToRename else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidProposedName else { return }
        var document = item.document
        let parent = document.path
            .split(separator: "/")
            .dropLast()
            .joined(separator: "/")
        document.path = parent.isEmpty ? name : "\(parent)/\(name)"
        itemToRename = nil
        proposedName = ""
        Task {
            do {
                try await store.save(item, document: document)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private var selection: Binding<Set<String>> {
        Binding(
            get: { selectedNodeIds },
            set: { newSelection in
                let previous = selectedNodeIds
                selectedNodeIds = newSelection
                guard newSelection.count == 1,
                      let nodeId = newSelection.first,
                      let node = FileTreeNode.node(withId: nodeId, in: roots) else {
                    return
                }

                if newSelection != previous {
                    selectionAnchorId = nodeId
                }
                guard newSelection != previous, let item = node.item else { return }
                store.open(item)
            }
        )
    }

    private func handleDirectoryClick(
        _ nodeId: String,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        let result = FileTreeSelectionInteraction.directoryClick(
            nodeId: nodeId,
            visibleNodeIds: visibleNodes.map(\.id),
            currentSelection: selectedNodeIds,
            anchorId: selectionAnchorId,
            modifierFlags: modifierFlags
        )
        selectedNodeIds = result.selection
        selectionAnchorId = result.anchorId
        if result.togglesDirectory {
            toggleDirectory(nodeId)
        }
    }

    private func toggleDirectory(_ nodeId: String) {
        withAnimation(.snappy(duration: 0.14)) {
            if expandedDirectoryIds.contains(nodeId) {
                expandedDirectoryIds.remove(nodeId)
            } else {
                expandedDirectoryIds.insert(nodeId)
            }
        }
    }

    @ViewBuilder
    private func fileTreeMenu(for nodeIds: Set<String>) -> some View {
        let targetItems = FileTreeNode.items(in: roots, selectedNodeIds: nodeIds)
        let singleItem = targetItems.count == 1 ? targetItems.first : nil
        let isOrgView = store.activeProjectId == nil
        let addableItems = MemoryFileTreeMenu.addable(targetItems, inOrgView: isOrgView)
        let removableItems = MemoryFileTreeMenu.removable(targetItems, inOrgView: isOrgView)
        let trashableItems = MemoryFileTreeMenu.trashable(targetItems, inOrgView: isOrgView)
        let singleManageable = singleItem.map {
            MemoryFileTreeMenu.isManageable($0, inOrgView: isOrgView)
        } ?? false
        let singleStale = singleItem.map { item in
            item.resource.map { store.staleResourceIds.contains($0.id) } == true
        } ?? false
        let hasDomainSection = !addableItems.isEmpty || !removableItems.isEmpty
            || (singleItem?.draft != nil) || singleStale

        // ---- generic document operations (standard macOS conventions) ----
        if let singleItem {
            Button("Open") { store.open(singleItem) }
            if singleItem.supportsMarkdownPreview {
                Button("Open Source") { store.open(singleItem, mode: .source) }
            }
            if singleManageable {
                Button("Rename…") { beginRenaming(singleItem) }
                if singleItem.resource != nil {
                    Button("Move to Trash", role: .destructive) {
                        Task { await store.delete(singleItem) }
                    }
                }
            }
        } else if !targetItems.isEmpty {
            Button("Open") { targetItems.forEach { store.open($0) } }
            if !trashableItems.isEmpty {
                Button(moveToTrashTitle(count: trashableItems.count), role: .destructive) {
                    deleteItems(trashableItems)
                }
            }
        }

        // ---- domain operations (Memory scope relationships and drafts) ----
        if hasDomainSection {
            Divider()
        }
        if !addableItems.isEmpty {
            Menu(addToProjectTitle(count: addableItems.count)) {
                if store.projects.isEmpty {
                    Button("No Projects") {}
                        .disabled(true)
                } else {
                    ForEach(store.projects) { project in
                        Button("Add to \(project.name)") {
                            addToProject(addableItems, projectId: project.id)
                        }
                    }
                }
            }
            .disabled(!store.canManageOrgSelection || store.projects.isEmpty)
        }
        if !removableItems.isEmpty {
            Button(removeFromProjectTitle(count: removableItems.count)) {
                removeFromProject(removableItems)
            }
            .disabled(!store.canManageOrgSelection)
        }
        if let singleItem {
            if singleItem.draft?.freshness == .behind {
                Button(singleItem.draft?.hasUpstreamResourceChanges == true ? "Review Changes" : "Sync") {
                    store.syncDocument(singleItem)
                }
            } else if let resource = singleItem.resource,
                      store.staleResourceIds.contains(resource.id) {
                Button("Sync") {
                    store.syncDocument(singleItem)
                }
            }
            if let draft = singleItem.draft {
                Button("Discard Draft") {
                    Task { await store.discard(draft) }
                }
            }
        }

        if targetItems.isEmpty {
            Button("New Memory") {
                Task {
                    await store.createMemory(
                        kind: store.selectedKind,
                        scope: store.activeProjectId == nil ? .org : .project
                    )
                }
            }
            .disabled(
                !store.canCreateMemory(
                    kind: store.selectedKind,
                    scope: store.activeProjectId == nil ? .org : .project
                )
            )
        }
    }

    private func synchronizeSelectionWithActiveItem() {
        guard selectedNodeIds.count <= 1,
              let itemId = store.activeVisibleTab?.itemId ?? store.selectedItemId,
              FileTreeNode.node(withId: itemId, in: roots) != nil else {
            return
        }
        selectedNodeIds = [itemId]
        selectionAnchorId = itemId
    }

    private func moveToTrashTitle(count: Int) -> String {
        count == 1 ? "Move to Trash" : "Move \(count) Items to Trash"
    }

    private func deleteItems(_ items: [MemoryListItem]) {
        Task {
            for item in items {
                await store.delete(item)
            }
        }
    }

    private func addToProject(_ items: [MemoryListItem], projectId: String) {
        Task {
            do {
                try await store.addOrgMemories(
                    resourceIds: Set(items.map(\.id)),
                    toProject: projectId
                )
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func removeFromProject(_ items: [MemoryListItem]) {
        Task {
            do {
                try await store.removeOrgMemoriesFromActiveProject(
                    resourceIds: Set(items.map(\.id))
                )
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func addToProjectTitle(count: Int) -> String {
        count == 1 ? "Add to Project" : "Add \(count) Items to Project"
    }

    private func removeFromProjectTitle(count: Int) -> String {
        count == 1 ? "Remove from Project" : "Remove \(count) Items from Project"
    }
}

/// Git-style title color for a memory file-tree row.
enum MemoryFileTreeTitleTone: Equatable {
    case primary
    case secondary
    case newDraft
    case modifiedDraft
    case deletedDraft

    static func resolve(item: MemoryListItem?) -> Self {
        guard let item else { return .primary }
        guard let draft = item.draft else {
            return item.inherited ? .secondary : .primary
        }
        if draft.isDeletion { return .deletedDraft }
        if draft.targetId == nil { return .newDraft }
        return .modifiedDraft
    }

    var color: Color {
        switch self {
        case .primary: return .primary
        case .secondary: return .secondary
        case .newDraft: return .green
        case .modifiedDraft: return Color(red: 0.8, green: 0.6, blue: 0.1) // amber, legible in light mode
        case .deletedDraft: return .red
        }
    }
}

private struct FileTreeRow: View {
    let entry: VisibleFileTreeNode
    let isExpanded: Bool
    let isStale: Bool
    let onDirectoryClick: (NSEvent.ModifierFlags) -> Void

    private var item: MemoryListItem? { entry.node.item }

    @ViewBuilder
    var body: some View {
        if item == nil {
            rowContent
                .simultaneousGesture(
                    TapGesture().onEnded {
                        onDirectoryClick(NSEvent.modifierFlags)
                    }
                )
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        PathTreeRowLabel(
            name: entry.node.name,
            path: item?.document.path,
            depth: entry.depth,
            isDirectory: item == nil,
            isExpanded: isExpanded,
            titleColor: titleColor
        ) {
            if item?.inherited == true {
                Image(systemName: "building.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Inherited from Organization")
                    .accessibilityLabel("Inherited from Organization")
            }
            SharedUpdateIndicator(
                freshness: item?.draft?.freshness,
                hasUpstreamResourceChanges: item?.draft?.hasUpstreamResourceChanges == true,
                reconciliation: item?.draft?.reconciliation,
                isStale: isStale
            )
        }
        .help(item?.inherited == true ? "Inherited from Organization" : entry.node.name)
    }

    private var titleColor: Color {
        MemoryFileTreeTitleTone.resolve(item: item).color
    }

}

struct FileTreeDirectoryClickResult {
    let selection: Set<String>
    let anchorId: String?
    let togglesDirectory: Bool
}

enum FileTreeSelectionInteraction {
    static func directoryClick(
        nodeId: String,
        visibleNodeIds: [String],
        currentSelection: Set<String>,
        anchorId: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> FileTreeDirectoryClickResult {
        if modifierFlags.contains(.shift) {
            let effectiveAnchor = anchorId ?? nodeId
            guard let anchorIndex = visibleNodeIds.firstIndex(of: effectiveAnchor),
                  let nodeIndex = visibleNodeIds.firstIndex(of: nodeId) else {
                return .init(
                    selection: [nodeId],
                    anchorId: nodeId,
                    togglesDirectory: false
                )
            }
            let range = min(anchorIndex, nodeIndex) ... max(anchorIndex, nodeIndex)
            let rangeSelection = Set(range.map { visibleNodeIds[$0] })
            return .init(
                selection: modifierFlags.contains(.command)
                    ? currentSelection.union(rangeSelection)
                    : rangeSelection,
                anchorId: effectiveAnchor,
                togglesDirectory: false
            )
        }

        if modifierFlags.contains(.command) {
            var selection = currentSelection
            if selection.contains(nodeId) {
                selection.remove(nodeId)
            } else {
                selection.insert(nodeId)
            }
            return .init(
                selection: selection,
                anchorId: nodeId,
                togglesDirectory: false
            )
        }

        guard modifierFlags.intersection([.option, .control]).isEmpty else {
            return .init(
                selection: currentSelection,
                anchorId: anchorId,
                togglesDirectory: false
            )
        }

        return .init(
            selection: [nodeId],
            anchorId: nodeId,
            togglesDirectory: true
        )
    }
}

struct VisibleFileTreeNode: Identifiable {
    let node: FileTreeNode
    let depth: Int

    var id: String { node.id }
}

struct FileTreeNode: Identifiable {
    let id: String
    let name: String
    let item: MemoryListItem?
    let children: [FileTreeNode]?

    static func build(_ items: [MemoryListItem]) -> [FileTreeNode] {
        var itemsById: [String: MemoryListItem] = [:]
        let pathItems = items.map { item in
            itemsById[item.id] = item
            var components = item.document.path.split(separator: "/").map(String.init)
            if item.kind == .workflows, components.first == "workflow", components.count > 1 {
                components.removeFirst()
            }
            return PathTreeItem(
                id: item.id,
                path: components.joined(separator: "/"),
                fallbackName: item.document.title
            )
        }

        func convert(_ node: PathTreeNode) -> FileTreeNode {
            FileTreeNode(
                id: node.id,
                name: node.name,
                item: node.item.flatMap { itemsById[$0.id] },
                children: node.children.map { $0.map(convert) }
            )
        }

        return PathTreeNode.build(pathItems).map(convert)
    }

    static func directoryIds(in nodes: [FileTreeNode]) -> Set<String> {
        nodes.reduce(into: Set<String>()) { result, node in
            guard let children = node.children else { return }
            result.insert(node.id)
            result.formUnion(directoryIds(in: children))
        }
    }

    static func allIds(in nodes: [FileTreeNode]) -> [String] {
        nodes.flatMap { node in
            [node.id] + (node.children.map { allIds(in: $0) } ?? [])
        }
    }

    static func node(withId id: String, in nodes: [FileTreeNode]) -> FileTreeNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children,
               let match = self.node(withId: id, in: children) {
                return match
            }
        }
        return nil
    }

    static func items(
        in nodes: [FileTreeNode],
        selectedNodeIds: Set<String>
    ) -> [MemoryListItem] {
        var selectedItems: [String: MemoryListItem] = [:]

        func collect(_ node: FileTreeNode) {
            if let item = node.item {
                selectedItems[item.id] = item
            }
            node.children?.forEach(collect)
        }

        func visit(_ node: FileTreeNode) {
            if selectedNodeIds.contains(node.id) {
                collect(node)
            } else {
                node.children?.forEach(visit)
            }
        }

        nodes.forEach(visit)
        return selectedItems.values.sorted {
            $0.document.path.localizedStandardCompare($1.document.path) == .orderedAscending
        }
    }

    static func visibleNodes(
        _ nodes: [FileTreeNode],
        expandedDirectoryIds: Set<String>,
        depth: Int = 0
    ) -> [VisibleFileTreeNode] {
        nodes.flatMap { node in
            var result = [VisibleFileTreeNode(node: node, depth: depth)]
            if expandedDirectoryIds.contains(node.id), let children = node.children {
                result.append(contentsOf: visibleNodes(
                    children,
                    expandedDirectoryIds: expandedDirectoryIds,
                    depth: depth + 1
                ))
            }
            return result
        }
    }
}

private struct DocumentSessionView: View {
    @ObservedObject var store: WorkspaceStore
    let item: MemoryListItem
    let mode: WorkbenchTabMode

    @State private var document: EditableMemoryDocument
    @State private var suppressesSaving = false
    @State private var reviewDraft: LocalDraft?
    @State private var reconciliationCandidate: DraftReconciliationCandidate?
    @State private var loadsReconciliation = false
    @State private var reconciliationUpdateRequest = 0
    @State private var documentDiffPresentation: UnifiedDiffPresentation?
    @State private var loadsDocumentDiff = false

    init(store: WorkspaceStore, item: MemoryListItem, mode: WorkbenchTabMode) {
        self.store = store
        self.item = item
        self.mode = mode
        _document = State(initialValue: item.document)
    }

    var body: some View {
        Group {
            if let candidate = reconciliationCandidate {
                DraftReconciliationView(
                    candidate: candidate,
                    updateRequest: reconciliationUpdateRequest,
                    usesContextualUpdateAction: true,
                    onUpdateStateChange: publishReconciliationToolbarState,
                    onCancel: closeReconciliation,
                    onApplied: closeReconciliation
                ) { resolvedState in
                    guard let draft = activeDraft, let serverId = draft.serverId else {
                        throw ReviewRequestError.draftNotSynchronized
                    }
                    try await store.applyReconciliation(
                        draftId: serverId,
                        draftVersion: draft.serverVersion,
                        candidate: candidate,
                        resolvedState: resolvedState
                    )
                }
            } else {
                documentContent
            }
        }
        .onChange(of: document) { _, _ in scheduleSave() }
        .onChange(of: store.pendingDocumentCommand) { _, command in
            handleDocumentCommand(command)
        }
        .onAppear { handleDocumentCommand(store.pendingDocumentCommand) }
        .onDisappear {
            flushSave()
            clearReconciliationToolbarState()
        }
        .sheet(item: $reviewDraft) { draft in
            ReviewRequestSheet(
                initialTitle: document.title,
                loadCandidate: { try await loadReviewCandidate(draft) }
            ) { title, description, candidate, resolvedState in
                try await submitReview(
                    draft,
                    title: title,
                    description: description,
                    candidate: candidate,
                    resolvedState: resolvedState
                )
            }
        }
    }

    private var documentContent: some View {
        Group {
            if item.draft?.isDeletion == true {
                ContentUnavailableView(
                    "Pending deletion",
                    systemImage: "trash",
                    description: Text("Discard the draft to keep this memory.")
                )
            } else if mode == .preview {
                MarkdownPreview(source: renderedSource)
            } else if mode == .diff {
                documentDiff
            } else {
                editor
                    .disabled(item.inherited)
            }
        }
    }

    @ViewBuilder
    private var documentDiff: some View {
        Group {
            if let presentation = documentDiffPresentation {
                UnifiedDiffView(presentation: presentation)
            } else if loadsDocumentDiff {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "doc.text",
                    description: Text("No local or remote changes to show for this document.")
                )
            }
        }
        .onAppear { loadDocumentDiff() }
        .onChange(of: documentDiffIdentity) { _, _ in loadDocumentDiff() }
    }

    private var documentDiffIdentity: String {
        [
            item.draft?.id ?? "no-draft",
            item.draft?.freshness.rawValue ?? "-",
            item.resource?.contentHash ?? "-",
            String(store.staleResourceIds.contains(item.resource?.id ?? "")),
        ].joined(separator: ":")
    }

    private func loadDocumentDiff() {
        guard mode == .diff, !loadsDocumentDiff else { return }
        documentDiffPresentation = nil
        loadsDocumentDiff = true
        Task {
            defer { loadsDocumentDiff = false }
            documentDiffPresentation = await store.documentDiffPresentation(
                for: item,
                localText: document.body
            )
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch item.kind {
        case .context, .rules, .workflows:
            NativeTextEditor(text: $document.body)
        }
    }

    private var renderedSource: String {
        let sourceDocument = mode == .preview ? item.document : document
        switch item.kind {
        case .context, .rules, .workflows:
            return sourceDocument.body
        }
    }

    private var activeDraft: LocalDraft? {
        guard let draft = item.draft else { return nil }
        return store.drafts.first(where: { $0.id == draft.id }) ?? draft
    }

    private func loadReconciliation(for draft: LocalDraft) {
        guard !loadsReconciliation else { return }
        loadsReconciliation = true
        store.documentReconciliationToolbarState = .init(
            itemId: item.id,
            isLoading: true,
            canUpdate: false,
            isUpdating: false
        )
        Task {
            defer { loadsReconciliation = false }
            do {
                try await store.flushDocumentSave(item.id)
                let latest = store.drafts.first {
                    $0.id == draft.id || (draft.targetId != nil && $0.targetId == draft.targetId)
                } ?? draft
                reconciliationCandidate = try await store.reconciliationCandidate(for: latest)
            } catch {
                clearReconciliationToolbarState()
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func handleDocumentCommand(_ command: DocumentSessionCommand?) {
        guard let command, command.itemId == item.id else { return }
        store.pendingDocumentCommand = nil
        switch command {
        case .requestReview(_, let draft):
            reviewDraft = draft
        case .discardDraft(_, let draft):
            discard(draft)
        case .reviewSharedChanges(_, let draft):
            loadReconciliation(for: draft)
        case .applyReconciliation:
            reconciliationUpdateRequest += 1
        case .closeReconciliation:
            closeReconciliation()
        case .moveToTrash:
            moveToTrash()
        }
    }

    private func publishReconciliationToolbarState(canUpdate: Bool, isUpdating: Bool) {
        store.documentReconciliationToolbarState = .init(
            itemId: item.id,
            isLoading: false,
            canUpdate: canUpdate,
            isUpdating: isUpdating
        )
    }

    private func closeReconciliation() {
        reconciliationCandidate = nil
        clearReconciliationToolbarState()
    }

    private func clearReconciliationToolbarState() {
        guard store.documentReconciliationToolbarState?.itemId == item.id else { return }
        store.documentReconciliationToolbarState = nil
    }

    private func scheduleSave() {
        guard !suppressesSaving, !item.inherited, mode == .source else { return }
        store.stageDocumentSave(item, document: document)
    }

    private func flushSave() {
        guard !suppressesSaving,
              !item.inherited,
              mode == .source,
              document != item.document else { return }
        Task {
            do {
                try await store.flushDocumentSave(item.id)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func submitReview(
        _ draft: LocalDraft,
        title: String,
        description: String,
        candidate: DraftReconciliationCandidate?,
        resolvedState: ReconciliationResourceState?
    ) async throws {
        try await store.flushDocumentSave(item.id)
        let latest = store.drafts.first {
            $0.id == draft.id || (draft.targetId != nil && $0.targetId == draft.targetId)
        } ?? draft
        try await store.requestReview(
            for: latest,
            title: title,
            description: description,
            candidate: candidate,
            resolvedState: resolvedState
        )
    }

    private func loadReviewCandidate(_ draft: LocalDraft) async throws -> DraftReconciliationCandidate {
        try await store.flushDocumentSave(item.id)
        let latest = store.drafts.first {
            $0.id == draft.id || (draft.targetId != nil && $0.targetId == draft.targetId)
        } ?? draft
        return try await store.reconciliationCandidate(for: latest)
    }

    private func discard(_ draft: LocalDraft) {
        suppressesSaving = true
        store.cancelDocumentSave(item.id)
        Task { await store.discard(draft) }
    }

    private func moveToTrash() {
        suppressesSaving = true
        store.cancelDocumentSave(item.id)
        Task { await store.delete(item) }
    }
}

struct DraftReconciliationView: View {
    let candidate: DraftReconciliationCandidate
    let updateRequest: Int
    let usesContextualUpdateAction: Bool
    let onUpdateStateChange: ((Bool, Bool) -> Void)?
    let onCancel: () -> Void
    let onApplied: () -> Void
    let onApply: (ReconciliationResourceState?) async throws -> Void

    @State private var resolvedExists: Bool
    @State private var resolvedPath: String
    @State private var resolvedContent: String
    @State private var isApplying = false
    @State private var errorMessage: String?

    init(
        candidate: DraftReconciliationCandidate,
        updateRequest: Int = 0,
        usesContextualUpdateAction: Bool = false,
        onUpdateStateChange: ((Bool, Bool) -> Void)? = nil,
        onCancel: @escaping () -> Void,
        onApplied: (() -> Void)? = nil,
        onApply: @escaping (ReconciliationResourceState?) async throws -> Void
    ) {
        self.candidate = candidate
        self.updateRequest = updateRequest
        self.usesContextualUpdateAction = usesContextualUpdateAction
        self.onUpdateStateChange = onUpdateStateChange
        self.onCancel = onCancel
        self.onApplied = onApplied ?? onCancel
        self.onApply = onApply
        let initial = candidate.proposedState ?? candidate.draftState
        _resolvedExists = State(initialValue: initial.exists)
        _resolvedPath = State(initialValue: initial.resource.path ?? "")
        _resolvedContent = State(initialValue: initial.content?.primaryText ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            if !candidate.valid {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    Text("A newer shared version is available. Review the latest update again.")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .frame(height: 34)
                Divider()
            }

            if candidate.status == .conflicts {
                conflictResolution
            } else {
                cleanDiff
            }

            if !usesContextualUpdateAction {
                Divider()
                HStack {
                    Button("Cancel") { onCancel() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button {
                        apply()
                    } label: {
                        if isApplying {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Update")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { publishUpdateState() }
        .onChange(of: canApply) { _, _ in publishUpdateState() }
        .onChange(of: isApplying) { _, _ in publishUpdateState() }
        .onChange(of: updateRequest) { _, _ in
            guard usesContextualUpdateAction else { return }
            apply()
        }
        .alert(
            "Could Not Update Draft",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
                .textSelection(.enabled)
        }
    }

    private var canApply: Bool {
        !isApplying
            && candidate.valid
            && !(candidate.status == .conflicts && resolvedExists && resolvedPath.isEmpty)
    }

    private func publishUpdateState() {
        guard usesContextualUpdateAction else { return }
        onUpdateStateChange?(canApply, isApplying)
    }

    @ViewBuilder
    private var cleanDiff: some View {
        if candidate.hasDraftResultChanges {
            SplitDiffView(
                original: text(in: candidate.draftState),
                modified: text(in: resultState),
                originalTitle: "Current Draft",
                modifiedTitle: "Updated Draft",
                originalPath: path(in: candidate.draftState),
                modifiedPath: path(in: resultState)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Changes to This File",
                systemImage: "doc.text",
                description: Text(
                    "The shared project changed elsewhere. Updating keeps this draft unchanged and moves it to the latest shared version."
                )
            )
        }
    }

    private var conflictResolution: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(conflictSummary, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)

                Spacer(minLength: 12)

                if hasExistenceConflict {
                    Toggle("Keep File", isOn: $resolvedExists)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                if resolvedExists && hasPathConflict {
                    TextField("Path", text: $resolvedPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            Divider()

            VSplitView {
                SplitDiffView(
                    original: text(in: candidate.currentState),
                    modified: text(in: resolvedState),
                    originalTitle: "Shared Version",
                    modifiedTitle: "Resolution Preview",
                    originalPath: path(in: candidate.currentState),
                    modifiedPath: path(in: resolvedState)
                )
                .frame(minHeight: 220, maxHeight: .infinity)

                resolvedContentPane
                    .frame(minHeight: 180, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resolvedContentPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Resolve Draft")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            Divider()

            if resolvedExists {
                TextEditor(text: $resolvedContent)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
            } else {
                ContentUnavailableView(
                    "File Removed",
                    systemImage: "trash",
                    description: Text("The resolved result removes this file.")
                )
            }
        }
    }

    private var resultState: ReconciliationResourceState {
        candidate.status == .conflicts
            ? resolvedState
            : candidate.proposedState ?? candidate.draftState
    }

    private var conflictSummary: String {
        let fields = Array(Set(candidate.conflicts.map(\.field))).sorted()
        let noun = candidate.conflicts.count == 1 ? "conflict" : "conflicts"
        guard !fields.isEmpty else { return "\(candidate.conflicts.count) \(noun)" }
        return "\(candidate.conflicts.count) \(noun): \(fields.joined(separator: ", "))"
    }

    private var hasExistenceConflict: Bool {
        candidate.conflicts.contains { $0.field == "exists" }
    }

    private var hasPathConflict: Bool {
        candidate.conflicts.contains { $0.field == "path" || $0.field == "path_occupied" }
    }

    private func text(in state: ReconciliationResourceState) -> String {
        state.exists ? state.content?.primaryText ?? "" : ""
    }

    private func path(in state: ReconciliationResourceState) -> String? {
        state.exists ? state.resource.path : nil
    }

    private func apply() {
        guard canApply else { return }
        isApplying = true
        Task {
            defer { isApplying = false }
            do {
                let resolved = candidate.status == .conflicts ? resolvedState : nil
                try await onApply(resolved)
                onApplied()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var resolvedState: ReconciliationResourceState {
        let template = candidate.proposedState ?? candidate.draftState
        let resource = ServerDraftResourceReference(
            scope: template.resource.scope,
            id: template.resource.id,
            path: resolvedExists ? resolvedPath : template.resource.path
        )
        return .init(
            exists: resolvedExists,
            resource: resource,
            content: resolvedExists
                ? template.content?.replacingPrimaryText(with: resolvedContent)
                : nil
        )
    }
}

private struct ReviewRequestSheet: View {
    @Environment(\.dismiss) private var dismiss

    let loadCandidate: () async throws -> DraftReconciliationCandidate
    let onSubmit: (
        String,
        String,
        DraftReconciliationCandidate?,
        ReconciliationResourceState?
    ) async throws -> Void

    @State private var title: String
    @State private var description = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var reconciliationCandidate: DraftReconciliationCandidate?

    init(
        initialTitle: String,
        loadCandidate: @escaping () async throws -> DraftReconciliationCandidate,
        onSubmit: @escaping (
            String,
            String,
            DraftReconciliationCandidate?,
            ReconciliationResourceState?
        ) async throws -> Void
    ) {
        _title = State(initialValue: initialTitle)
        self.loadCandidate = loadCandidate
        self.onSubmit = onSubmit
    }

    var body: some View {
        Group {
            if let candidate = reconciliationCandidate {
                DraftReconciliationView(
                    candidate: candidate,
                    onCancel: { reconciliationCandidate = nil },
                    onApplied: { dismiss() }
                ) { resolvedState in
                    try await onSubmit(
                        normalizedTitle,
                        description.trimmingCharacters(in: .whitespacesAndNewlines),
                        candidate,
                        resolvedState
                    )
                }
                .frame(minWidth: 780, idealWidth: 980, minHeight: 560, idealHeight: 680)
            } else {
                requestForm
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .alert(
            "Could Not Request Review",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
                .textSelection(.enabled)
        }
    }

    private var requestForm: some View {
        VStack(spacing: 0) {
            Form {
                Section("Review") {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(4...8)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    submit()
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Request")
                    }
                }
                .disabled(isSubmitting || normalizedTitle.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 270)
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        let submittedTitle = normalizedTitle
        let submittedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedTitle.isEmpty else { return }
        isSubmitting = true
        Task {
            do {
                try await onSubmit(submittedTitle, submittedDescription, nil, nil)
                dismiss()
            } catch ReviewRequestError.reconciliationRequired {
                do {
                    reconciliationCandidate = try await loadCandidate()
                    isSubmitting = false
                } catch {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}

/// Pure classification of file-tree context menu operations (design v2).
///
/// Menu = generic document operations (standard macOS conventions) + domain
/// operations (Memory scope relationships and drafts). Add to Project exists
/// only in the Org view; Remove from Project exists only in the Project view
/// for inherited items; Rename/Trash apply only to items owned by the current
/// view context.
enum MemoryFileTreeMenu {
    /// Items that can be renamed or trashed in the current view context:
    /// org memories in the Org view, project-owned memories in the Project
    /// view. Inherited and org-unreferenced items are view-only.
    static func isManageable(_ item: MemoryListItem, inOrgView: Bool) -> Bool {
        !item.inherited && (inOrgView ? item.scope == .org : item.scope == .project)
    }

    /// Org memories that may be added to a project: only in the Org view.
    static func addable(_ items: [MemoryListItem], inOrgView: Bool) -> [MemoryListItem] {
        inOrgView ? items.filter { $0.scope == .org } : []
    }

    /// Items inherited by the active project that may be removed from it:
    /// only in the Project view.
    static func removable(_ items: [MemoryListItem], inOrgView: Bool) -> [MemoryListItem] {
        inOrgView ? [] : items.filter(\.inherited)
    }

    /// Items that support batch Move to Trash: manageable items that back a
    /// resource (pure drafts are discarded, not trashed).
    static func trashable(_ items: [MemoryListItem], inOrgView: Bool) -> [MemoryListItem] {
        items.filter { isManageable($0, inOrgView: inOrgView) && $0.resource != nil }
    }
}
