import AppKit
import SwiftUI

enum ProjectMetadataValidation {
    static func isValid(name: String, description: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedName.isEmpty
            && normalizedName.count <= 120
            && normalizedDescription.count <= 4_000
    }
}

enum ProjectCreationValidation {
    static func isValid(name: String, description: String, repositoryCount: Int) -> Bool {
        ProjectMetadataValidation.isValid(name: name, description: description)
            && repositoryCount > 0
    }
}

struct ProjectCreationSheet: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = ""
    @State private var description = ""
    @State private var repositories: [URL] = []
    @State private var selectedBundleId: String?
    @State private var selectedAdapters: Set<ProjectAgentAdapterKind> = []
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var idempotencyKey = UUID().uuidString.lowercased()

    var body: some View {
        VStack(spacing: 0) {
            Text("New Project")
                .font(.title2)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)

            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Repositories") {
                    ForEach(repositories, id: \.path) { repository in
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repository.lastPathComponent)
                                    .lineLimit(1)
                                Text(repository.deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button {
                                repositories.removeAll { $0.path == repository.path }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove Repository")
                            .accessibilityLabel("Remove \(repository.lastPathComponent)")
                        }
                    }

                    Button {
                        chooseRepositories()
                    } label: {
                        Label("Add Repositories…", systemImage: "plus")
                    }
                }

                Section("Memory") {
                    Picker("Bundle", selection: $selectedBundleId) {
                        Text("None")
                            .tag(Optional<String>.none)
                        ForEach(store.bundles) { bundle in
                            Text("\(bundle.name) (\(bundle.resourceIds.count))")
                                .tag(Optional(bundle.id))
                        }
                    }

                    Text("A Bundle imports its Hub memory into the new Project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Coding Agents") {
                    ForEach(ProjectAgentAdapterKind.allCases) { adapter in
                        Toggle(
                            adapter.title,
                            isOn: Binding(
                                get: { selectedAdapters.contains(adapter) },
                                set: { selected in
                                    if selected {
                                        selectedAdapters.insert(adapter)
                                    } else {
                                        selectedAdapters.remove(adapter)
                                    }
                                }
                            )
                        )
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .textSelection(.enabled)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)

                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCreating)
            }
            .padding(12)
        }
        .frame(width: 560, height: 640)
        .interactiveDismissDisabled(isCreating)
        .onAppear {
            DispatchQueue.main.async {
                nameFocused = true
            }
        }
    }

    private var isValid: Bool {
        ProjectCreationValidation.isValid(
            name: name,
            description: description,
            repositoryCount: repositories.count
        )
    }

    private func chooseRepositories() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = "Add"
        panel.begin { response in
            guard response == .OK else { return }
            let existing = Set(repositories.map(\.standardized.path))
            repositories += panel.urls
                .map(\.standardized)
                .filter { !existing.contains($0.path) }
            repositories.sort { $0.path < $1.path }
        }
    }

    private func create() {
        guard isValid, !isCreating else { return }
        isCreating = true
        errorMessage = nil
        Task {
            do {
                try await store.createProject(
                    name: name,
                    description: description,
                    idempotencyKey: idempotencyKey,
                    repositoryPaths: repositories.map(\.path),
                    bundleId: selectedBundleId,
                    adapters: selectedAdapters
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}

struct ProjectUnavailableView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ContentUnavailableView {
            Label("No Projects", systemImage: "folder")
        } description: {
            if store.canManageProjects {
                Text("Create a Project to start organizing local memory.")
            } else {
                Text("Ask an organization administrator to grant you access to a Project.")
            }
        } actions: {
            if store.canManageProjects {
                Button("New Project…") {
                    store.presentProjectCreation()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Refresh") {
                    Task { await store.reload() }
                }
            }
        }
    }
}

struct ProjectSettingsView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var project: ProjectRecord?
    @State private var name = ""
    @State private var description = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("General") {
                if isLoading, project == nil {
                    ProgressView()
                        .controlSize(.small)
                } else if let project {
                    if store.canManageProjects {
                        TextField("Name", text: $name)
                        TextField("Description", text: $description, axis: .vertical)
                            .lineLimit(2...5)

                        HStack {
                            Spacer()
                            Button("Save") {
                                save(project)
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!hasChanges || !isValid || isSaving)
                        }
                    } else {
                        LabeledContent("Name", value: project.name)
                        LabeledContent(
                            "Description",
                            value: project.description.isEmpty ? "None" : project.description
                        )
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .textSelection(.enabled)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ProjectLocalSetupSettings(store: store)
            ProjectMemoryCacheSettings(store: store)

            if store.canManageProjects {
                Section("Access") {
                    Button("Manage Access…") {
                        openAccessManagement()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: store.activeProjectId) {
            await load()
        }
    }

    private var hasChanges: Bool {
        guard let project else { return false }
        return name != project.name || description != project.description
    }

    private var isValid: Bool {
        ProjectMetadataValidation.isValid(name: name, description: description)
    }

    private func load() async {
        guard let projectId = store.activeProjectId else {
            project = nil
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            apply(try await store.projectRecord(projectId, refresh: true))
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ project: ProjectRecord) {
        guard isValid, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                apply(try await store.updateProject(
                    project.id,
                    expectedRevision: project.revision,
                    name: name,
                    description: description
                ))
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func apply(_ project: ProjectRecord) {
        self.project = project
        name = project.name
        description = project.description
    }

    private func openAccessManagement() {
        guard let projectId = store.activeProjectId,
              let serverURL = URL(string: store.runtime?.health.serverUrl ?? "") else {
            return
        }
        NSWorkspace.shared.open(
            serverURL
                .appending(path: "admin")
                .appending(path: "projects")
                .appending(path: projectId)
        )
    }
}

private struct ProjectLocalSetupSettings: View {
    @ObservedObject var store: WorkspaceStore
    @State private var bindings: [DaemonProjectBinding] = []
    @State private var adapters: [DaemonProjectAgentAdapter] = []
    @State private var pendingAdapterValues: [String: Bool] = [:]
    @State private var workingKeys: Set<String> = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var bindingToRemove: DaemonProjectBinding?

    var body: some View {
        Section("Repositories") {
            if isLoading, bindings.isEmpty {
                ProgressView()
                    .controlSize(.small)
            } else {
                ForEach(bindings) { binding in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: binding.workspaceRoot).lastPathComponent)
                                .lineLimit(1)
                            Text(binding.workspaceRoot)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(binding.workspaceRoot)
                        }
                        Spacer()
                        Menu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    URL(fileURLWithPath: binding.workspaceRoot)
                                ])
                            }
                            Divider()
                            Button("Remove Repository", role: .destructive) {
                                bindingToRemove = binding
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuIndicator(.hidden)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Repository Actions")
                    }
                }
            }

            Button {
                chooseRepositories()
            } label: {
                Label("Add Repositories…", systemImage: "plus")
            }
            .disabled(store.activeProjectId == nil || isLoading)

            if let errorMessage {
                Text(errorMessage)
                    .textSelection(.enabled)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Section("Coding Agents") {
            if bindings.isEmpty {
                Text("Add a repository before configuring a Coding Agent.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bindings) { binding in
                    VStack(alignment: .leading, spacing: 8) {
                        if bindings.count > 1 {
                            Text(URL(fileURLWithPath: binding.workspaceRoot).lastPathComponent)
                                .fontWeight(.medium)
                        }
                        ForEach(ProjectAgentAdapterKind.allCases) { adapter in
                            Toggle(
                                adapter.title,
                                isOn: adapterBinding(adapter, repository: binding)
                            )
                            .disabled(workingKeys.contains(adapterKey(adapter, binding.workspaceRoot)))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .task(id: store.activeProjectId) {
            await load()
        }
        .confirmationDialog(
            "Remove Repository?",
            isPresented: Binding(
                get: { bindingToRemove != nil },
                set: { if !$0 { bindingToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let binding = bindingToRemove else { return }
                bindingToRemove = nil
                Task { await remove(binding) }
            }
            Button("Cancel", role: .cancel) {
                bindingToRemove = nil
            }
        } message: {
            Text("Clumsies will remove its Coding Agent configuration from this repository and stop resolving it to the Project.")
        }
    }

    private func load() async {
        guard let projectId = store.activeProjectId else {
            bindings = []
            adapters = []
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let loadedBindings = store.projectBindings(projectId)
            async let loadedAdapters = store.projectAgentAdapters(projectId)
            (bindings, adapters) = try await (loadedBindings, loadedAdapters)
            pendingAdapterValues = [:]
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseRepositories() {
        guard let projectId = store.activeProjectId else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = "Add"
        panel.begin { response in
            guard response == .OK else { return }
            Task {
                isLoading = true
                errorMessage = nil
                do {
                    _ = try await store.addProjectRepositories(
                        panel.urls.map(\.path),
                        projectId: projectId
                    )
                    await load()
                } catch {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func remove(_ binding: DaemonProjectBinding) async {
        isLoading = true
        errorMessage = nil
        do {
            try await store.removeProjectRepository(binding, adapters: adapters)
            await load()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func adapterBinding(
        _ adapter: ProjectAgentAdapterKind,
        repository: DaemonProjectBinding
    ) -> Binding<Bool> {
        let key = adapterKey(adapter, repository.workspaceRoot)
        return Binding(
            get: {
                pendingAdapterValues[key]
                    ?? (currentAdapter(adapter, repository.workspaceRoot) != nil)
            },
            set: { enabled in
                pendingAdapterValues[key] = enabled
                workingKeys.insert(key)
                let current = currentAdapter(adapter, repository.workspaceRoot)
                Task {
                    do {
                        try await store.setProjectAgentAdapter(
                            adapter,
                            enabled: enabled,
                            projectId: repository.projectId,
                            workspaceRoot: repository.workspaceRoot,
                            current: current
                        )
                        // Installing the first Adapter can normalize a historical
                        // symlink-based binding to its canonical filesystem path.
                        // Refresh both collections so the toggle compares the two
                        // daemon-owned records using the same workspace identity.
                        async let refreshedBindings = store.projectBindings(repository.projectId)
                        async let refreshedAdapters = store.projectAgentAdapters(repository.projectId)
                        (bindings, adapters) = try await (refreshedBindings, refreshedAdapters)
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    pendingAdapterValues.removeValue(forKey: key)
                    workingKeys.remove(key)
                }
            }
        )
    }

    private func currentAdapter(
        _ adapter: ProjectAgentAdapterKind,
        _ workspaceRoot: String
    ) -> DaemonProjectAgentAdapter? {
        adapters.first {
            $0.adapter == adapter && $0.workspaceRoot == workspaceRoot
        }
    }

    private func adapterKey(_ adapter: ProjectAgentAdapterKind, _ workspaceRoot: String) -> String {
        "\(workspaceRoot):\(adapter.rawValue)"
    }
}
