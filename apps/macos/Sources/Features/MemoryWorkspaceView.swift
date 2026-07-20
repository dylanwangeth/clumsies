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
                }
                if let draft = item.draft {
                    Button("Discard Draft") { Task { await store.discard(draft) } }
                }
                if !item.inherited {
                    Button("Move to Trash", role: .destructive) { Task { await store.delete(item) } }
                }
            }
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
        let entries = items.map {
            Entry(item: $0, components: Array($0.document.path.split(separator: "/").map(String.init))[...])
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

    init(store: WorkspaceStore, item: MemoryListItem, mode: WorkbenchTabMode) {
        self.store = store
        self.item = item
        self.mode = mode
        _document = State(initialValue: item.document)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DocumentPathControl(
                    path: mode == .preview ? .constant(item.document.path) : $document.path,
                    isEditable: mode == .source && !item.inherited
                )
                Spacer()
                ControlGroup {
                    if item.kind == .rules {
                        Button {
                            showsRuleDetails.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .symbolVariant(showsRuleDetails ? .fill : .none)
                                .foregroundStyle(showsRuleDetails ? Color.accentColor : .secondary)
                        }
                        .help("Rule Details")
                        .accessibilityLabel("Rule Details")
                    }
                    if supportsMarkdownPreview {
                        Button {
                            store.open(item, mode: mode == .preview ? .source : .preview)
                        } label: {
                            Image(systemName: mode == .preview ? "doc.plaintext" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .help(mode == .preview ? "Open Source" : "Open Preview")
                        .accessibilityLabel(mode == .preview ? "Open Source" : "Open Preview")
                    }
                    Menu {
                        if item.inherited {
                            Button("Open in Hub") { openInHub() }
                        }
                        if let draft = item.draft, draft.status == .open {
                            Button("Request Review") {
                                requestReview(draft)
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
                            .foregroundStyle(.secondary)
                    }
                    .menuIndicator(.hidden)
                    .help("Document Actions")
                    .accessibilityLabel("Document Actions")
                }
                .controlSize(.small)
                .popover(isPresented: $showsRuleDetails, arrowEdge: .top) {
                    RuleDetailsPopover(
                        document: mode == .preview ? .constant(item.document) : $document,
                        isEditable: mode == .source && !item.inherited
                    )
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
    }

    @ViewBuilder
    private var editor: some View {
        switch item.kind {
        case .context, .rules, .metaprompt:
            NativeTextEditor(text: $document.body)
        case .workflows:
            WorkflowDocumentEditor(
                document: $document,
                rules: store.resources.filter { $0.kind == .rules }
            )
        }
    }

    private var renderedSource: String {
        let sourceDocument = mode == .preview ? item.document : document
        switch item.kind {
        case .context, .rules, .metaprompt:
            return sourceDocument.body
        case .workflows:
            return "# \(sourceDocument.title)\n\n\(sourceDocument.body)\n\n" + sourceDocument.steps.enumerated().map { index, step in
                "\(index + 1). \(step.body ?? step.ruleId.map { "Apply rule `\($0)`." } ?? "")"
            }.joined(separator: "\n")
        }
    }

    private var supportsMarkdownPreview: Bool {
        if item.kind == .rules || item.kind == .metaprompt { return true }
        guard item.kind == .context else { return false }
        let path = mode == .preview ? item.document.path : document.path
        let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        return pathExtension == "md" || pathExtension == "markdown"
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

    private func requestReview(_ draft: LocalDraft) {
        let snapshot = document
        Task {
            do {
                try await store.flushDocumentSave(item.id)
                let latest = store.drafts.first {
                    $0.id == draft.id || (draft.targetId != nil && $0.targetId == draft.targetId)
                } ?? draft
                await store.requestReview(for: latest, title: snapshot.title)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
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

private struct DocumentPathControl: View {
    @Binding var path: String
    let isEditable: Bool

    @State private var isEditing = false
    @State private var originalPath = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("Path", text: $path)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .focused($isFocused)
                    .onSubmit { finishEditing() }
                    .onExitCommand {
                        path = originalPath
                        finishEditing()
                    }
            } else if isEditable {
                Button(action: beginEditing) {
                    DocumentPathBreadcrumb(path: path)
                }
                .buttonStyle(.plain)
                .help("Edit Path")
                .accessibilityLabel("Path: \(path)")
            } else {
                DocumentPathBreadcrumb(path: path)
                    .accessibilityLabel("Path: \(path)")
            }
        }
        .lineLimit(1)
        .onChange(of: isFocused) { _, focused in
            if isEditing && !focused {
                finishEditing()
            }
        }
    }

    private func beginEditing() {
        originalPath = path
        isEditing = true
        DispatchQueue.main.async { isFocused = true }
    }

    private func finishEditing() {
        isFocused = false
        isEditing = false
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

private struct WorkflowDocumentEditor: View {
    @Binding var document: EditableMemoryDocument
    let rules: [MemoryResource]

    var body: some View {
        Form {
            TextField("Name", text: $document.title)
            TextField("Description", text: $document.body, axis: .vertical)
                .lineLimit(2...6)
            Section("Steps") {
                ForEach($document.steps) { $step in
                    HStack(alignment: .top, spacing: 8) {
                        Picker("Type", selection: Binding(
                            get: { step.ruleId == nil ? "instruction" : "rule" },
                            set: { value in
                                if value == "rule" {
                                    step.ruleId = rules.first?.id
                                    step.body = nil
                                } else {
                                    step.ruleId = nil
                                    step.body = ""
                                }
                            }
                        )) {
                            Text("Instruction").tag("instruction")
                            Text("Rule").tag("rule")
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        if step.ruleId != nil {
                            Picker("Rule", selection: $step.ruleId) {
                                ForEach(rules) { rule in
                                    Text(rule.document.title).tag(Optional(rule.id))
                                }
                            }
                            .labelsHidden()
                        } else {
                            TextField("Instruction", text: Binding(
                                get: { step.body ?? "" },
                                set: { step.body = $0 }
                            ), axis: .vertical)
                        }
                        ToolbarIconButton(symbol: "trash", label: "Remove Step") {
                            document.steps.removeAll { $0.id == step.id }
                        }
                    }
                }
                Button {
                    document.steps.append(.init(body: ""))
                } label: {
                    Label("Add Step", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
    }
}
