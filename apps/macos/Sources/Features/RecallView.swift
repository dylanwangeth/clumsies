import SwiftUI

/// Content column: the sessions this project has produced, newest first.
struct RecallSessionList: View {
    @ObservedObject var model: RecallModel

    var body: some View {
        Group {
            if model.sessions.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    "No recalled sessions",
                    systemImage: "sparkle.magnifyingglass",
                    description: Text(
                        "After a coding session runs in this project, its tasks and the memories each task recalled appear here."
                    )
                )
            } else {
                List(selection: $model.selectedSessionId) {
                    ForEach(model.sessions) { session in
                        RecallSessionRow(session: session)
                            .tag(session.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
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
            Text(session.title ?? session.sessionId)
                .fontWeight(.medium)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("\(session.tasks.count) task\(session.tasks.count == 1 ? "" : "s")")
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

/// Detail column: the tasks in the selected session and, for each task, the
/// memories the agent recalled.
struct RecallSessionDetail: View {
    @ObservedObject var model: RecallModel

    var body: some View {
        Group {
            if let session = model.selectedSession {
                if session.tasks.isEmpty {
                    ContentUnavailableView(
                        "No tasks in this session",
                        systemImage: "text.bubble",
                        description: Text("This session has no recorded user prompts.")
                    )
                } else {
                    taskList(session)
                }
            } else {
                ContentUnavailableView(
                    "Select a session",
                    systemImage: "sidebar.left",
                    description: Text("Choose a session to see its tasks and the memories each task recalled.")
                )
            }
        }
    }

    private func taskList(_ session: RecallSession) -> some View {
        List {
            ForEach(session.tasks) { task in
                RecallTaskSection(task: task)
            }
        }
        .listStyle(.inset)
    }
}

private struct RecallTaskSection: View {
    let task: RecallTask

    var body: some View {
        Section {
            if task.activations.isEmpty {
                Text("No memory was activated for this task.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(task.activations) { activation in
                    RecallActivationRow(activation: activation)
                }
            }
        } header: {
            Text(task.text)
                .lineLimit(3)
                .textCase(nil)
        }
    }
}

private struct RecallActivationRow: View {
    let activation: RecallActivation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(.tint)
                Text(activation.query)
                    .fontWeight(.medium)
                    .textSelection(.enabled)
                Spacer()
                if let status = activation.runStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = activation.resultError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if activation.fragments.isEmpty {
                Text("No fragments were recalled for this activation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(activation.fragments) { fragment in
                    RecallFragmentRow(fragment: fragment)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RecallFragmentRow: View {
    let fragment: RecallFragment

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(fragment.path)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let action = fragment.action {
                    Text(action)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            Text(fragment.content)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(.leading, 22)
    }
}
