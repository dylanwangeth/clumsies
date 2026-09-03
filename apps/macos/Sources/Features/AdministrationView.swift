import SwiftUI

enum AdministrationSection: String, CaseIterable, Identifiable, Sendable {
    case overview
    case organization
    case members
    case projects
    case access
    case audit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .organization: "Organization"
        case .members: "Members"
        case .projects: "Projects"
        case .access: "Access"
        case .audit: "Audit"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .organization: "building.2"
        case .members: "person.2"
        case .projects: "folder"
        case .access: "key"
        case .audit: "list.bullet.clipboard"
        }
    }
}

struct AdministrationNavigator: View {
    @Binding var selection: AdministrationSection?

    var body: some View {
        List(selection: $selection) {
            ForEach(AdministrationSection.allCases) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
        }
        .navigationTitle("Administration")
    }
}

struct AdministrationView: View {
    @ObservedObject var store: WorkspaceStore
    let section: AdministrationSection

    var body: some View {
        VStack(spacing: 0) {
            if store.administrationSnapshot != nil, store.administrationIsStale {
                AdministrationStaleBanner()
            }

            if let errorMessage = store.administrationErrorMessage {
                AdministrationErrorBanner(message: errorMessage)
            }

            content
        }
        .navigationTitle(section.title)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.loadAdministration() }
                } label: {
                    if store.isLoadingAdministration {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isLoadingAdministration || store.isMutatingAdministration)
                .help("Refresh Administration")
                .accessibilityLabel("Refresh Administration")
            }
        }
        .task {
            if store.administrationSnapshot == nil {
                await store.loadAdministration()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = store.administrationSnapshot {
            switch section {
            case .overview:
                AdministrationOverviewView(snapshot: snapshot)
            case .organization:
                AdministrationOrganizationView(
                    store: store,
                    organization: snapshot.organization,
                    allowsMutation: store.canMutateAdministration
                )
            case .members:
                AdministrationMembersView(
                    store: store,
                    members: snapshot.members,
                    allowsMutation: store.canMutateAdministration
                )
            case .projects:
                AdministrationProjectsView(
                    store: store,
                    snapshot: snapshot,
                    allowsMutation: store.canMutateAdministration
                )
            case .access:
                AdministrationAccessView(
                    store: store,
                    snapshot: snapshot,
                    allowsMutation: store.canMutateAdministration
                )
            case .audit:
                AdministrationAuditView(
                    events: snapshot.auditEvents,
                    members: snapshot.members
                )
            }
        } else if store.isLoadingAdministration {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading Administration…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Administration Unavailable",
                systemImage: "building.2.crop.circle",
                description: Text(
                    store.canAdministerOrganization
                        ? "Refresh to load organization administration."
                        : "Organization administrator access is required."
                )
            )
        }
    }
}

private struct AdministrationStaleBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cached administration data")
                    .fontWeight(.semibold)
                Text("This data may be out of date. All administrative changes are disabled until a live refresh succeeds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

private struct AdministrationErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct AdministrationOverviewView: View {
    let snapshot: AdministrationSnapshot

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    AdministrationMetric(
                        title: "Members",
                        value: String(snapshot.members.count),
                        detail: "Organization directory",
                        symbol: "person.2"
                    )
                    AdministrationMetric(
                        title: "Projects",
                        value: String(snapshot.projects.count),
                        detail: "Across the organization",
                        symbol: "folder"
                    )
                    AdministrationMetric(
                        title: "Active credentials",
                        value: String(snapshot.tokens.filter { !$0.revoked }.count),
                        detail: "All credential types",
                        symbol: "key"
                    )
                    AdministrationMetric(
                        title: "Server",
                        value: "v\(snapshot.health.version)",
                        detail: snapshot.health.status.title,
                        symbol: "server.rack"
                    )
                }

                GroupBox {
                    VStack(spacing: 0) {
                        AdministrationHealthRow(title: "Database", check: snapshot.health.database)
                        Divider()
                        AdministrationHealthRow(title: "Schema", check: snapshot.health.schema)
                        Divider()
                        AdministrationHealthRow(title: "Commit service", check: snapshot.health.commitService)
                        Divider()
                        AdministrationHealthRow(title: "OIDC", check: snapshot.health.oidc)
                    }
                } label: {
                    Label("Service health", systemImage: "heart.text.square")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Organization", value: snapshot.organization.name)
                        LabeledContent(
                            "Identity provider",
                            value: snapshot.identityProvider.configured ? "Configured" : "Not configured"
                        )
                        if let issuer = snapshot.identityProvider.issuer {
                            LabeledContent("Issuer", value: issuer)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Deployment", systemImage: "network")
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

private struct AdministrationMetric: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        }
    }
}

private struct AdministrationHealthRow: View {
    let title: String
    let check: AdminHealthCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(check.status.tint)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(check.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(check.status.title)
                .font(.caption)
                .foregroundStyle(check.status.tint)
        }
        .padding(.vertical, 9)
    }
}

private struct AdministrationOrganizationView: View {
    @ObservedObject var store: WorkspaceStore
    let organization: AdminOrganizationRecord
    let allowsMutation: Bool
    @State private var name = ""
    @State private var domains = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Organization details") {
                TextField("Name", text: $name)
                Text("Revision \(organization.revision) · Updated \(organization.updatedAt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                TextEditor(text: $domains)
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                Text("Enter one domain per line or separate domains with commas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Allowed email domains")
            }

            Section {
                HStack {
                    Button("Save Organization") {
                        save()
                    }
                    .disabled(!canSave)

                    if store.isMutatingAdministration {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let errorMessage {
                    AdministrationInlineError(message: errorMessage)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: organization.revision) {
            name = organization.name
            domains = organization.allowedEmailDomains.joined(separator: "\n")
            errorMessage = nil
        }
    }

    private var canSave: Bool {
        allowsMutation
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let allowedDomains = domains
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        errorMessage = nil
        Task {
            do {
                try await store.updateAdminOrganization(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    allowedEmailDomains: Array(Set(allowedDomains)).sorted(),
                    expectedRevision: organization.revision
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AdministrationMembersView: View {
    @ObservedObject var store: WorkspaceStore
    let members: [AdminOrganizationMemberRecord]
    let allowsMutation: Bool
    @State private var query = ""
    @State private var showsInvite = false
    @State private var pendingDisable: AdminOrganizationMemberRecord?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search members", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button {
                    showsInvite = true
                } label: {
                    Label("Invite Member", systemImage: "person.badge.plus")
                }
                .disabled(!allowsMutation)
            }
            .padding(12)

            if let errorMessage {
                AdministrationInlineError(message: errorMessage)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Divider()

            if filteredMembers.isEmpty {
                ContentUnavailableView(
                    "No Members",
                    systemImage: "person.2.slash",
                    description: Text(query.isEmpty ? "Invite a member to get started." : "No members match this search.")
                )
            } else {
                List(filteredMembers) { member in
                    let isCurrentUser = member.id == store.account?.userId
                    let ownerIsLocked = store.account?.role != AdminOrganizationRole.owner.rawValue
                        && member.role == .owner
                    let canEditMember = allowsMutation && !isCurrentUser && !ownerIsLocked

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.displayName ?? member.email)
                                .fontWeight(.medium)
                            Text(member.email + (isCurrentUser ? " · You" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if member.externalIdentityBound {
                                Label("Identity linked", systemImage: "checkmark.seal")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if canEditMember {
                            Picker("Role", selection: roleBinding(for: member)) {
                                ForEach(assignableRoles) { role in
                                    Text(role.title).tag(role)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 105)
                        } else {
                            Text(member.role.title)
                                .frame(width: 105)
                        }

                        if canEditMember {
                            Picker("Status", selection: statusBinding(for: member)) {
                                ForEach(AdminMemberStatus.allCases) { status in
                                    Text(status.title).tag(status)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        } else {
                            Text(member.status.title)
                                .frame(width: 110)
                        }

                        Button(role: .destructive) {
                            pendingDisable = member
                        } label: {
                            Image(systemName: "person.crop.circle.badge.xmark")
                        }
                        .disabled(!canEditMember || member.status == .disabled)
                        .help("Disable Member and Revoke Sessions")
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .sheet(isPresented: $showsInvite) {
            AdministrationInviteMemberSheet(store: store)
        }
        .confirmationDialog(
            "Disable organization member?",
            isPresented: Binding(
                get: { pendingDisable != nil },
                set: { if !$0 { pendingDisable = nil } }
            ),
            presenting: pendingDisable
        ) { member in
            Button("Disable \(member.displayName ?? member.email)", role: .destructive) {
                mutate { try await store.disableAdminOrganizationMember(member) }
                pendingDisable = nil
            }
        } message: { member in
            Text("This disables \(member.email) and revokes all active sessions. Server policy remains authoritative.")
        }
    }

    private var assignableRoles: [AdminOrganizationRole] {
        var roles: [AdminOrganizationRole] = [.member, .admin]
        if store.account?.role == AdminOrganizationRole.owner.rawValue {
            roles.append(.owner)
        }
        return roles
    }

    private var filteredMembers: [AdminOrganizationMemberRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !needle.isEmpty else { return members }
        return members.filter {
            "\($0.displayName ?? "") \($0.email) \($0.role.rawValue) \($0.status.rawValue)"
                .localizedLowercase.contains(needle)
        }
    }

    private func roleBinding(for member: AdminOrganizationMemberRecord) -> Binding<AdminOrganizationRole> {
        Binding(
            get: { member.role },
            set: { role in
                guard role != member.role else { return }
                mutate { try await store.updateAdminOrganizationMember(member, role: role) }
            }
        )
    }

    private func statusBinding(for member: AdminOrganizationMemberRecord) -> Binding<AdminMemberStatus> {
        Binding(
            get: { member.status },
            set: { status in
                guard status != member.status else { return }
                mutate { try await store.updateAdminOrganizationMember(member, status: status) }
            }
        )
    }

    private func mutate(_ operation: @escaping () async throws -> Void) {
        guard allowsMutation else { return }
        errorMessage = nil
        Task {
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AdministrationInviteMemberSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: WorkspaceStore
    @State private var email = ""
    @State private var role: AdminOrganizationRole = .member
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                Picker("Organization role", selection: $role) {
                    ForEach(assignableRoles) { role in
                        Text(role.title).tag(role)
                    }
                }
                if let errorMessage {
                    AdministrationInlineError(message: errorMessage)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Invite") { invite() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canInvite)
            }
            .padding(12)
        }
        .frame(width: 430, height: 245)
    }

    private var canInvite: Bool {
        store.canMutateAdministration
            && email.contains("@")
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var assignableRoles: [AdminOrganizationRole] {
        var roles: [AdminOrganizationRole] = [.member, .admin]
        if store.account?.role == AdminOrganizationRole.owner.rawValue {
            roles.append(.owner)
        }
        return roles
    }

    private func invite() {
        errorMessage = nil
        Task {
            do {
                try await store.inviteAdminOrganizationMember(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    role: role
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AdministrationProjectsView: View {
    @ObservedObject var store: WorkspaceStore
    let snapshot: AdministrationSnapshot
    let allowsMutation: Bool
    @State private var selectedProjectId: String?
    @State private var showsCreation = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedProjectId) {
                    ForEach(snapshot.projects) { project in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .fontWeight(.medium)
                            Text("\(project.memberCount) members")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(project.id)
                        .padding(.vertical, 3)
                    }
                }

                Divider()
                Button {
                    showsCreation = true
                } label: {
                    Label("Create Project", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(12)
                .disabled(!allowsMutation)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

            if let project = selectedProject {
                AdministrationProjectEditor(
                    store: store,
                    project: project,
                    organizationMembers: snapshot.members,
                    allowsMutation: allowsMutation
                )
            } else {
                ContentUnavailableView(
                    snapshot.projects.isEmpty ? "No Projects" : "Select a Project",
                    systemImage: "folder",
                    description: Text(
                        snapshot.projects.isEmpty
                            ? "Create a server project without attaching a local repository."
                            : "Choose a project to edit its details and members."
                    )
                )
                .frame(minWidth: 440)
            }
        }
        .onAppear { selectAvailableProject() }
        .onChange(of: snapshot.projects.map(\.id)) { _, _ in selectAvailableProject() }
        .sheet(isPresented: $showsCreation) {
            AdministrationProjectCreationSheet(store: store) { projectId in
                selectedProjectId = projectId
            }
        }
    }

    private var selectedProject: AdminProjectRecord? {
        snapshot.projects.first { $0.id == selectedProjectId }
    }

    private func selectAvailableProject() {
        if let selectedProjectId,
           snapshot.projects.contains(where: { $0.id == selectedProjectId }) {
            return
        }
        selectedProjectId = snapshot.projects.first?.id
    }
}

private struct AdministrationProjectEditor: View {
    @ObservedObject var store: WorkspaceStore
    let project: AdminProjectRecord
    let organizationMembers: [AdminOrganizationMemberRecord]
    let allowsMutation: Bool
    @State private var name = ""
    @State private var description = ""
    @State private var pendingMemberRemoval: ProjectMemberRecord?
    @State private var confirmsProjectDeletion = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Name", text: $name)
                        TextField("Description", text: $description, axis: .vertical)
                            .lineLimit(3...8)
                        Text("Revision \(project.revision) · Updated \(project.updatedAt)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack {
                            Button("Save Project") { saveProject() }
                                .disabled(!canSaveProject)
                            Button("Delete Project", role: .destructive) {
                                confirmsProjectDeletion = true
                            }
                            .disabled(!allowsMutation)
                            Spacer()
                            if store.isMutatingAdministration {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Project details", systemImage: "folder")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        if store.loadingAdministrationProjectIds.contains(project.id) {
                            ProgressView("Loading members…")
                                .controlSize(.small)
                                .padding(.vertical, 12)
                        } else if projectMembers.isEmpty {
                            Text("No project members.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(Array(projectMembers.enumerated()), id: \.element.id) { index, member in
                                if index > 0 { Divider() }
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(member.user.displayName ?? member.user.email)
                                            .fontWeight(.medium)
                                        Text(member.user.email)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Picker("Role", selection: projectRoleBinding(for: member)) {
                                        ForEach(ProjectMemberRole.allCases, id: \.self) { role in
                                            Text(role.title).tag(role)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 105)
                                    .disabled(!allowsMemberMutation)
                                    Button(role: .destructive) {
                                        pendingMemberRemoval = member
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .disabled(!allowsMemberMutation)
                                    .help("Remove Project Member")
                                }
                                .padding(.vertical, 8)
                            }
                        }

                        Divider()
                        Menu {
                            ForEach(availableOrganizationMembers) { member in
                                Menu(member.displayName ?? member.email) {
                                    ForEach(ProjectMemberRole.allCases, id: \.self) { role in
                                        Button(role.title) { add(member, role: role) }
                                    }
                                }
                            }
                        } label: {
                            Label("Add Member", systemImage: "person.badge.plus")
                        }
                        .disabled(!allowsMemberMutation || availableOrganizationMembers.isEmpty)
                        .padding(.vertical, 10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Project members", systemImage: "person.2")
                }

                if let errorMessage {
                    AdministrationInlineError(message: errorMessage)
                }
            }
            .padding(24)
            .frame(maxWidth: 850, alignment: .leading)
        }
        .task(id: "\(project.id):\(store.administrationRefreshGeneration.uuidString)") {
            await store.loadAdministrationProjectMembers(projectId: project.id)
        }
        .task(id: project.revision) {
            name = project.name
            description = project.description
            errorMessage = nil
        }
        .confirmationDialog(
            "Delete project?",
            isPresented: $confirmsProjectDeletion
        ) {
            Button("Delete \(project.name)", role: .destructive) {
                mutate { try await store.deleteAdminProject(project) }
            }
        } message: {
            Text("This removes the project and its organization data. Repository bindings on this Mac are not required for this project.")
        }
        .confirmationDialog(
            "Remove project member?",
            isPresented: Binding(
                get: { pendingMemberRemoval != nil },
                set: { if !$0 { pendingMemberRemoval = nil } }
            ),
            presenting: pendingMemberRemoval
        ) { member in
            Button("Remove \(member.user.displayName ?? member.user.email)", role: .destructive) {
                mutate {
                    try await store.deleteAdminProjectMember(
                        projectId: project.id,
                        userId: member.id
                    )
                }
                pendingMemberRemoval = nil
            }
        }
    }

    private var projectMembers: [ProjectMemberRecord] {
        store.administrationProjectMembers[project.id] ?? []
    }

    private var availableOrganizationMembers: [AdminOrganizationMemberRecord] {
        let existingIds = Set(projectMembers.map(\.id))
        return organizationMembers.filter {
            $0.status != .disabled && !existingIds.contains($0.id)
        }
    }

    private var allowsMemberMutation: Bool {
        allowsMutation
            && !store.loadingAdministrationProjectIds.contains(project.id)
            && store.administrationProjectMembers[project.id] != nil
    }

    private var canSaveProject: Bool {
        allowsMutation && ProjectMetadataValidation.isValid(name: name, description: description)
    }

    private func projectRoleBinding(for member: ProjectMemberRecord) -> Binding<ProjectMemberRole> {
        Binding(
            get: { member.role },
            set: { role in
                guard role != member.role else { return }
                mutate {
                    try await store.updateAdminProjectMember(
                        projectId: project.id,
                        userId: member.id,
                        role: role
                    )
                }
            }
        )
    }

    private func saveProject() {
        mutate {
            try await store.updateAdminProject(
                project,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description
            )
        }
    }

    private func add(_ member: AdminOrganizationMemberRecord, role: ProjectMemberRole) {
        mutate {
            try await store.addAdminProjectMember(
                projectId: project.id,
                userId: member.id,
                role: role
            )
        }
    }

    private func mutate(_ operation: @escaping () async throws -> Void) {
        guard allowsMutation else { return }
        errorMessage = nil
        Task {
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AdministrationProjectCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: WorkspaceStore
    let onCreated: (String) -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(3...6)
                Text("This creates the server project now. A local repository can be attached later by any authorized member.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let errorMessage {
                    AdministrationInlineError(message: errorMessage)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(12)
        }
        .frame(width: 480, height: 300)
    }

    private var canCreate: Bool {
        store.canMutateAdministration
            && ProjectMetadataValidation.isValid(name: name, description: description)
    }

    private func create() {
        errorMessage = nil
        Task {
            do {
                let project = try await store.createAdminProject(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: description
                )
                onCreated(project.id)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AdministrationAccessView: View {
    @ObservedObject var store: WorkspaceStore
    let snapshot: AdministrationSnapshot
    let allowsMutation: Bool
    @State private var pendingRevocation: AdminAccessTokenRecord?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identityProviderSection
                credentialsSection

                if let errorMessage {
                    AdministrationInlineError(message: errorMessage)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .confirmationDialog(
            "Revoke credential?",
            isPresented: showsRevocationConfirmation,
            presenting: pendingRevocation
        ) { token in
            Button("Revoke \(token.kind.title)", role: .destructive) {
                revoke(token)
                pendingRevocation = nil
            }
        } message: { token in
            Text("This immediately revokes credential \(token.id).")
        }
    }

    private var identityProviderSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Status", value: identityProviderStatus)
                LabeledContent("Protocol", value: snapshot.identityProvider.protocol.uppercased())
                LabeledContent("Admission", value: formattedAdmissionMode)
                LabeledContent("Secrets", value: formattedSecretSource)
                if let issuer = snapshot.identityProvider.issuer {
                    LabeledContent("Issuer", value: issuer)
                }
                if let callback = snapshot.identityProvider.callbackUrl {
                    LabeledContent("Callback", value: callback)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Identity provider", systemImage: "person.badge.key")
        }
    }

    private var credentialsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if snapshot.tokens.isEmpty {
                    Text("No credentials have been issued.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }
                ForEach(Array(snapshot.tokens.enumerated()), id: \.element.id) { index, token in
                    if index > 0 { Divider() }
                    tokenRow(token)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Credentials", systemImage: "key.horizontal")
        }
    }

    private func tokenRow(_ token: AdminAccessTokenRecord) -> some View {
        let state = credentialState(token)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(token.kind.title)
                    .fontWeight(.medium)
                Text(memberName(token.userId))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(token.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(state.title)
                    .foregroundStyle(state.color)
                Text(token.expiresAt ?? "No expiration")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button("Revoke", role: .destructive) {
                pendingRevocation = token
            }
            .disabled(!state.isActive || !allowsMutation)
        }
        .padding(.vertical, 8)
    }

    private func credentialState(
        _ token: AdminAccessTokenRecord
    ) -> (title: String, color: Color, isActive: Bool) {
        if token.revoked {
            return ("Revoked", .secondary, false)
        }
        if let expiration = TimestampFormatting.date(from: token.expiresAt), expiration <= Date.now {
            return ("Expired", .orange, false)
        }
        return ("Active", .green, true)
    }

    private var showsRevocationConfirmation: Binding<Bool> {
        Binding(
            get: { pendingRevocation != nil },
            set: { if !$0 { pendingRevocation = nil } }
        )
    }

    private var identityProviderStatus: String {
        snapshot.identityProvider.configured ? "Configured" : "Not configured"
    }

    private var formattedAdmissionMode: String {
        snapshot.identityProvider.admissionMode
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private var formattedSecretSource: String {
        snapshot.identityProvider.secretSource
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func memberName(_ userId: String) -> String {
        guard let member = snapshot.members.first(where: { $0.id == userId }) else {
            return userId
        }
        return member.displayName ?? member.email
    }

    private func revoke(_ token: AdminAccessTokenRecord) {
        guard allowsMutation else { return }
        errorMessage = nil
        Task {
            do {
                try await store.revokeAdminAccessToken(token)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AdministrationAuditView: View {
    let events: [AdminAuditEventRecord]
    let members: [AdminOrganizationMemberRecord]
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search audit events", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Divider()
            if filteredEvents.isEmpty {
                ContentUnavailableView(
                    "No Audit Events",
                    systemImage: "list.bullet.clipboard",
                    description: Text(query.isEmpty ? "No organization activity has been recorded." : "No events match this search.")
                )
            } else {
                List(filteredEvents) { event in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.action)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                            Text("\(actorName(event.actorUserId)) · \(event.targetType)\(event.targetId.map { " · \($0)" } ?? "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(event.createdAt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private var filteredEvents: [AdminAuditEventRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !needle.isEmpty else { return events }
        return events.filter {
            "\($0.action) \($0.targetType) \($0.targetId ?? "") \(actorName($0.actorUserId))"
                .localizedLowercase.contains(needle)
        }
    }

    private func actorName(_ userId: String?) -> String {
        guard let userId else { return "System" }
        guard let member = members.first(where: { $0.id == userId }) else { return userId }
        return member.displayName ?? member.email
    }
}

private struct AdministrationInlineError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension AdminHealthStatus {
    var tint: Color {
        switch self {
        case .ok: .green
        case .degraded: .orange
        case .down: .red
        }
    }
}
