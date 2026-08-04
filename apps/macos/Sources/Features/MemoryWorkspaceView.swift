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
            if store.selectedSection == .local, store.activeProject?.isLoaded == false {
                ProjectPreparationView(store: store)
            } else if !store.visibleTabs.isEmpty {
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

    var body: some View {
        ContentUnavailableView {
            Label("No \(store.selectedKind.title)", systemImage: "doc")
        } description: {
            Text("Create the first \(store.selectedKind.singularTitle.lowercased()) here.")
        } actions: {
            Button("New \(store.selectedKind.singularTitle)") {
                Task {
                    await store.createMemory(
                        kind: store.selectedKind,
                        scope: store.selectedSection == .hub ? .org : .project
                    )
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(
                !store.canCreateMemory(
                    kind: store.selectedKind,
                    scope: store.selectedSection == .hub ? .org : .project
                )
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
        let hubItems = targetItems.filter { $0.scope == .org }
        let removableItems = targetItems.filter(\.inherited)

        if let singleItem {
            Button("Open") { store.open(singleItem) }
            if singleItem.supportsMarkdownPreview {
                Button("Open Preview") { store.open(singleItem, mode: .preview) }
            }
            Divider()
        }

        if store.selectedSection == .hub, !hubItems.isEmpty {
            Menu(addToLocalTitle(count: hubItems.count)) {
                if store.projects.isEmpty {
                    Button("No Projects") {}
                        .disabled(true)
                } else {
                    ForEach(store.projects) { project in
                        Button(project.name) {
                            addToLocal(hubItems, projectId: project.id)
                        }
                    }
                }
            }
            .disabled(!store.canManageOrgSelection || store.projects.isEmpty)
        }

        if store.selectedSection == .local, !removableItems.isEmpty {
            Button(removeFromLocalTitle(count: removableItems.count)) {
                removeFromLocal(removableItems)
            }
            .disabled(!store.canManageOrgSelection)
        }

        if let singleItem {
            if store.selectedSection == .hub && !hubItems.isEmpty
                || store.selectedSection == .local && !removableItems.isEmpty {
                Divider()
            }
            if singleItem.inherited {
                Button("Open in Hub") {
                    Task { await store.reveal(singleItem) }
                }
            } else {
                Button("Rename…") { beginRenaming(singleItem) }
            }
            if let draft = singleItem.draft {
                Button("Discard Draft") {
                    Task { await store.discard(draft) }
                }
            }
            if !singleItem.inherited {
                Button("Move to Trash", role: .destructive) {
                    Task { await store.delete(singleItem) }
                }
            }
        }

        if targetItems.isEmpty {
            Button("New \(store.selectedKind.singularTitle)") {
                Task {
                    await store.createMemory(
                        kind: store.selectedKind,
                        scope: store.selectedSection == .hub ? .org : .project
                    )
                }
            }
            .disabled(
                !store.canCreateMemory(
                    kind: store.selectedKind,
                    scope: store.selectedSection == .hub ? .org : .project
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

    private func addToLocal(_ items: [MemoryListItem], projectId: String) {
        Task {
            do {
                try await store.addHubMemory(
                    resourceIds: Set(items.map(\.id)),
                    toProject: projectId
                )
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func removeFromLocal(_ items: [MemoryListItem]) {
        Task {
            do {
                try await store.removeHubMemoryFromActiveProject(
                    resourceIds: Set(items.map(\.id))
                )
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func addToLocalTitle(count: Int) -> String {
        count == 1 ? "Add to Local" : "Add \(count) Items to Local"
    }

    private func removeFromLocalTitle(count: Int) -> String {
        count == 1 ? "Remove from Local" : "Remove \(count) Items from Local"
    }
}

private struct FileTreeRow: View {
    let entry: VisibleFileTreeNode
    let isExpanded: Bool
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
        HStack(spacing: 6) {
            if let item {
                FileSymbolView(path: item.document.path)
            } else {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }

            Text(entry.node.name)
                .font(.system(size: 12.5, weight: .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(titleColor)

            Spacer(minLength: 4)
        }
        .padding(.leading, CGFloat(entry.depth) * 13 + 5)
        .padding(.trailing, 7)
        .frame(maxWidth: .infinity, minHeight: 25, maxHeight: 25, alignment: .leading)
        .contentShape(Rectangle())
        .help(item?.inherited == true ? "Inherited from Hub" : entry.node.name)
    }

    private var titleColor: Color {
        guard let item else { return .primary }
        if item.draft?.freshness == .behind { return .orange }
        if item.draft != nil { return .accentColor }
        if item.inherited { return .secondary }
        return .primary
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

    private struct Entry {
        let item: MemoryListItem
        let components: ArraySlice<String>
    }

    static func build(_ items: [MemoryListItem]) -> [FileTreeNode] {
        let entries = items.map { item in
            var components = item.document.path.split(separator: "/").map(String.init)
            if item.kind == .workflows, components.first == "workflow", components.count > 1 {
                components.removeFirst()
            }
            return Entry(item: item, components: components[...])
        }
        return build(entries, prefix: "")
    }

    private static func build(_ entries: [Entry], prefix: String) -> [FileTreeNode] {
        let groups = Dictionary(grouping: entries) { $0.components.first ?? $0.item.document.title }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let group = groups[name] ?? []
            if let file = group.first(where: { $0.components.count <= 1 }) {
                return .init(
                    id: file.item.id,
                    name: name,
                    item: file.item,
                    children: nil
                )
            }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let descendants = group.map { Entry(item: $0.item, components: $0.components.dropFirst()) }
            return .init(id: "directory:\(path)", name: name, item: nil, children: build(descendants, prefix: path))
        }
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
    @State private var reconciliationInitialComparison = DraftReconciliationComparison.shared
    @State private var loadsReconciliation = false

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
                    initialComparison: reconciliationInitialComparison,
                    onCancel: { reconciliationCandidate = nil }
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
        .onDisappear { flushSave() }
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
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DocumentPathBreadcrumb(path: mode == .preview ? item.document.path : document.path)
                    .accessibilityLabel("Path: \(mode == .preview ? item.document.path : document.path)")
                Spacer()
                HStack(spacing: 4) {
                    if supportsMarkdownPreview {
                        Button {
                            store.open(item, mode: mode == .preview ? .source : .preview)
                        } label: {
                            Image(systemName: mode == .preview ? "doc.plaintext" : "eye")
                        }
                        .buttonStyle(DocumentToolButtonStyle())
                        .help(mode == .preview ? "Open Source" : "Open Preview")
                        .accessibilityLabel(mode == .preview ? "Open Source" : "Open Preview")
                    }
                    Menu {
                        if item.inherited {
                            Button("Open in Hub") { openInHub() }
                        }
                        if let draft = item.draft, draft.status == .open {
                            Button("Request Review") {
                                reviewDraft = draft
                            }
                            Divider()
                        }
                        if let draft = item.draft {
                            Button("Discard Draft") { discard(draft) }
                        }
                        if !item.inherited {
                            Button("Move to Trash", role: .destructive) { moveToTrash() }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .buttonStyle(DocumentToolButtonStyle())
                    .menuIndicator(.hidden)
                    .help("Document Actions")
                    .accessibilityLabel("Document Actions")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: WorkbenchChrome.barHeight)
            .background(.bar)
            Divider()

            if let draft = activeDraft, draft.freshness == .behind {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Shared memory has changed")
                            .font(.callout.weight(.medium))
                        Text("Review the latest shared version before updating this draft.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review") {
                        loadReconciliation(for: draft, comparison: .shared)
                    }
                    Button("Update…") {
                        loadReconciliation(for: draft, comparison: .result)
                    }
                        .buttonStyle(.borderedProminent)
                    if loadsReconciliation {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .background(.orange.opacity(0.08))
                Divider()
            }

            if item.draft?.isDeletion == true {
                ContentUnavailableView(
                    "Pending deletion",
                    systemImage: "trash",
                    description: Text("Discard the draft to keep this memory.")
                )
            } else if mode == .preview {
                MarkdownPreview(source: renderedSource)
            } else {
                editor
                    .disabled(item.inherited)
            }
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

    private var supportsMarkdownPreview: Bool {
        guard item.draft?.isDeletion != true else { return false }
        let path = mode == .preview ? item.document.path : document.path
        return item.kind.supportsMarkdownPreview(path: path)
    }

    private var activeDraft: LocalDraft? {
        guard let draft = item.draft else { return nil }
        return store.drafts.first(where: { $0.id == draft.id }) ?? draft
    }

    private func loadReconciliation(
        for draft: LocalDraft,
        comparison: DraftReconciliationComparison
    ) {
        guard !loadsReconciliation else { return }
        reconciliationInitialComparison = comparison
        loadsReconciliation = true
        Task {
            defer { loadsReconciliation = false }
            do {
                try await store.flushDocumentSave(item.id)
                let latest = store.drafts.first {
                    $0.id == draft.id || (draft.targetId != nil && $0.targetId == draft.targetId)
                } ?? draft
                reconciliationCandidate = try await store.reconciliationCandidate(for: latest)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
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

    private func openInHub() {
        Task { await store.reveal(item) }
    }

    private func moveToTrash() {
        suppressesSaving = true
        store.cancelDocumentSave(item.id)
        Task { await store.delete(item) }
    }
}

enum DraftReconciliationComparison: String, CaseIterable, Identifiable {
    case shared
    case draft
    case result

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shared: "Shared Changes"
        case .draft: "Your Changes"
        case .result: "Result"
        }
    }

    var description: String {
        switch self {
        case .shared: "Changes in the shared version since this draft started."
        case .draft: "Changes made in this draft against its base."
        case .result: "The changes that will update this draft to the latest shared version."
        }
    }
}

struct DraftReconciliationView: View {
    let candidate: DraftReconciliationCandidate
    let onCancel: () -> Void
    let onApplied: () -> Void
    let onApply: (ReconciliationResourceState?) async throws -> Void

    @State private var selectedComparison: DraftReconciliationComparison
    @State private var resolvedExists: Bool
    @State private var resolvedPath: String
    @State private var resolvedContent: String
    @State private var isApplying = false
    @State private var errorMessage: String?

    init(
        candidate: DraftReconciliationCandidate,
        initialComparison: DraftReconciliationComparison = .shared,
        onCancel: @escaping () -> Void,
        onApplied: (() -> Void)? = nil,
        onApply: @escaping (ReconciliationResourceState?) async throws -> Void
    ) {
        self.candidate = candidate
        self.onCancel = onCancel
        self.onApplied = onApplied ?? onCancel
        self.onApply = onApply
        _selectedComparison = State(initialValue: initialComparison)
        let initial = candidate.proposedState ?? candidate.draftState
        _resolvedExists = State(initialValue: initial.exists)
        _resolvedPath = State(initialValue: initial.resource.path ?? "")
        _resolvedContent = State(initialValue: initial.content?.primaryText ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update Draft")
                        .font(.headline)
                    Text(candidate.draftState.resource.path ?? "Untitled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                statusLabel
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Picker("Comparison", selection: $selectedComparison) {
                    ForEach(DraftReconciliationComparison.allCases) { comparison in
                        Text(comparison.title).tag(comparison)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(selectedComparison.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if selectedComparison == .result && candidate.status == .conflicts {
                conflictResolution
            } else {
                comparisonDiff
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }

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
                .disabled(
                    isApplying
                        || !candidate.valid
                        || (candidate.status == .conflicts && resolvedExists && resolvedPath.isEmpty)
                )
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if !candidate.valid {
            Label("Out of date", systemImage: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
        } else if candidate.status == .conflicts {
            Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Label("Ready to update", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private var comparisonDiff: some View {
        ReviewDiffView(
            base: comparisonStates.before.exists
                ? comparisonStates.before.content?.primaryText ?? ""
                : "",
            proposed: comparisonStates.after.exists
                ? comparisonStates.after.content?.primaryText ?? ""
                : "",
            basePath: comparisonStates.before.exists
                ? comparisonStates.before.resource.path
                : nil,
            proposedPath: comparisonStates.after.exists
                ? comparisonStates.after.resource.path
                : nil,
            scrollAxes: [.horizontal, .vertical],
            fillsAvailableWidth: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conflictResolution: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Label(conflictSummary, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)

                Spacer(minLength: 12)

                Toggle("Keep File", isOn: $resolvedExists)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                if resolvedExists {
                    TextField("Path", text: $resolvedPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
            }

            GeometryReader { proxy in
                if proxy.size.width >= 820 {
                    HSplitView {
                        conflictDiffPane
                            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                        resolvedContentPane
                            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VSplitView {
                        conflictDiffPane
                            .frame(minHeight: 180, maxHeight: .infinity)
                        resolvedContentPane
                            .frame(minHeight: 180, maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conflictDiffPane: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Result Diff")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            comparisonDiff
        }
    }

    private var resolvedContentPane: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Resolved Content")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if resolvedExists {
                TextEditor(text: $resolvedContent)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.separator)
                    }
            } else {
                ContentUnavailableView(
                    "File Removed",
                    systemImage: "trash",
                    description: Text("The resolved result removes this file.")
                )
            }
        }
    }

    private var comparisonStates: (
        before: ReconciliationResourceState,
        after: ReconciliationResourceState
    ) {
        switch selectedComparison {
        case .shared:
            (candidate.baseState, candidate.currentState)
        case .draft:
            (candidate.baseState, candidate.draftState)
        case .result:
            (candidate.currentState, resultState)
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

    private func apply() {
        guard !isApplying else { return }
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
            kind: template.resource.kind,
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
                    initialComparison: .result,
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

private struct DocumentToolButtonStyle: ButtonStyle {
    let isSelected: Bool

    @State private var isHovered = false

    init(isSelected: Bool = false) {
        self.isSelected = isSelected
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(width: 24, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { isHovered = $0 }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color(nsColor: .labelColor).opacity(0.14)
        }
        if isSelected {
            return Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
        if isHovered {
            return Color(nsColor: .labelColor).opacity(0.07)
        }
        return .clear
    }
}

private struct DocumentPathBreadcrumb: View {
    let path: String

    private var components: [String] {
        path.split(separator: "/").map(String.init)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(component)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(index == components.count - 1 ? 1 : 0)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
    }
}
