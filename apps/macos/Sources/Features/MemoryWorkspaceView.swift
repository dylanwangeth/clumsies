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
        if item.draft?.conflict != nil { return .red }
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
    @State private var showsRuleDetails = false
    @State private var reviewDraft: LocalDraft?

    init(store: WorkspaceStore, item: MemoryListItem, mode: WorkbenchTabMode) {
        self.store = store
        self.item = item
        self.mode = mode
        _document = State(initialValue: item.document)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DocumentPathBreadcrumb(path: mode == .preview ? item.document.path : document.path)
                    .accessibilityLabel("Path: \(mode == .preview ? item.document.path : document.path)")
                Spacer()
                HStack(spacing: 4) {
                    if item.kind == .rules {
                        Button {
                            showsRuleDetails.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(DocumentToolButtonStyle(isSelected: showsRuleDetails))
                        .help("Rule Details")
                        .accessibilityLabel("Rule Details")
                        .popover(isPresented: $showsRuleDetails, arrowEdge: .top) {
                            RuleDetailsPopover(
                                document: mode == .preview ? .constant(item.document) : $document,
                                isEditable: mode == .source && !item.inherited
                            )
                        }
                    }
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
        .onChange(of: document) { _, _ in scheduleSave() }
        .onDisappear { flushSave() }
        .sheet(item: $reviewDraft) { draft in
            ReviewRequestSheet(initialTitle: document.title) { title, description in
                try await submitReview(draft, title: title, description: description)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch item.kind {
        case .context, .rules, .workflows, .metaprompt:
            NativeTextEditor(text: $document.body)
        }
    }

    private var renderedSource: String {
        let sourceDocument = mode == .preview ? item.document : document
        switch item.kind {
        case .context, .rules, .workflows, .metaprompt:
            return sourceDocument.body
        }
    }

    private var supportsMarkdownPreview: Bool {
        let path = mode == .preview ? item.document.path : document.path
        return item.kind.supportsMarkdownPreview(path: path)
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
        description: String
    ) async throws {
        try await store.flushDocumentSave(item.id)
        let latest = store.drafts.first {
            $0.id == draft.id || (draft.targetId != nil && $0.targetId == draft.targetId)
        } ?? draft
        try await store.requestReview(
            for: latest,
            title: title,
            description: description
        )
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

private struct ReviewRequestSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSubmit: (String, String) async throws -> Void

    @State private var title: String
    @State private var description = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(
        initialTitle: String,
        onSubmit: @escaping (String, String) async throws -> Void
    ) {
        _title = State(initialValue: initialTitle)
        self.onSubmit = onSubmit
    }

    var body: some View {
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
                        Text("Request Review")
                    }
                }
                .disabled(isSubmitting || normalizedTitle.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 270)
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
                try await onSubmit(submittedTitle, submittedDescription)
                dismiss()
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
                ForEach(MemoryKind.userMaintainedCases) { kind in
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

private struct RuleDetailsPopover: View {
    @Binding var document: EditableMemoryDocument
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rule Details")
                .font(.headline)

            metadataField("Name") {
                if isEditable {
                    TextField("", text: $document.title)
                        .accessibilityLabel("Name")
                } else {
                    readOnlyValue(document.title)
                }
            }

            metadataField("Applies when") {
                if isEditable {
                    TextField("", text: $document.appliesWhen, axis: .vertical)
                        .accessibilityLabel("Applies when")
                        .lineLimit(2...5)
                } else {
                    readOnlyValue(document.appliesWhen)
                }
            }

            metadataField("Tags") {
                if isEditable {
                    TextField("", text: tagsBinding)
                        .accessibilityLabel("Tags")
                } else {
                    readOnlyValue(document.tags.joined(separator: ", "))
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var tagsBinding: Binding<String> {
        Binding(
            get: { document.tags.joined(separator: ", ") },
            set: {
                document.tags = $0
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func metadataField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func readOnlyValue(_ value: String) -> some View {
        Text(value.isEmpty ? "None" : value)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
