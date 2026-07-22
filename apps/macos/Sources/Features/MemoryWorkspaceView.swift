import SwiftUI

struct MemoryNavigator: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        FileTreeView(store: store, items: store.visibleMemoryItems)
        .sheet(isPresented: $store.showsOrgSelection) {
            ProjectOrgSelectionView(store: store)
                .frame(width: 620, height: 620)
        }
        .onChange(of: store.selectedKind) { _, _ in
            store.selectedItemId = nil
        }
    }
}

struct MemoryMainPane: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            if !store.visibleTabs.isEmpty {
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
                    EmptyWorkspaceView()
                }
            } else {
                EmptyWorkspaceView()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
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

private struct FileTreeView: View {
    @ObservedObject var store: WorkspaceStore
    let items: [MemoryListItem]
    @State private var expandedDirectoryIds: Set<String> = []
    @State private var initializedExpansion = false

    private var roots: [FileTreeNode] {
        FileTreeNode.build(items)
    }

    private var visibleNodes: [VisibleFileTreeNode] {
        FileTreeNode.visibleNodes(roots, expandedDirectoryIds: expandedDirectoryIds)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(visibleNodes) { entry in
                    FileTreeRow(
                        store: store,
                        entry: entry,
                        isExpanded: expandedDirectoryIds.contains(entry.id),
                        onToggleDirectory: {
                            withAnimation(.snappy(duration: 0.14)) {
                                if expandedDirectoryIds.contains(entry.id) {
                                    expandedDirectoryIds.remove(entry.id)
                                } else {
                                    expandedDirectoryIds.insert(entry.id)
                                }
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .contextMenu {
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
        .onAppear {
            guard !initializedExpansion else { return }
            expandedDirectoryIds = FileTreeNode.directoryIds(in: roots)
            initializedExpansion = true
        }
        .onChange(of: items.map { "\($0.id):\($0.document.path)" }) { _, _ in
            expandedDirectoryIds.formUnion(FileTreeNode.directoryIds(in: roots))
        }
    }
}

private struct FileTreeRow: View {
    @ObservedObject var store: WorkspaceStore
    let entry: VisibleFileTreeNode
    let isExpanded: Bool
    let onToggleDirectory: () -> Void
    @State private var isHovered = false
    @State private var showsRenameAlert = false
    @State private var proposedName = ""

    private var item: MemoryListItem? { entry.node.item }
    private var isSelected: Bool {
        guard let item else { return false }
        return store.activeVisibleTab?.itemId == item.id || store.selectedItemId == item.id
    }

    var body: some View {
        Button {
            if let item {
                store.open(item)
            } else {
                onToggleDirectory()
            }
        } label: {
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
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(item?.inherited == true ? "Inherited from Hub" : entry.node.name)
        .contextMenu {
            if let item {
                Button("Open") { store.open(item) }
                if item.supportsMarkdownPreview {
                    Button("Open Preview") { store.open(item, mode: .preview) }
                }
                Divider()
                if item.inherited {
                    Button("Open in Hub") {
                        Task { await store.reveal(item) }
                    }
                } else {
                    Button("Rename…") { beginRenaming(item) }
                }
                if let draft = item.draft {
                    Button("Discard Draft") { Task { await store.discard(draft) } }
                }
                if !item.inherited {
                    Button("Move to Trash", role: .destructive) { Task { await store.delete(item) } }
                }
            }
        }
        .alert("Rename Memory", isPresented: $showsRenameAlert) {
            TextField("File name", text: $proposedName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let item {
                    rename(item)
                }
            }
            .disabled(!isValidProposedName)
        }
    }

    private var titleColor: Color {
        guard let item else { return .primary }
        if item.draft?.freshness == .behind { return .orange }
        if item.draft != nil { return .accentColor }
        if item.inherited { return .secondary }
        return .primary
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isHovered { return Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.55) }
        return .clear
    }

    private var isValidProposedName: Bool {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private func beginRenaming(_ item: MemoryListItem) {
        proposedName = item.document.path.split(separator: "/").last.map(String.init) ?? item.document.path
        showsRenameAlert = true
    }

    private func rename(_ item: MemoryListItem) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidProposedName else { return }
        var document = item.document
        let parent = document.path
            .split(separator: "/")
            .dropLast()
            .joined(separator: "/")
        document.path = parent.isEmpty ? name : "\(parent)/\(name)"
        Task {
            do {
                try await store.save(item, document: document)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct VisibleFileTreeNode: Identifiable {
    let node: FileTreeNode
    let depth: Int

    var id: String { node.id }
}

private struct FileTreeNode: Identifiable {
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
                reconciliationCandidate = try await store.reconciliationCandidate(for: draft)
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

private struct ProjectOrgSelectionView: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIds: Set<String>
    @State private var saving = false

    init(store: WorkspaceStore) {
        self.store = store
        _selectedIds = State(initialValue: store.activeProject?.selectedOrgResourceIds ?? [])
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(MemoryKind.allCases) { kind in
                    Section(kind.title) {
                        ForEach(store.resources.filter { $0.scope == .org && $0.kind == kind }) { resource in
                            Toggle(isOn: Binding(
                                get: { selectedIds.contains(resource.id) },
                                set: { enabled in
                                    if enabled { selectedIds.insert(resource.id) }
                                    else { selectedIds.remove(resource.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(resource.document.title)
                                    Text(resource.document.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityLabel("\(resource.document.title), \(resource.document.path)")
                            .disabled(!store.canManageOrgSelection)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .navigationTitle("Hub Memory for \(store.activeProject?.name ?? "Project")")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving || !store.canManageOrgSelection)
                }
            }
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                try await store.replaceProjectOrgSelection(resourceIds: selectedIds)
                dismiss()
            } catch {
                store.errorMessage = error.localizedDescription
                saving = false
            }
        }
    }
}
