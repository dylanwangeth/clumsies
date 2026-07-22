import SwiftUI

struct NativeSettingsView: View {
    @ObservedObject var store: WorkspaceStore
    let softwareUpdateController: SoftwareUpdateController
    let onOpenDiagnostics: () -> Void

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
                Button("Open Daemon Diagnostics") { onOpenDiagnostics() }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}

struct NativeDiagnosticsView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Diagnostics")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Retry Sync") { Task { await store.retrySync() } }
            }
            .padding(20)
            Divider()
            Form {
                if let runtime = store.runtime {
                    LabeledContent("Daemon", value: runtime.health.daemonVersion)
                    LabeledContent("Project", value: runtime.health.projectId ?? "Not selected")
                    LabeledContent("Database", value: runtime.health.localDb.path)
                    LabeledContent("Schema", value: String(runtime.health.localDb.schemaVersion))
                    LabeledContent("Draft sync", value: runtime.sync.draftSync.state)
                    LabeledContent("Commit sync", value: runtime.sync.commitSync.state)
                    LabeledContent("Pending operations", value: String(runtime.sync.pendingOperationCount))
                    LabeledContent("Failed operations", value: String(runtime.sync.failedOperationCount))
                    LabeledContent("Drafts behind", value: String(runtime.sync.behindDraftCount))
                    LabeledContent(
                        "Reconciliation conflicts",
                        value: String(runtime.sync.reconciliationConflictCount)
                    )
                    LabeledContent("MCP", value: runtime.mcp.running ? "Running" : "Stopped")
                    LabeledContent("Server data", value: runtime.serverDataSource.capitalized)
                    LabeledContent("Logs", value: runtime.health.logDir)
                } else {
                    ProgressView()
                }
            }
            .formStyle(.grouped)
        }
    }
}
