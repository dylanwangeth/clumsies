import AppKit
import MarkdownUI
import SwiftUI

enum IssueBoardLayout {
    static let workspaceMinimumWidth: CGFloat = 920
    static let columnWidth: CGFloat = 268
    static let columnSpacing: CGFloat = 12
    static let cardSpacing: CGFloat = 10

    static var boardContentWidth: CGFloat {
        CGFloat(IssueBoardState.allCases.count) * columnWidth
            + CGFloat(IssueBoardState.allCases.count - 1) * columnSpacing
    }

    static func minimumContentHeight(for viewportHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight)
    }

    static func minimumContentWidth(for viewportWidth: CGFloat) -> CGFloat {
        max(boardContentWidth, viewportWidth)
    }
}

private enum IssueBoardSurface {
    static let background = Color(nsColor: .windowBackgroundColor)
}

enum IssueBoardPresentation {
    static func showsUnlinkedActivity(
        activeProjectId: String?,
        responseProjectId: String?,
        runCount: Int
    ) -> Bool {
        guard let activeProjectId else { return false }
        return responseProjectId == activeProjectId && runCount > 0
    }
}

enum IssueTiming {
    static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    static func absoluteText(_ value: String?) -> String? {
        guard let date = date(from: value) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func relativeText(_ value: String?, relativeTo now: Date) -> String? {
        guard let date = date(from: value) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

struct IssueExternalReferenceCardItem: Equatable {
    let kind: IssueExternalReferenceKind
    let title: String
    let reference: IssueExternalReference
}

struct IssueExternalReferenceCardPresentation: Equatable {
    let items: [IssueExternalReferenceCardItem]
    let remainingCount: Int

    var accessibilityLabel: String? {
        var values = items.map(\.title)
        if remainingCount > 0 {
            values.append("+\(remainingCount) more")
        }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }
}

enum IssueExternalReferencePresentation {
    static let maximumVisibleCardReferences = 2
    static let maximumCardTargetLength = 38
    static let maximumMenuTargetLength = 64

    static func cardPresentation(
        for references: [IssueExternalReference]
    ) -> IssueExternalReferenceCardPresentation {
        let items = references.prefix(maximumVisibleCardReferences).map { reference in
            let target = compactTarget(
                for: reference,
                maximumLength: maximumCardTargetLength
            )
            return IssueExternalReferenceCardItem(
                kind: reference.kind,
                title: "\(reference.kind.shortTitle) · \(target)",
                reference: reference
            )
        }
        return IssueExternalReferenceCardPresentation(
            items: Array(items),
            remainingCount: max(0, references.count - maximumVisibleCardReferences)
        )
    }

    static func menuLabel(for reference: IssueExternalReference) -> String {
        let target = compactTarget(
            for: reference,
            maximumLength: maximumMenuTargetLength,
            includesURLDetails: true
        )
        return "\(reference.kind.title) · \(target)"
    }

    static func destinationURL(for reference: IssueExternalReference) -> URL? {
        guard let components = URLComponents(string: reference.url),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else {
            return nil
        }
        return components.url
    }

    private static func compactTarget(
        for reference: IssueExternalReference,
        maximumLength: Int,
        includesURLDetails: Bool = false
    ) -> String {
        guard let components = URLComponents(string: reference.url),
              let host = components.host, !host.isEmpty else {
            return "Link"
        }

        let pathComponents = components.path
            .split(separator: "/")
            .map { component in
                String(component).removingPercentEncoding ?? String(component)
            }
        var target: String
        if host.lowercased() == "github.com",
           pathComponents.count >= 4,
           pathComponents[2] == "issues" || pathComponents[2] == "pull" {
            target = "\(pathComponents[0])/\(pathComponents[1])#\(pathComponents[3])"
        } else if !pathComponents.isEmpty {
            target = "\(host)/\(pathComponents.joined(separator: "/"))"
        } else {
            target = host
        }
        if includesURLDetails {
            var details = ""
            if let query = components.query, !query.isEmpty {
                details += "?\(query)"
            }
            if let fragment = components.fragment, !fragment.isEmpty {
                details += "#\(fragment)"
            }
            if !details.isEmpty {
                let compactDetails = truncatedMiddle(
                    details,
                    maximumLength: min(24, maximumLength / 2)
                )
                let baseLength = maximumLength - compactDetails.count - 3
                return "\(truncatedMiddle(target, maximumLength: baseLength)) · \(compactDetails)"
            }
        }
        return truncatedMiddle(target, maximumLength: maximumLength)
    }

    private static func truncatedMiddle(_ value: String, maximumLength: Int) -> String {
        guard value.count > maximumLength else { return value }
        let prefixLength = (maximumLength - 1) / 2
        let suffixLength = maximumLength - prefixLength - 1
        return "\(value.prefix(prefixLength))…\(value.suffix(suffixLength))"
    }
}

struct IssueExternalReferenceFilterMenu: View {
    @ObservedObject var model: IssueBoardModel

    var body: some View {
        Menu {
            Toggle("Has external Issue", isOn: $model.showsExternalIssuesOnly)
            Toggle("Has pull request", isOn: $model.showsPullRequestsOnly)

            if model.hasExternalReferenceFilters {
                Divider()
                Button("Clear Link Filters") {
                    model.clearExternalReferenceFilters()
                }
            }
        } label: {
            Label(
                "External Links",
                systemImage: model.hasExternalReferenceFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .help("Filter Kanban by external links")
        .disabled(model.response == nil)
        .accessibilityLabel("External Link Filters")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        switch (model.showsExternalIssuesOnly, model.showsPullRequestsOnly) {
        case (true, true): "External Issues and pull requests"
        case (true, false): "External Issues"
        case (false, true): "Pull requests"
        case (false, false): "No link filters"
        }
    }
}

private extension IssueExternalReferenceKind {
    var title: String {
        switch self {
        case .issue: "Issue"
        case .pullRequest: "Pull Request"
        }
    }

    var symbolName: String {
        switch self {
        case .issue: "exclamationmark.circle"
        case .pullRequest: "arrow.triangle.branch"
        }
    }

    var shortTitle: String {
        switch self {
        case .issue: "Issue"
        case .pullRequest: "PR"
        }
    }
}

struct IssueBoardView: View {
    @ObservedObject var model: IssueBoardModel
    let projectId: String?
    let projectName: String?
    let onOpenDetails: (IssueBoardCard) -> Void
    @State private var selectedIssueId: String?
    @State private var mutatingIssueId: String?
    @State private var showsDiagnostics = false
    @State private var mutationError: String?
    @State private var pendingDeletion: IssueBoardCard?

    var body: some View {
        boardContent
            .background(IssueBoardSurface.background)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: projectId) {
                await model.poll(projectId: projectId)
            }
            .onChange(of: projectId) {
                selectedIssueId = nil
                mutatingIssueId = nil
                showsDiagnostics = false
            }
            .alert(
                "Couldn’t Update Issue",
                isPresented: Binding(
                    get: { mutationError != nil },
                    set: { if !$0 { mutationError = nil } }
                )
            ) {
                Button("OK") { mutationError = nil }
            } message: {
                Text(mutationError ?? "")
            }
            .alert(
                "Delete \(pendingDeletion?.issueKey ?? "Issue")?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { issue in
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
                Button("Delete", role: .destructive) {
                    pendingDeletion = nil
                    remove(.delete, issue: issue)
                }
            } message: { issue in
                Text("This permanently deletes \(issue.issueKey). AgentRun telemetry is retained without an Issue link.")
            }
    }

    @ViewBuilder
    private var boardContent: some View {
        if projectId == nil {
            noProjectView
        } else if let response = model.response,
                  response.projectId == projectId {
            loadedView(response)
        } else if let refreshError = model.refreshError {
            unavailableView(message: refreshError)
        } else {
            loadingView
        }
    }

    private var noProjectView: some View {
        ContentUnavailableView {
            Label("Select a Project", systemImage: "folder")
        } description: {
            Text("Choose a project from the toolbar filter to view its Issues.")
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading Issues…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableView(message: String) -> some View {
        ContentUnavailableView {
            Label("Issues Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await model.refresh() }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func loadedView(_ response: IssueBoardResponse) -> some View {
        VStack(spacing: 0) {
            if let refreshError = model.refreshError {
                refreshFailureBanner(message: refreshError)
                Divider()
            }

            if !response.diagnostics.isEmpty {
                diagnosticsBanner(response.diagnostics)
                Divider()
            }

            if response.issues.isEmpty {
                ContentUnavailableView {
                    Label("No Issues", systemImage: "rectangle.3.group")
                } description: {
                    Text("Tell your Agent what should be tracked. It can create a native Todo through the Issue tool.")
                }
            } else {
                board(response)
            }
        }
    }

    private func refreshFailureBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn’t refresh Issues")
                    .fontWeight(.medium)
                Text("Showing the last successful board. \(message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(message)
            }
            Spacer(minLength: 12)
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing Issues")
            } else {
                Button("Try Again") {
                    Task { await model.refresh() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func diagnosticsBanner(_ diagnostics: [IssueBoardDiagnostic]) -> some View {
        HStack {
            Button {
                showsDiagnostics.toggle()
            } label: {
                Label(
                    diagnostics.count == 1
                        ? "1 Issue diagnostic"
                        : "\(diagnostics.count) Issue diagnostics",
                    systemImage: "exclamationmark.triangle"
                )
            }
            .buttonStyle(.plain)
            .help("Show Issue diagnostics")
            .popover(isPresented: $showsDiagnostics, arrowEdge: .top) {
                IssueDiagnosticsPopover(diagnostics: diagnostics)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func board(_ response: IssueBoardResponse) -> some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyHStack(alignment: .top, spacing: IssueBoardLayout.columnSpacing) {
                    ForEach(IssueBoardState.allCases, id: \.self) { state in
                        IssueBoardColumn(
                            state: state,
                            issues: model.issues(in: state),
                            selectedIssueId: $selectedIssueId,
                            mutatingIssueId: mutatingIssueId,
                            onOpenDetails: openDetails,
                            onCopyIssueId: copyIssueId,
                            onOpenExternalReference: openExternalReference,
                            onCopyExternalReference: copyExternalReference,
                            onGate: applyGate,
                            onArchive: { remove(.archive, issue: $0) },
                            onDelete: { pendingDeletion = $0 }
                        )
                    }
                }
                .padding(16)
                .frame(
                    minWidth: IssueBoardLayout.minimumContentWidth(
                        for: proxy.size.width
                    ),
                    minHeight: IssueBoardLayout.minimumContentHeight(
                        for: proxy.size.height
                    ),
                    alignment: .topLeading
                )
            }
        }
        .accessibilityLabel("\(projectName ?? "Project") Issue board")
    }

    private func applyGate(_ action: IssueGateAction, to issue: IssueBoardCard) {
        guard mutatingIssueId == nil else { return }
        mutatingIssueId = issue.id
        Task {
            defer { mutatingIssueId = nil }
            do {
                try await model.applyGate(action, to: issue)
            } catch {
                mutationError = error.localizedDescription
            }
        }
    }

    private func remove(_ action: IssueRemovalAction, issue: IssueBoardCard) {
        guard mutatingIssueId == nil else { return }
        mutatingIssueId = issue.id
        Task {
            defer { mutatingIssueId = nil }
            do {
                try await model.remove(action, issue: issue)
                if selectedIssueId == issue.id {
                    selectedIssueId = nil
                }
            } catch {
                mutationError = error.localizedDescription
            }
        }
    }

    private func copyIssueId(_ issue: IssueBoardCard) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issue.issueId, forType: .string)
    }

    private func openExternalReference(_ reference: IssueExternalReference) {
        guard let url = IssueExternalReferencePresentation.destinationURL(for: reference) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func copyExternalReference(_ reference: IssueExternalReference) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reference.url, forType: .string)
    }

    private func openDetails(_ issue: IssueBoardCard) {
        selectedIssueId = issue.id
        onOpenDetails(issue)
    }
}

struct IssueDetailView: View {
    let issueId: String
    @ObservedObject var model: IssueBoardModel
    var onGate: ((IssueGateAction, IssueBoardCard) -> Void)?
    var onArchive: ((IssueBoardCard) -> Void)?
    var onDelete: ((IssueBoardCard) -> Void)?

    private var issue: IssueBoardCard? {
        model.issues.first { $0.id == issueId }
    }

    var body: some View {
        Group {
            if let issue {
                issueContent(issue)
                    .task(id: issueId) {
                        await model.loadDetail(issue)
                    }
                    .navigationTitle(issue.issueKey)
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            gateMenu(issue)
                        }
                    }
            } else {
                ContentUnavailableView {
                    Label("Issue Unavailable", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("This Issue is no longer present on the current Kanban board.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IssueBoardSurface.background)
    }

    @ViewBuilder
    private func gateMenu(_ issue: IssueBoardCard) -> some View {
        Menu {
            switch issue.boardState {
            case .todo, .inProgress, .paused:
                EmptyView()
            case .closureRequested:
                Button("Approve Closure", systemImage: "checkmark.circle") {
                    onGate?(.approveClosure, issue)
                }
                Button("Request Changes", systemImage: "arrow.uturn.backward.circle") {
                    onGate?(.requestChanges, issue)
                }
            case .done:
                Button("Reopen", systemImage: "arrow.counterclockwise") {
                    onGate?(.reopen, issue)
                }
                if let onArchive {
                    Button("Archive", systemImage: "archivebox") {
                        onArchive(issue)
                    }
                }
            }
            if let onDelete {
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    onDelete(issue)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func issueContent(_ issue: IssueBoardCard) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(issue.title)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        Label(issue.boardState.title, systemImage: issue.boardState.symbolName)
                            .foregroundStyle(issue.boardState.iconColor)
                        if let started = issue.startedAt,
                           let relative = IssueTiming.relativeText(started, relativeTo: .now)
                        {
                            Text("·").foregroundStyle(.tertiary)
                            Text(relative).foregroundStyle(.secondary)
                        }
                        if issue.isStale {
                            Text("·").foregroundStyle(.tertiary)
                            Text("Stale").foregroundStyle(.orange)
                        }
                        if issue.blocked {
                            Text("·").foregroundStyle(.tertiary)
                            Text("Blocked").foregroundStyle(.red)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)

                    if !issue.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Markdown(issue.description)
                            .markdownTheme(.basic)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let detail = model.detail(for: issue),
                       !detail.acceptanceCriteria.isEmpty
                    {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(detail.acceptanceCriteria.enumerated()), id: \.offset) { _, criteria in
                                Text("•  \(criteria)")
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if let summary = issue.closureSummary, !summary.isEmpty {
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 48)
            }

            IssueDetailInspector(issue: issue, detail: model.detail(for: issue))
                .frame(width: 240)
                .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

private struct IssueBoardColumn: View {
    let state: IssueBoardState
    let issues: [IssueBoardCard]
    @Binding var selectedIssueId: String?
    let mutatingIssueId: String?
    let onOpenDetails: (IssueBoardCard) -> Void
    let onCopyIssueId: (IssueBoardCard) -> Void
    let onOpenExternalReference: (IssueExternalReference) -> Void
    let onCopyExternalReference: (IssueExternalReference) -> Void
    let onGate: (IssueGateAction, IssueBoardCard) -> Void
    let onArchive: (IssueBoardCard) -> Void
    let onDelete: (IssueBoardCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: state.symbolName)
                    .foregroundStyle(state.iconColor)
                Text(state.title)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(issues.count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(issues.count) Issues")
            }
            .padding(.horizontal, 4)

            Divider()

            if issues.isEmpty {
                Text("No Issues")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .center)
            } else {
                VStack(spacing: IssueBoardLayout.cardSpacing) {
                    ForEach(issues) { issue in
                        Button {
                            selectedIssueId = issue.id
                        } label: {
                            IssueCard(
                                issue: issue,
                                isSelected: selectedIssueId == issue.id,
                                isMutating: mutatingIssueId == issue.id
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            TapGesture(count: 2)
                                .onEnded { onOpenDetails(issue) }
                        )
                        .focusable()
                        .help("\(issue.issueKey): \(issue.title). Double-click to view details.")
                        .accessibilityIdentifier("issue-card-\(issue.issueKey)")
                        .accessibilityLabel(accessibilityLabel(for: issue))
                        .accessibilityAction(named: "View Details") {
                            onOpenDetails(issue)
                        }
                        .contextMenu {
                            Button("View Details", systemImage: "doc.text.magnifyingglass") {
                                onOpenDetails(issue)
                            }

                            Button("Copy Issue ID", systemImage: "doc.on.doc") {
                                onCopyIssueId(issue)
                            }

                            if !issue.externalReferences.isEmpty {
                                Menu {
                                    ForEach(
                                        Array(issue.externalReferences.enumerated()),
                                        id: \.offset
                                    ) { _, reference in
                                        Menu {
                                            Button("Open", systemImage: "arrow.up.forward.app") {
                                                onOpenExternalReference(reference)
                                            }
                                            .disabled(
                                                IssueExternalReferencePresentation
                                                    .destinationURL(for: reference) == nil
                                            )

                                            Button("Copy Link", systemImage: "doc.on.doc") {
                                                onCopyExternalReference(reference)
                                            }
                                        } label: {
                                            Label(
                                                IssueExternalReferencePresentation
                                                    .menuLabel(for: reference),
                                                systemImage: reference.kind.symbolName
                                            )
                                        }
                                    }
                                } label: {
                                    Label("External Links", systemImage: "link")
                                }
                            }

                            Divider()

                            switch issue.boardState {
                            case .todo, .inProgress, .paused:
                                deleteButton(issue)
                            case .closureRequested:
                                Button("Approve Closure", systemImage: "checkmark.circle") {
                                    onGate(.approveClosure, issue)
                                }
                                Button("Request Changes", systemImage: "arrow.uturn.backward.circle") {
                                    onGate(.requestChanges, issue)
                                }
                                Divider()
                                deleteButton(issue)
                            case .done:
                                Button("Reopen", systemImage: "arrow.counterclockwise") {
                                    onGate(.reopen, issue)
                                }
                                Button("Archive", systemImage: "archivebox") {
                                    onArchive(issue)
                                }
                            }
                        }
                        .disabled(mutatingIssueId != nil)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: IssueBoardLayout.columnWidth, alignment: .topLeading)
    }

    private func deleteButton(_ issue: IssueBoardCard) -> some View {
        Button(role: .destructive) {
            onDelete(issue)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func accessibilityLabel(for issue: IssueBoardCard) -> String {
        var values = [issue.issueKey, issue.title, state.title]
        if let references = IssueExternalReferencePresentation
            .cardPresentation(for: issue.externalReferences)
            .accessibilityLabel {
            values.append(references)
        }
        if issue.blocked {
            values.append("blocked by unresolved dependencies or conditions")
        }
        return values.joined(separator: ", ")
    }
}

private struct IssueCard: View {
    let issue: IssueBoardCard
    let isSelected: Bool
    let isMutating: Bool
    @State private var isHovering = false

    var body: some View {
        let externalReferences = IssueExternalReferencePresentation.cardPresentation(
            for: issue.externalReferences
        )

        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(issue.issueKey)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if isMutating {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Updating \(issue.issueKey)")
                }
                if issue.isStale {
                    Label("Stale", systemImage: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("No active AgentRun and no activity for more than 24 hours")
                }
                if issue.blocked {
                    Label("Blocked", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .help(blockingReasonHelpText(issue))
                }
            }

            Text(issue.title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .help(issue.title)

            if !issue.descriptionExcerpt.isEmpty {
                Text(issue.descriptionExcerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .help(issue.description)
            }

            if !externalReferences.items.isEmpty {
                IssueExternalReferencesSummary(presentation: externalReferences)
            }

            IssueTimingSummary(issue: issue)

            if !issue.activeRuns.isEmpty {
                Divider()
                ForEach(Array(issue.activeRuns.prefix(3))) { run in
                    AgentRunRow(run: run)
                }
                if issue.activeRuns.count > 3 {
                    Text("\(issue.activeRuns.count - 3) more active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let latestRun = issue.latestRun {
                Divider()
                AgentRunRow(run: latestRun)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    borderColor,
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var borderColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.75)
        }
        if isHovering {
            return Color.accentColor.opacity(0.45)
        }
        return Color(nsColor: .separatorColor)
    }

    private func blockingReasonHelpText(_ issue: IssueBoardCard) -> String {
        let reasons = issue.blockingReasons.map { reason in
            switch reason.kind {
            case .dependency:
                "depends on \(reason.issueKey ?? "another Issue") (\(reason.boardState?.title ?? "unknown"))"
            case .fact:
                reason.description ?? "an external condition is unsatisfied"
            }
        }
        return reasons.isEmpty
            ? "Blocked by unresolved dependencies or conditions"
            : reasons.joined(separator: "; ")
    }

}

private struct IssueExternalReferencesSummary: View {
    let presentation: IssueExternalReferenceCardPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(presentation.items.enumerated()), id: \.offset) { _, item in
                if let url = IssueExternalReferencePresentation.destinationURL(for: item.reference) {
                    ExternalLinkText(
                        url: url,
                        title: item.title,
                        systemImage: item.kind.symbolName
                    )
                    .font(.caption2)
                } else {
                    Label(item.title, systemImage: item.kind.symbolName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if presentation.remainingCount > 0 {
                Text("+\(presentation.remainingCount)")
                    .padding(.leading, 18)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel ?? "")
    }
}

private struct IssueTimingSummary: View {
    let issue: IssueBoardCard

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(milestones(relativeTo: context.date).enumerated()), id: \.offset) { _, milestone in
                    Label(milestone.label, systemImage: milestone.symbol)
                        .help(milestone.help)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func milestones(relativeTo now: Date) -> [(label: String, symbol: String, help: String)] {
        let values: [(value: String?, prefix: String, symbol: String)]
        switch issue.boardState {
        case .todo:
            values = [(issue.createdAt, "Created", "calendar.badge.plus")]
        case .inProgress, .paused, .closureRequested:
            values = [(issue.startedAt, "Opened", "play.circle")]
        case .done:
            values = [
                (issue.startedAt, "Opened", "play.circle"),
                (issue.closedAt, "Closed", "checkmark.circle")
            ]
        }
        return values.compactMap { milestone in
            guard let relative = IssueTiming.relativeText(milestone.value, relativeTo: now) else {
                return nil
            }
            return (
                "\(milestone.prefix) \(relative)",
                milestone.symbol,
                IssueTiming.absoluteText(milestone.value) ?? ""
            )
        }
    }
}

private struct AgentRunRow: View {
    let run: AgentRun

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: run.kind.symbolName)
                    .foregroundStyle(.secondary)
                Text(run.displayName)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Label(run.statusTitle, systemImage: run.statusSymbolName)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(run.statusColor)
                    .lineLimit(1)
            }
            .font(.caption)

            if let summary = run.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(summary)
            }
        }
        .help(run.helpText)
    }
}

private struct UnlinkedAgentRunRow: View {
    let run: AgentRun

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(run.displayName)
                .lineLimit(1)
            HStack(spacing: 5) {
                Image(systemName: run.statusSymbolName)
                    .foregroundStyle(run.statusColor)
                Text(run.statusTitle)
                Text("·")
                Text(run.host.title)
                if run.kind == .subagent {
                    Text("· Subagent")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .help(run.helpText)
        .accessibilityElement(children: .combine)
    }
}

struct IssueUnlinkedActivityPopover: View {
    let runs: [AgentRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Unlinked Activity")
                .font(.headline)
                .padding(14)

            Divider()

            List(runs) { run in
                UnlinkedAgentRunRow(run: run)
                    .padding(.vertical, 3)
            }
        }
        .frame(width: 360, height: 280)
    }
}

struct IssueWorkflowHelpPopover: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("How Issues move")
                    .font(.title3.weight(.semibold))

                GroupBox("You") {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Describe needs and feedback to your Agent in natural language.", systemImage: "text.bubble")
                        Label("Double-click a card, or choose View Details from its menu, to read it.", systemImage: "doc.text.magnifyingglass")
                        Label("Right-click a card to copy its ID or perform an allowed gate action.", systemImage: "checkmark.shield")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Agents via MCP") {
                    VStack(alignment: .leading, spacing: 8) {
                        workflowStep("kanban.list", detail: "Read this Project’s titles and descriptions before choosing an Issue.")
                        workflowStep("kanban.create", detail: "Capture durable work as a native Todo Issue.")
                        workflowStep("kanban.update", detail: "Maintain structured Issue meaning from user feedback.")
                        workflowStep("kanban.begin_work", detail: "Link the hook-provided run_id to an Issue after a semantic decision.")
                        workflowStep("kanban.request_closure", detail: "Ask for closure only after judging the acceptance criteria satisfied.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Label(
                    "A Stop hook ends an AgentRun; it never requests, approves, or closes an Issue by itself.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .frame(width: 430, height: 430)
    }

    private func workflowStep(_ command: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(command)
                .font(.callout.monospaced().weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct IssueDiagnosticsPopover: View {
    let diagnostics: [IssueBoardDiagnostic]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Issue Diagnostics")
                .font(.headline)
                .padding(14)

            Divider()

            List(diagnostics) { diagnostic in
                VStack(alignment: .leading, spacing: 4) {
                    Text(diagnostic.message)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(diagnostic.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(diagnostic.path)
                }
                .padding(.vertical, 3)
            }
        }
        .frame(width: 420, height: 280)
    }
}

extension IssueBoardState {
    var title: String {
        switch self {
        case .todo: "Todo"
        case .inProgress: "In Progress"
        case .paused: "Paused"
        case .closureRequested: "Closure Requested"
        case .done: "Done"
        }
    }

    var symbolName: String {
        switch self {
        case .todo: "circle"
        case .inProgress: "bolt.circle"
        case .paused: "pause.circle"
        case .closureRequested: "checkmark.circle"
        case .done: "checkmark.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .inProgress: .accentColor
        case .paused: .orange
        case .done: .green
        case .todo, .closureRequested: .secondary
        }
    }
}

private extension AgentRunHost {
    var title: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .manual: "Manual"
        case .zed: "Zed"
        case .opencode: "opencode"
        }
    }
}

private extension AgentRunKind {
    var symbolName: String {
        switch self {
        case .root: "person.crop.circle"
        case .subagent: "arrow.turn.down.right"
        }
    }
}

private extension AgentRun {
    var displayName: String {
        if let displayLabel = displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayLabel.isEmpty {
            return displayLabel
        }
        return kind == .root ? host.title : "\(host.title) subagent"
    }

    var statusTitle: String {
        if phase == .running { return "Running" }
        return switch outcome {
        case .completed: "Completed"
        case .blocked: "Blocked"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .unknown: "Unknown"
        case nil: "Ended"
        }
    }

    var statusSymbolName: String {
        if phase == .running { return "bolt.circle" }
        return switch outcome {
        case .completed: "checkmark.circle"
        case .blocked: "pause.circle"
        case .failed: "xmark.circle"
        case .cancelled: "slash.circle"
        case .unknown: "questionmark.circle"
        case nil: "stop.circle"
        }
    }

    var statusColor: Color {
        if phase == .running { return .accentColor }
        return switch outcome {
        case .failed: .red
        case .blocked, .cancelled, .unknown: .orange
        case .completed, nil: .secondary
        }
    }

    var helpText: String {
        var details = [host.title, kind == .root ? "Root run" : "Subagent", statusTitle]
        if let parentRunId, !parentRunId.isEmpty {
            details.append("Parent: \(parentRunId)")
        }
        return details.joined(separator: " · ")
    }
}


private struct IssueDetailInspector: View {
    let issue: IssueBoardCard
    let detail: IssueDetailResponse?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                timelineRow
                verificationRow
                activityRow
                referencesRow
            }
            .padding(16)
        }
    }

    private var statusRow: some View {
        inspectorRow(icon: issue.boardState.symbolName,
                     tint: issue.boardState.iconColor,
                     label: "Status",
                     value: issue.boardState.title)
    }

    @ViewBuilder
    private var timelineRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            inspectorLabel("Timeline")
            if let created = issue.createdAt {
                inspectorDate("Created", created)
            }
            if let started = issue.startedAt {
                inspectorDate("Started", started)
            }
            if let closed = issue.closedAt {
                inspectorDate("Closed", closed)
            }
        }
    }

    @ViewBuilder
    private var verificationRow: some View {
        if issue.verificationLevel != .agentSelf || !issue.verificationSteps.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                inspectorLabel("Verification")
                Label {
                    Text(verifLabel)
                } icon: {
                    Image(systemName: verifSymbol)
                }
                .foregroundStyle(verifColor)
                .font(.callout)
                ForEach(Array(issue.verificationSteps.enumerated()), id: \.offset) { i, step in
                    Text("\(i + 1). \(step)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var activityRow: some View {
        if !issue.activeRuns.isEmpty || issue.latestRun != nil {
            VStack(alignment: .leading, spacing: 4) {
                inspectorLabel("Activity")
                ForEach(Array(issue.activeRuns.prefix(3))) { run in
                    AgentRunRow(run: run)
                }
                if issue.activeRuns.isEmpty, let latest = issue.latestRun {
                    AgentRunRow(run: latest)
                }
                if issue.activeRuns.count > 3 {
                    Text("+\(issue.activeRuns.count - 3) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var referencesRow: some View {
        let refs = IssueExternalReferencePresentation.cardPresentation(for: issue.externalReferences)
        if !refs.items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                inspectorLabel("Linked")
                IssueExternalReferencesSummary(presentation: refs)
            }
        }
    }

    private func inspectorRow(icon: String, tint: Color, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                inspectorLabel(label)
                Text(value).font(.callout)
            }
            Spacer(minLength: 0)
        }
    }

    private func inspectorLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func inspectorDate(_ label: String, _ iso: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(IssueTiming.absoluteText(iso) ?? "—")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var verifLabel: String {
        switch issue.verificationLevel {
        case .agentSelf: "Agent self-verified"
        case .humanRequired: "Human required"
        case .mixed: "Mixed"
        }
    }
    private var verifSymbol: String {
        switch issue.verificationLevel {
        case .agentSelf: "checkmark.seal"
        case .humanRequired: "person.crop.circle.badge.questionmark"
        case .mixed: "checkmark.seal.fill"
        }
    }
    private var verifColor: Color {
        switch issue.verificationLevel {
        case .agentSelf: .green
        case .humanRequired: .orange
        case .mixed: .blue
        }
    }
}
