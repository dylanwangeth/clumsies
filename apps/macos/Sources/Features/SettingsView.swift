import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable {
    case general
    case agent
    case advanced

    static let defaultsKey = "ClumsiesSettingsPane"

    var title: String {
        switch self {
        case .general: "General"
        case .agent: "Agent"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .agent: "person.2"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    static func restored(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .general
    }

    func persist(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

struct NativeSettingsView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var softwareUpdateController: SoftwareUpdateController
    let pane: SettingsPane
    let onOpenDiagnostics: () -> Void
    let onShowLogs: () -> Void

    var body: some View {
        Group {
            switch pane {
            case .general:
                GeneralSettingsView(softwareUpdateController: softwareUpdateController)
            case .agent:
                AgentsSettingsView(store: store)
            case .advanced:
                AdvancedSettingsView(
                    store: store,
                    onOpenDiagnostics: onOpenDiagnostics,
                    onShowLogs: onShowLogs
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var softwareUpdateController: SoftwareUpdateController

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section("Updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { softwareUpdateController.automaticallyChecksForUpdates },
                        set: { softwareUpdateController.automaticallyChecksForUpdates = $0 }
                    )
                )
                Toggle(
                    "Automatically download updates",
                    isOn: Binding(
                        get: { softwareUpdateController.automaticallyDownloadsUpdates },
                        set: { softwareUpdateController.automaticallyDownloadsUpdates = $0 }
                    )
                )
                .disabled(!softwareUpdateController.allowsAutomaticUpdates)
                Button("Check for Updates...") { softwareUpdateController.checkForUpdates() }
                    .disabled(!softwareUpdateController.canCheckForUpdates)
            }
            Section("About") {
                LabeledContent("Version", value: version)
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}

private struct AgentsSettingsView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var status: DaemonCodexPluginStatus?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var repairMessage: String?

    var body: some View {
        Form {
            Section("Codex") {
                if let status {
                    LabeledContent("Host", value: status.hostInstalled ? "Installed" : "Not installed")
                    LabeledContent("Marketplace", value: marketplaceLabel(status))
                    LabeledContent("Plugin installed", value: status.pluginInstalled ? "Yes" : "No")
                    LabeledContent("Plugin enabled", value: status.pluginEnabled ? "Yes" : "No")
                    LabeledContent("Installed version", value: status.installedVersion ?? "Not installed")
                    LabeledContent("Expected version", value: status.expectedVersion)
                    LabeledContent("Status", value: status.ready ? "Ready" : "Needs repair")
                } else if errorMessage == nil {
                    ProgressView()
                        .controlSize(.small)
                }

                Text("Clumsies installs and keeps this user-level Plugin enabled automatically. Repository bindings only choose the Project used by Memory and Kanban.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage {
                    Text(errorMessage)
                        .textSelection(.enabled)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let repairMessage {
                    Text(repairMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Repair") { Task { await repair() } }
                    .disabled(isWorking || status?.hostInstalled == false)
            }

            Section("After Codex Plugin Changes") {
                Text("Restart Codex and start a new task. In that task, open /hooks and review the current Clumsies Hook. Plugin Enabled does not mean Hook Trusted or AgentRun Ready.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            RepositoryAgentSettingsView(store: store)
        }
        .formStyle(.grouped)
        .padding(12)
        .task { await load() }
    }

    private func marketplaceLabel(_ status: DaemonCodexPluginStatus) -> String {
        if status.marketplaceConflict { return "Conflict" }
        return status.marketplaceInstalled ? "Installed" : "Not installed"
    }

    private func load() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            status = try await store.codexPluginStatus()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func repair() async {
        isWorking = true
        errorMessage = nil
        repairMessage = nil
        defer { isWorking = false }
        do {
            status = try await store.repairCodexPlugin()
            repairMessage = "Repair completed. Restart Codex and start a new task."
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct AgentRepositoryProject: Identifiable {
    let id: String
    let name: String
    let repositories: [DaemonProjectBinding]
}

private struct RepositoryAgentSettingsView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var projects: [AgentRepositoryProject] = []
    @State private var adapters: [DaemonProjectAgentAdapter] = []
    @State private var pendingValues: [String: Bool] = [:]
    @State private var workingKeys: Set<String> = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            Section("Repository Integrations") {
                if isLoading, projects.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else if store.projects.isEmpty {
                    Text("Create a Project and bind a repository before configuring these Agents.")
                        .foregroundStyle(.secondary)
                } else if projects.isEmpty {
                    Text("Add a repository in Project Settings before configuring these Agents.")
                        .foregroundStyle(.secondary)
                }

                Text("These integrations write Clumsies-managed configuration into specific repositories. Manage every Project here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage {
                    Text(errorMessage)
                        .textSelection(.enabled)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .task(id: [store.projectBindingsGeneration.uuidString]
                + store.projects.map { "\($0.id):\($0.name)" }) {
                await load()
            }

            ForEach(projects) { project in
                Section(project.name) {
                    ForEach(project.repositories) { repository in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(URL(fileURLWithPath: repository.workspaceRoot).lastPathComponent)
                                .fontWeight(.medium)
                            Text(repository.workspaceRoot)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(repository.workspaceRoot)

                            ForEach(ProjectAgentAdapterKind.repositoryIntegrationCases) { adapter in
                                Toggle(
                                    adapter.title,
                                    isOn: adapterBinding(adapter, repository: repository)
                                )
                                .disabled(!workingKeys.isEmpty)
                                .accessibilityLabel(
                                    "\(adapter.title) for \(URL(fileURLWithPath: repository.workspaceRoot).lastPathComponent) in \(project.name)"
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer {
            if !Task.isCancelled {
                isLoading = false
            }
        }
        do {
            try await reload()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func reload() async throws {
        var nextProjects: [AgentRepositoryProject] = []
        async let nextAdapters = store.allProjectAgentAdapters()
        for project in store.projects {
            try Task.checkCancellation()
            let repositories = try await store.projectBindings(project.id)
            if !repositories.isEmpty {
                nextProjects.append(.init(
                    id: project.id,
                    name: project.name,
                    repositories: repositories
                ))
            }
        }
        let loadedAdapters = try await nextAdapters
        try Task.checkCancellation()
        projects = nextProjects
        adapters = loadedAdapters
    }

    private func adapterBinding(
        _ adapter: ProjectAgentAdapterKind,
        repository: DaemonProjectBinding
    ) -> Binding<Bool> {
        let key = adapterKey(adapter, repository)
        return Binding(
            get: {
                pendingValues[key]
                    ?? (currentAdapter(adapter, repository) != nil)
            },
            set: { enabled in
                guard workingKeys.isEmpty else { return }
                pendingValues[key] = enabled
                workingKeys.insert(key)
                let current = currentAdapter(adapter, repository)
                Task {
                    do {
                        try await store.setProjectAgentAdapter(
                            adapter,
                            enabled: enabled,
                            projectId: repository.projectId,
                            workspaceRoot: repository.workspaceRoot,
                            current: current
                        )
                        try await reload()
                        errorMessage = nil
                    } catch {
                        let message = error.localizedDescription
                        try? await reload()
                        errorMessage = message
                    }
                    pendingValues.removeValue(forKey: key)
                    workingKeys.remove(key)
                }
            }
        )
    }

    private func currentAdapter(
        _ adapter: ProjectAgentAdapterKind,
        _ repository: DaemonProjectBinding
    ) -> DaemonProjectAgentAdapter? {
        adapters.first {
            $0.adapter == adapter
                && $0.serverUrl == repository.serverUrl
                && $0.projectId == repository.projectId
                && $0.workspaceRoot == repository.workspaceRoot
        }
    }

    private func adapterKey(
        _ adapter: ProjectAgentAdapterKind,
        _ repository: DaemonProjectBinding
    ) -> String {
        "\(repository.serverUrl):\(repository.workspaceRoot):\(adapter.rawValue)"
    }
}

private struct AdvancedSettingsView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpenDiagnostics: () -> Void
    let onShowLogs: () -> Void

    var body: some View {
        Form {
            Section("Runtime") {
                LabeledContent("Server", value: store.runtime?.health.serverUrl ?? "Unavailable")
                LabeledContent("Daemon", value: store.runtime?.health.daemonVersion ?? "Unavailable")
                LabeledContent("Background service", value: "LaunchAgent")
            }
            Section {
                Button("Open Runtime Status...") { onOpenDiagnostics() }
                Button("Show Logs in Finder") { onShowLogs() }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}

struct ProjectMemoryCacheSettings: View {
    private enum Confirmation: String, Identifiable {
        case reset
        case clear

        var id: String { rawValue }
    }

    @ObservedObject var store: WorkspaceStore
    @State private var storage: DaemonProjectStorage?
    @State private var move: DaemonProjectStorageMove?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var confirmation: Confirmation?

    var body: some View {
        Section("Memory Cache") {
            if let projectId = store.activeProjectId {
                if let storage {
                    LabeledContent("Location") {
                        Text(storage.selectedRootPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(storage.selectedRootPath)
                    }
                    LabeledContent("Used", value: Self.byteCount.string(fromByteCount: Int64(storage.sizeBytes)))
                    LabeledContent("Status", value: availabilityLabel(storage.availability))

                    if let move, !move.state.isTerminal {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(moveLabel(move.state))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let diagnostic = storage.diagnostic {
                        Label(diagnostic, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .textSelection(.enabled)
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Button("Choose...") { Task { await chooseLocation(projectId: projectId) } }
                        Button("Reveal in Finder") { reveal(storage.managedRootPath) }
                            .disabled(storage.availability == .unavailable)
                        Button("Reset") { confirmation = .reset }
                            .disabled(storage.mode == .standard)
                        Button("Clear Cache...") { confirmation = .clear }
                    }
                    .disabled(isWorking || move?.state.isTerminal == false)
                } else if isWorking {
                    ProgressView()
                } else {
                    Text(errorMessage ?? "Storage status is unavailable.")
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Select a Project to configure its local storage.")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: store.activeProjectId) {
            await loadStorage()
        }
        .confirmationDialog(
            confirmation == .reset ? "Reset to Default Location?" : "Clear Project Cache?",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if confirmation == .reset {
                Button("Reset", role: .destructive) { Task { await resetLocation() } }
            } else if confirmation == .clear {
                Button("Clear Cache", role: .destructive) { Task { await clearCache() } }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            if confirmation == .reset {
                Text("Clumsies will move the Project cache back to its standard macOS location.")
            } else {
                Text("Drafts and settings are preserved. Commit generations and the search index will be rebuilt.")
            }
        }
    }

    private func loadStorage() async {
        guard let projectId = store.activeProjectId else {
            storage = nil
            move = nil
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let loaded = try await store.daemon.projectStorage(projectId)
            storage = loaded
            if let moveId = loaded.activeMoveId {
                await monitorMove(moveId, projectId: projectId)
            } else {
                move = nil
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseLocation(projectId: String) async {
        guard let storage else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard await panel.selectionResponse == .OK, let url = panel.url else { return }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let created = try await store.daemon.replaceProjectStorage(
                .init(
                    projectId: projectId,
                    selectedRootPath: url.path,
                    handoffBookmarkData: bookmark.base64EncodedString(),
                    expectedLocationRevision: storage.locationRevision
                )
            )
            move = created
            await monitorMove(created.moveId, projectId: projectId)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetLocation() async {
        confirmation = nil
        guard let storage, let projectId = store.activeProjectId else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let created = try await store.daemon.resetProjectStorage(
                .init(projectId: projectId, expectedLocationRevision: storage.locationRevision)
            )
            move = created
            await monitorMove(created.moveId, projectId: projectId)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearCache() async {
        confirmation = nil
        guard let storage, let projectId = store.activeProjectId else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            self.storage = try await store.daemon.clearProjectCache(
                .init(projectId: projectId, expectedLocationRevision: storage.locationRevision)
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func monitorMove(_ moveId: String, projectId: String) async {
        do {
            while !Task.isCancelled {
                let current = try await store.daemon.projectStorageMove(moveId)
                move = current
                if current.state.isTerminal {
                    if let moveError = current.errorMessage {
                        errorMessage = moveError
                    } else if current.state == .failed {
                        errorMessage = "The storage move failed."
                    }
                    storage = try await store.daemon.projectStorage(projectId)
                    return
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func availabilityLabel(_ availability: DaemonProjectStorageAvailability) -> String {
        switch availability {
        case .ready: "Ready"
        case .moving: "Moving"
        case .unavailable: "Unavailable"
        }
    }

    private func moveLabel(_ state: DaemonProjectStorageMoveState) -> String {
        switch state {
        case .preparing: "Preparing"
        case .materializing: "Copying cache"
        case .verifying: "Verifying"
        case .switching: "Switching location"
        case .cleaning: "Cleaning up"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    private static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

private extension NSOpenPanel {
    var selectionResponse: NSApplication.ModalResponse {
        get async {
            await withCheckedContinuation { continuation in
                begin { continuation.resume(returning: $0) }
            }
        }
    }
}
