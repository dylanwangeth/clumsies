import Foundation

@MainActor
final class RecallModel: ObservableObject {
    @Published private(set) var sessions: [RecallSession] = []
    @Published var selectedSessionId: String?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let daemon: DaemonXPCClient

    init(daemon: DaemonXPCClient) {
        self.daemon = daemon
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await daemon.listRecalls(ListRecallsRequest())
            sessions = response.sessions
            if selectedSessionId == nil || !sessions.contains(where: { $0.id == selectedSessionId }) {
                selectedSessionId = sessions.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var selectedSession: RecallSession? {
        sessions.first { $0.id == selectedSessionId }
    }

    func loadFragment(
        workspaceRoot: String,
        runId: String,
        unitKey: String
    ) async throws -> RecallFragment {
        try await daemon.recallFragment(
            GetRecallFragmentRequest(
                workspaceRoot: workspaceRoot,
                runId: runId,
                unitKey: unitKey
            )
        ).fragment
    }
}
