import AppKit
import SwiftUI

struct NativeSettingsView: View {
    @ObservedObject var store: WorkspaceStore
    let softwareUpdateController: SoftwareUpdateController

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section("Application") {
                LabeledContent("Version", value: version)
                Button("Check for Updates...") { softwareUpdateController.checkForUpdates() }
            }
            Section("Connection") {
                LabeledContent("Server", value: store.runtime?.health.serverUrl ?? "Unavailable")
                LabeledContent("Project", value: store.activeProject?.name ?? "Not selected")
                LabeledContent("Organization", value: store.organization?.name ?? "Unavailable")
            }
            Section("Local Runtime") {
                LabeledContent("Draft synchronization", value: "Automatic")
                LabeledContent("Background service", value: "LaunchAgent")
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
