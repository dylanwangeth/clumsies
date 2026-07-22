import SwiftUI

struct BundleNavigator: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        List(selection: $store.selectedBundleId) {
            ForEach(store.bundles) { bundle in
                VStack(alignment: .leading, spacing: 2) {
                    Text(bundle.name)
                        .lineLimit(1)
                    Text("\(bundle.resourceIds.count) resources")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(bundle.id)
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        Task { await store.deleteBundle(bundle) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .task { await store.prepareWorkspaceIndex(includeContent: false) }
    }
}

struct BundleDetail: View {
    @ObservedObject var store: WorkspaceStore
    @Binding var showsResourcePicker: Bool
    @Binding var confirmsDeletion: Bool

    var body: some View {
        if let bundle = store.selectedBundle {
            BundleEditor(
                store: store,
                bundle: bundle,
                showsResourcePicker: $showsResourcePicker,
                confirmsDeletion: $confirmsDeletion
            )
                .id(bundle.id)
        } else {
            ContentUnavailableView(
                "No Bundles",
                systemImage: "shippingbox",
                description: Text("Create a personal Bundle to collect memory for recurring work.")
            )
        }
    }
}

private struct BundleEditor: View {
    @ObservedObject var store: WorkspaceStore
    let bundle: PersonalBundle

    @State private var name: String
    @State private var description: String
    @State private var resourceIds: Set<String>
    @Binding var showsResourcePicker: Bool
    @Binding var confirmsDeletion: Bool
    @State private var isDeleting = false

    init(
        store: WorkspaceStore,
        bundle: PersonalBundle,
        showsResourcePicker: Binding<Bool>,
        confirmsDeletion: Binding<Bool>
    ) {
        self.store = store
        self.bundle = bundle
        _name = State(initialValue: bundle.name)
        _description = State(initialValue: bundle.description)
        _resourceIds = State(initialValue: Set(bundle.resourceIds))
        _showsResourcePicker = showsResourcePicker
        _confirmsDeletion = confirmsDeletion
    }

    var body: some View {
        Form {
            Section("Bundle") {
                TextField("Name", text: $name)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2...6)
            }
            Section {
                if selectedResources.isEmpty {
                    Text("No memory has been added.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(selectedResources) { resource in
                        HStack(spacing: 10) {
                            Button {
                                open(resource)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(resource.document.title)
                                        .lineLimit(1)
                                    Text(resourceLocation(resource))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open \(resource.document.title)")
                            .accessibilityLabel("Open \(resource.document.title)")

                            Button {
                                resourceIds.remove(resource.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove from Bundle")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Memory")
                    Spacer()
                    Text(resourceIds.count, format: .number)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsResourcePicker) {
            BundleResourcePicker(resources: selectableResources, selection: $resourceIds)
        }
        .confirmationDialog(
            "Delete \(bundle.name)?",
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Bundle", role: .destructive) { deleteBundle() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Bundle will be permanently removed. Its memory is not affected.")
        }
        .onChange(of: name) { _, _ in scheduleSave() }
        .onChange(of: description) { _, _ in scheduleSave() }
        .onChange(of: resourceIds) { _, _ in scheduleSave() }
        .onDisappear { flushSave() }
    }

    private var selectableResources: [MemoryResource] {
        store.resources.filter { $0.kind.isUserMaintained }
    }

    private var selectedResources: [MemoryResource] {
        selectableResources
            .filter { resourceIds.contains($0.id) }
            .sorted {
                let locationOrder = resourceLocation($0).localizedStandardCompare(resourceLocation($1))
                if locationOrder != .orderedSame { return locationOrder == .orderedAscending }
                return $0.document.title.localizedStandardCompare($1.document.title) == .orderedAscending
            }
    }

    private var hasChanges: Bool {
        name != bundle.name
            || description != bundle.description
            || resourceIds != Set(bundle.resourceIds)
    }

    private func resourceLocation(_ resource: MemoryResource) -> String {
        let scope = resource.scope == .org ? "Hub" : resource.projectName ?? "Project"
        return "\(scope) · \(resource.kind.singularTitle)"
    }

    private func open(_ resource: MemoryResource) {
        let item = MemoryListItem(
            id: resource.id,
            resource: resource,
            draft: nil,
            inherited: false
        )
        Task { await store.reveal(item) }
    }

    private func scheduleSave() {
        guard !isDeleting else { return }
        store.stageBundleSave(
            bundle,
            name: name,
            description: description,
            resourceIds: resourceIds
        )
    }

    private func flushSave() {
        guard !isDeleting, hasChanges else { return }
        Task {
            do {
                try await store.flushBundleSave(bundle.id)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteBundle() {
        isDeleting = true
        store.cancelBundleSave(bundle.id)
        Task { await store.deleteBundle(bundle) }
    }
}

private struct BundleResourcePicker: View {
    let resources: [MemoryResource]
    @Binding var selection: Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(MemoryKind.userMaintainedCases) { kind in
                    let candidates = filteredResources.filter { $0.kind == kind }
                    if !candidates.isEmpty {
                        Section(kind.title) {
                            ForEach(candidates) { resource in
                                Toggle(isOn: selectionBinding(for: resource.id)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(resource.document.title)
                                            .lineLimit(1)
                                        Text(resourceLocation(resource))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityLabel(
                                    "\(resource.document.title), \(resourceLocation(resource))"
                                )
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search memory")
            .navigationTitle("Add Memory")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 620, height: 600)
    }

    private var filteredResources: [MemoryResource] {
        let candidates = resources.sorted {
            $0.document.title.localizedStandardCompare($1.document.title) == .orderedAscending
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return candidates }
        return candidates.filter {
            $0.document.title.localizedCaseInsensitiveContains(term)
                || $0.document.path.localizedCaseInsensitiveContains(term)
                || resourceLocation($0).localizedCaseInsensitiveContains(term)
        }
    }

    private func selectionBinding(for resourceId: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(resourceId) },
            set: { selected in
                if selected { selection.insert(resourceId) }
                else { selection.remove(resourceId) }
            }
        )
    }

    private func resourceLocation(_ resource: MemoryResource) -> String {
        resource.scope == .org ? "Hub" : resource.projectName ?? "Project"
    }
}
