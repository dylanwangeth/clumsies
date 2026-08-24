import AppKit
import SwiftUI

/// Content column: the agent activity this project has produced, newest first.
struct RecallSessionList: View {
    @ObservedObject var model: RecallModel

    var body: some View {
        Group {
            if model.sessions.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(
                        "Agent activity from bound projects appears here with user requests and recalled memory."
                    )
                )
            } else {
                List(selection: $model.selectedSessionId) {
                    ForEach(model.sessions) { session in
                        RecallSessionRow(session: session)
                            .tag(session.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            if model.isLoading && model.sessions.isEmpty {
                ProgressView()
            }
        }
    }
}

private struct RecallSessionRow: View {
    let session: RecallSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.activityDisplayTitle)
                .fontWeight(.medium)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(session.host.activityTitle)
                Text("\(session.tasks.count) request\(session.tasks.count == 1 ? "" : "s")")
                if let createdAt = session.createdAt {
                    Text("·")
                    Text(Self.date(createdAt))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private static func date(_ millis: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

/// Detail column: user requests and the memory the agent recalled for them.
struct RecallSessionDetail: View {
    @ObservedObject var model: RecallModel

    var body: some View {
        NavigationStack {
            Group {
                if let session = model.selectedSession {
                    if session.tasks.isEmpty {
                        ContentUnavailableView(
                            "No User Requests",
                            systemImage: "text.bubble",
                            description: Text("No user requests were found in this activity.")
                        )
                    } else {
                        taskList(session)
                            .navigationTitle("Activity")
                    }
                } else {
                    ContentUnavailableView(
                        "Select an Activity",
                        systemImage: "sidebar.left",
                        description: Text("Choose an item to see its requests and recalled memory.")
                    )
                }
            }
        }
        .id(model.selectedSessionId)
    }

    private func taskList(_ session: RecallSession) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                RecallSessionSummary(session: session)

                ForEach(Array(session.tasks.enumerated()), id: \.element.id) { index, task in
                    Divider()
                    RecallTaskSection(
                        number: index + 1,
                        task: task,
                        workspaceRoot: session.workspaceRoot,
                        model: model
                    )
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct RecallSessionSummary: View {
    let session: RecallSession

    private var memorySearchCount: Int {
        session.tasks.reduce(0) { $0 + $1.activations.count }
    }

    private var recalledMemoryCount: Int {
        session.tasks.reduce(0) { taskTotal, task in
            taskTotal + task.activations.reduce(0) { $0 + $1.fragments.count }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.activityDisplayTitle)
                .font(.title2.weight(.semibold))
                .lineLimit(3)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Text(session.host.activityTitle)
                if let createdAt = session.createdAt {
                    Text("·")
                    Text(Self.date(createdAt))
                }
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Label(
                    "\(session.tasks.count) request\(session.tasks.count == 1 ? "" : "s")",
                    systemImage: "text.bubble"
                )
                Label(
                    "\(memorySearchCount) search\(memorySearchCount == 1 ? "" : "es")",
                    systemImage: "sparkle.magnifyingglass"
                )
                Label(
                    "\(recalledMemoryCount) memory chunk\(recalledMemoryCount == 1 ? "" : "s")",
                    systemImage: "doc.text"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
    }

    private static func date(_ millis: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private struct RecallTaskSection: View {
    let number: Int
    let task: RecallTask
    let workspaceRoot: String
    let model: RecallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Request \(number)")
                    .font(.headline)
                Spacer()
                if let time = task.time {
                    Text(Self.date(time))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Label("User request", systemImage: "person.crop.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(task.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if task.activations.isEmpty {
                Label(
                    "The agent did not ask Clumsies for memory while handling this request.",
                    systemImage: "brain"
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(task.activations) { activation in
                    RecallActivationRow(
                        activation: activation,
                        workspaceRoot: workspaceRoot,
                        model: model
                    )
                }
            }
        }
        .padding(.vertical, 24)
    }

    private static func date(_ millis: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
            .formatted(date: .omitted, time: .shortened)
    }
}

private struct RecallActivationRow: View {
    let activation: RecallActivation
    let workspaceRoot: String
    let model: RecallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label("Memory search", systemImage: "sparkle.magnifyingglass")
                    .fontWeight(.medium)
                Spacer()
                if let status = Self.visibleStatusTitle(activation.runStatus) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status == "Failed" ? Color.orange : Color.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Agent query")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(activation.query)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = activation.resultError {
                Label("Memory search failed", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                DisclosureGroup("Show technical details") {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
                .font(.caption)
            }

            if activation.fragments.isEmpty {
                Label(
                    "No matching memory chunks were returned.",
                    systemImage: "doc.text.magnifyingglass"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("\(activation.fragments.count) Result\(activation.fragments.count == 1 ? "" : "s")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    ForEach(activation.fragments) { fragment in
                        RecallFragmentRow(
                            fragment: fragment,
                            workspaceRoot: workspaceRoot,
                            runId: activation.runId,
                            model: model
                        )
                    }
                }
            }
        }
    }

    private static func visibleStatusTitle(_ status: String?) -> String? {
        switch status?.lowercased() {
        case nil, "succeeded", "success", "completed": nil
        case "running": "Searching"
        case "failed", "error": "Failed"
        case let status?: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

private struct RecallFragmentRow: View {
    let fragment: RecallFragment
    let workspaceRoot: String
    let runId: String?
    let model: RecallModel

    var body: some View {
        GroupBox {
            NavigationLink {
                RecallFragmentDetail(
                    fragment: fragment,
                    workspaceRoot: workspaceRoot,
                    runId: runId,
                    model: model
                )
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(fragment.displayTitle)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        Text(fragment.locationTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(fragment.preview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 8) {
                            Text(fragment.scopeTitle)
                            if let finalRank = fragment.finalRank {
                                Text("Result \(finalRank)")
                            }
                            if let deliveryTitle = fragment.nonDefaultDeliveryTitle {
                                Text(deliveryTitle)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(runId == nil ? "View recorded memory" : "View full recalled memory")
            .accessibilityLabel("Open recalled memory from \(fragment.path)")
        }
    }
}

private struct RecallFragmentDetail: View {
    let fragment: RecallFragment
    let workspaceRoot: String
    let runId: String?
    let model: RecallModel
    @State private var fullFragment: RecallFragment?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var displayedFragment: RecallFragment {
        fullFragment ?? fragment
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(displayedFragment.displayTitle)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Text(displayedFragment.locationTitle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if !displayedFragment.headingPath.isEmpty {
                    Text(displayedFragment.headingPath.joined(separator: " › "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Text(displayedFragment.scopeTitle)
                    if let finalRank = displayedFragment.finalRank {
                        Text("Result \(finalRank)")
                    }
                    if let deliveryTitle = displayedFragment.deliveryTitle {
                        Text(deliveryTitle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let explanation = displayedFragment.deliveryExplanation {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            if fullFragment?.truncated == true {
                recordedPreview(
                    "Only the recorded preview is available for this description-only result."
                )
            } else if fullFragment != nil {
                fullContent
            } else if runId == nil {
                recordedPreview(
                    "This older activity does not link to a saved retrieval run, so only its recorded content is available."
                )
            } else if isLoading {
                recordedPreview("Loading the full memory chunk…", showsProgress: true)
            } else if let errorMessage {
                recordedPreview(errorMessage, showsRetry: true)
            } else {
                recordedPreview("Loading the full memory chunk…", showsProgress: true)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(displayedFragment.displayTitle)
        .task {
            await loadFullFragment()
        }
    }

    @ViewBuilder
    private var fullContent: some View {
        if displayedFragment.content.isEmpty {
            ContentUnavailableView(
                "Memory Chunk Is Empty",
                systemImage: "doc.text",
                description: Text("This recalled chunk has no text content.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MarkdownPreview(source: displayedFragment.content)
        }
    }

    private func recordedPreview(
        _ message: String,
        showsProgress: Bool = false,
        showsRetry: Bool = false
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: showsRetry ? "exclamationmark.triangle" : "info.circle")
                        .foregroundStyle(showsRetry ? Color.orange : Color.secondary)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                if showsRetry {
                    Button("Try Again") {
                        Task { await loadFullFragment() }
                    }
                }
            }
            .padding(12)

            Divider()

            if displayedFragment.content.isEmpty {
                ContentUnavailableView(
                    "No Recorded Preview",
                    systemImage: "doc.text",
                    description: Text(displayedFragment.emptyContentExplanation)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarkdownPreview(source: displayedFragment.content)
            }
        }
    }

    private func loadFullFragment() async {
        guard fullFragment == nil, !isLoading, let runId else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            fullFragment = try await model.loadFragment(
                workspaceRoot: workspaceRoot,
                runId: runId,
                unitKey: fragment.unitKey
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Couldn’t load the full chunk. The recorded preview is shown below."
        }
    }
}

extension RecallFragment {
    var displayTitle: String {
        headingPath.last ?? (path as NSString).lastPathComponent
    }

    var locationTitle: String {
        path
    }

    var deliveryTitle: String? {
        switch action?.lowercased() {
        case "add": "Sent to agent"
        case "replace": "Updated for agent"
        case "reuse": "Already available"
        default: nil
        }
    }

    var deliveryExplanation: String? {
        switch action?.lowercased() {
        case "add": "This memory chunk was newly sent to the agent for this request."
        case "replace": "A newer version of this memory chunk replaced the version the agent already had."
        case "reuse": "The agent already had this unchanged memory chunk, so Clumsies did not need to send it again."
        default: nil
        }
    }

    fileprivate var nonDefaultDeliveryTitle: String? {
        action?.lowercased() == "add" ? nil : deliveryTitle
    }

    fileprivate var preview: String {
        content.isEmpty ? emptyContentExplanation : content
    }

    fileprivate var emptyContentExplanation: String {
        action?.lowercased() == "reuse"
            ? "The agent already had this unchanged memory chunk, so its text was not sent again."
            : "The full text was not preserved in this activity record."
    }

    fileprivate var scopeTitle: String {
        switch scope {
        case .org?: "Shared memory"
        case .project?: "Project memory"
        case nil: "Memory"
        }
    }
}

extension RecallSession {
    var activityDisplayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return tasks.lazy
            .map(\.text)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? "Agent activity"
    }
}

private extension AgentRunHost {
    var activityTitle: String {
        switch self {
        case .codex: "Codex"
        case .dsh: "DSH"
        case .claudeCode: "Claude Code"
        case .opencode: "OpenCode"
        case .antigravity: "Antigravity"
        case .manual: "Manual"
        case .zed: "Zed"
        case .unknown: "Unknown"
        }
    }
}
