import {
  useEffect,
  useMemo,
  useState,
  type FormEvent,
  type ReactNode,
} from "react";
import {
  ClumsiesAdminApi,
  ClumsiesApiError,
  createAdminApiClient,
  type AdminSchema,
} from "@clumsies/api-client";
import {
  Activity,
  ArrowLeft,
  Building2,
  CircleAlert,
  FolderKanban,
  Gauge,
  KeyRound,
  LayoutDashboard,
  LoaderCircle,
  LogOut,
  Menu,
  Pencil,
  Plus,
  RefreshCw,
  Search,
  Settings,
  ShieldCheck,
  Trash2,
  UserPlus,
  Users,
  X,
} from "lucide-react";
import {
  adminPath,
  credentialStatus,
  formatDateTime,
  formatRelativeTime,
  humanizeAction,
  initials,
  matchesSearch,
  parseAdminRoute,
  type AdminRoute,
  type AdminSection,
} from "./model";

type WebAdminSession = AdminSchema<"WebAdminSession">;
type AdminOrg = AdminSchema<"AdminOrg">;
type Member = AdminSchema<"Member">;
type AdminProject = AdminSchema<"AdminProject">;
type ProjectMember = AdminSchema<"ProjectMember">;
type AccessToken = AdminSchema<"AccessTokenMeta">;
type AuditEvent = AdminSchema<"AuditEvent">;
type AdminHealth = AdminSchema<"AdminHealth">;
type OidcProviderStatus = AdminSchema<"OidcProviderStatus">;
type OrgRole = AdminSchema<"OrgRole">;
type MemberStatus = AdminSchema<"MemberStatus">;
type ProjectRole = AdminSchema<"ProjectRole">;

type AdminData = {
  org: AdminOrg;
  members: Member[];
  projects: AdminProject[];
  tokens: AccessToken[];
  auditEvents: AuditEvent[];
  health: AdminHealth;
  provider: OidcProviderStatus;
};

type Notice = { tone: "success" | "error"; message: string };

const NAV_ITEMS: Array<{
  section: AdminSection;
  label: string;
  icon: typeof LayoutDashboard;
}> = [
  { section: "overview", label: "Overview", icon: LayoutDashboard },
  { section: "members", label: "Members", icon: Users },
  { section: "projects", label: "Projects", icon: FolderKanban },
  { section: "access", label: "Access", icon: KeyRound },
  { section: "audit", label: "Audit", icon: Activity },
  { section: "settings", label: "Settings", icon: Settings },
];

export function AdminApp({
  initialSession,
  onSessionEnded,
  serverUrl,
}: {
  initialSession: WebAdminSession;
  onSessionEnded: (notice: string | null) => void;
  serverUrl: string;
}) {
  const api = useMemo(
    () =>
      new ClumsiesAdminApi(
        createAdminApiClient({
          baseUrl: serverUrl,
          credentials: "include",
          csrfToken: initialSession.csrf_token,
        }),
      ),
    [initialSession.csrf_token, serverUrl],
  );
  const [route, setRoute] = useState(() => parseAdminRoute(window.location.pathname));
  const [data, setData] = useState<AdminData | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [notice, setNotice] = useState<Notice | null>(null);
  const [navOpen, setNavOpen] = useState(false);

  useEffect(() => {
    const onPopState = () => setRoute(parseAdminRoute(window.location.pathname));
    window.addEventListener("popstate", onPopState);
    return () => window.removeEventListener("popstate", onPopState);
  }, []);

  useEffect(() => {
    void loadData(true);
    // The API identity changes whenever the session changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [api]);

  async function loadData(initial = false) {
    if (initial) setLoading(true);
    else setRefreshing(true);
    try {
      const [org, members, projects, tokens, auditEvents, health, provider] =
        await Promise.all([
          api.org(),
          loadAllPages((query) => api.listMembers(query)),
          loadAllPages((query) => api.listProjects(query)),
          loadAllPages((query) => api.listTokens(query)),
          loadAllPages((query) => api.listAuditEvents(query)),
          api.health(),
          api.identityProvider(),
        ]);
      setData({
        org,
        members,
        projects,
        tokens,
        auditEvents,
        health,
        provider,
      });
    } catch (error) {
      handleError(error);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }

  function handleError(error: unknown) {
    if (error instanceof ClumsiesApiError && error.status === 401) {
      onSessionEnded("Your administrator session expired. Sign in again.");
      return;
    }
    setNotice({ tone: "error", message: errorMessage(error) });
  }

  async function mutate(
    action: () => Promise<unknown>,
    successMessage: string,
    options: { reload?: boolean } = {},
  ): Promise<boolean> {
    try {
      await action();
      if (options.reload !== false) await loadData();
      setNotice({ tone: "success", message: successMessage });
      return true;
    } catch (error) {
      handleError(error);
      return false;
    }
  }

  function navigate(next: AdminRoute) {
    const path = adminPath(next);
    window.history.pushState(null, "", path);
    setRoute(next);
    setNavOpen(false);
  }

  async function logout() {
    try {
      await api.deleteSession();
    } catch (error) {
      if (!(error instanceof ClumsiesApiError && error.status === 401)) {
        handleError(error);
        return;
      }
    }
    onSessionEnded(null);
  }

  if (loading && !data) {
    return <AdminLoading />;
  }
  if (!data) {
    return (
      <AdminFailure
        message={notice?.message ?? "The administrator workspace could not be loaded."}
        onRetry={() => void loadData(true)}
      />
    );
  }

  return (
    <div className="admin-shell">
      <button
        aria-label="Open navigation"
        className="mobile-nav-button"
        onClick={() => setNavOpen(true)}
        title="Open navigation"
        type="button"
      >
        <Menu aria-hidden="true" />
      </button>
      {navOpen && (
        <button
          aria-label="Close navigation"
          className="nav-scrim"
          onClick={() => setNavOpen(false)}
          type="button"
        />
      )}
      <aside className={`admin-sidebar${navOpen ? " open" : ""}`}>
        <div className="admin-brand">
          <img src="/admin/clumsies-mark.svg" alt="" />
          <div>
            <strong>Clumsies</strong>
            <span>{data.org.name}</span>
          </div>
          <button
            aria-label="Close navigation"
            className="mobile-close-button"
            onClick={() => setNavOpen(false)}
            title="Close navigation"
            type="button"
          >
            <X aria-hidden="true" />
          </button>
        </div>
        <nav aria-label="Administration">
          {NAV_ITEMS.map((item) => {
            const Icon = item.icon;
            const selected = route.section === item.section;
            return (
              <button
                aria-current={selected ? "page" : undefined}
                className={selected ? "selected" : ""}
                key={item.section}
                onClick={() => navigate({ section: item.section })}
                type="button"
              >
                <Icon aria-hidden="true" />
                <span>{item.label}</span>
              </button>
            );
          })}
        </nav>
        <div className="admin-account">
          <Avatar
            displayName={initialSession.user.display_name}
            email={initialSession.user.email}
            imageUrl={initialSession.user.avatar_url}
          />
          <div>
            <strong>{initialSession.user.display_name || initialSession.user.email}</strong>
            <span>{titleCase(initialSession.user.role)}</span>
          </div>
          <button aria-label="Sign out" onClick={() => void logout()} title="Sign out" type="button">
            <LogOut aria-hidden="true" />
          </button>
        </div>
      </aside>

      <main className="admin-main">
        {notice && (
          <div className={`admin-notice ${notice.tone}`} role={notice.tone === "error" ? "alert" : "status"}>
            <span>{notice.message}</span>
            <button aria-label="Dismiss" onClick={() => setNotice(null)} title="Dismiss" type="button">
              <X aria-hidden="true" />
            </button>
          </div>
        )}
        {route.section === "overview" && (
          <OverviewPage
            data={data}
            onRefresh={() => void loadData()}
            refreshing={refreshing}
          />
        )}
        {route.section === "members" && (
          <MembersPage
            currentUser={initialSession.user}
            members={data.members}
            onCreate={(request) =>
              mutate(() => api.createMember(request), "Member invitation created.")
            }
            onDisable={(member) =>
              mutate(
                () => api.deleteMember(member.user_id, member.revision),
                `${member.email} was disabled.`,
              )
            }
            onUpdate={(member, request) =>
              mutate(
                () => api.updateMember(member.user_id, member.revision, request),
                `${member.email} was updated.`,
              )
            }
          />
        )}
        {route.section === "projects" && !route.projectId && (
          <ProjectsPage
            projects={data.projects}
            onCreate={(request) =>
              mutate(() => api.createProject(request), "Project created.")
            }
            onDelete={(project) =>
              mutate(
                () => api.deleteProject(project.project_id, project.revision),
                `${project.name} was deleted.`,
              )
            }
            onOpen={(projectId) => navigate({ section: "projects", projectId })}
            onUpdate={(project, request) =>
              mutate(
                () => api.updateProject(project.project_id, project.revision, request),
                `${project.name} was updated.`,
              )
            }
          />
        )}
        {route.section === "projects" && route.projectId && (
          <ProjectDetailPage
            api={api}
            members={data.members}
            onBack={() => navigate({ section: "projects" })}
            onError={handleError}
            onProjectChanged={() => loadData()}
            project={data.projects.find((project) => project.project_id === route.projectId)}
            projectId={route.projectId}
          />
        )}
        {route.section === "access" && (
          <AccessPage
            currentTokenId={initialSession.token_id}
            members={data.members}
            onRevoke={async (token) => {
              const completed = await mutate(
                () => api.deleteToken(token.token_id),
                "Credential revoked.",
                { reload: token.token_id !== initialSession.token_id },
              );
              if (completed && token.token_id === initialSession.token_id) {
                onSessionEnded("Your current administrator session was revoked.");
              }
              return completed;
            }}
            provider={data.provider}
            tokens={data.tokens}
          />
        )}
        {route.section === "audit" && (
          <AuditPage events={data.auditEvents} members={data.members} />
        )}
        {route.section === "settings" && (
          <SettingsPage
            onSave={(request) =>
              mutate(
                () => api.updateOrg(data.org.revision, request),
                "Organization settings saved.",
              )
            }
            org={data.org}
          />
        )}
      </main>
    </div>
  );
}

type Page<T> = {
  items: T[];
  page_info: { next_cursor?: string | null; has_more: boolean };
};

async function loadAllPages<T>(
  loader: (query: { limit: number; cursor?: string }) => Promise<Page<T>>,
): Promise<T[]> {
  const items: T[] = [];
  let cursor: string | undefined;
  do {
    const page = await loader({ limit: 200, cursor });
    items.push(...page.items);
    cursor = page.page_info.has_more
      ? (page.page_info.next_cursor ?? undefined)
      : undefined;
    if (page.page_info.has_more && cursor === undefined) {
      throw new Error("The server returned an incomplete pagination cursor.");
    }
  } while (cursor !== undefined);
  return items;
}

function OverviewPage({
  data,
  onRefresh,
  refreshing,
}: {
  data: AdminData;
  onRefresh: () => void;
  refreshing: boolean;
}) {
  const activeMembers = data.members.filter((member) => member.status === "active").length;
  const activeCredentials = data.tokens.filter(
    (token) => credentialStatus(token.revoked, token.expires_at) === "active",
  ).length;
  const healthChecks = [
    ["Database", data.health.database],
    ["Schema", data.health.schema],
    ["Commit service", data.health.commit_service],
    ["OIDC", data.health.oidc],
  ] as const;

  return (
    <div className="admin-page">
      <PageHeading title="Overview">
        <StatusBadge value={data.health.status} />
        <IconButton
          label="Refresh"
          onClick={onRefresh}
          spinning={refreshing}
          icon={<RefreshCw aria-hidden="true" />}
        />
      </PageHeading>
      <dl className="metric-strip">
        <Metric label="Members" value={String(data.members.length)} detail={`${activeMembers} active`} />
        <Metric label="Projects" value={String(data.projects.length)} detail="organization total" />
        <Metric label="Credentials" value={String(activeCredentials)} detail="currently active" />
        <Metric label="Server" value={`v${data.health.version}`} detail={data.org.name} />
      </dl>
      <div className="overview-grid">
        <section className="plain-section">
          <SectionHeading title="Service health" />
          <div className="health-list">
            {healthChecks.map(([label, check]) => (
              <div key={label}>
                <span>{label}</span>
                <StatusBadge value={check.status} />
                <small>{check.message}</small>
              </div>
            ))}
          </div>
        </section>
        <section className="plain-section">
          <SectionHeading title="Recent activity" />
          <ActivityList events={data.auditEvents.slice(0, 8)} members={data.members} />
        </section>
      </div>
    </div>
  );
}

function MembersPage({
  currentUser,
  members,
  onCreate,
  onDisable,
  onUpdate,
}: {
  currentUser: WebAdminSession["user"];
  members: Member[];
  onCreate: (request: { email: string; role: OrgRole }) => Promise<boolean>;
  onDisable: (member: Member) => Promise<boolean>;
  onUpdate: (
    member: Member,
    request: { role?: OrgRole; status?: MemberStatus },
  ) => Promise<boolean>;
}) {
  const [query, setQuery] = useState("");
  const [role, setRole] = useState<OrgRole | "all">("all");
  const [status, setStatus] = useState<MemberStatus | "all">("all");
  const [editor, setEditor] = useState<Member | "new" | null>(null);
  const [disableTarget, setDisableTarget] = useState<Member | null>(null);
  const filtered = members.filter(
    (member) =>
      (role === "all" || member.role === role) &&
      (status === "all" || member.status === status) &&
      matchesSearch([member.display_name, member.email], query),
  );

  return (
    <div className="admin-page">
      <PageHeading title="Members">
        <button className="primary-button" onClick={() => setEditor("new")} type="button">
          <UserPlus aria-hidden="true" />
          Invite member
        </button>
      </PageHeading>
      <div className="table-toolbar">
        <SearchField onChange={setQuery} placeholder="Search members" value={query} />
        <select aria-label="Filter by role" onChange={(event) => setRole(event.target.value as OrgRole | "all")} value={role}>
          <option value="all">All roles</option>
          <option value="owner">Owner</option>
          <option value="admin">Admin</option>
          <option value="member">Member</option>
        </select>
        <select aria-label="Filter by status" onChange={(event) => setStatus(event.target.value as MemberStatus | "all")} value={status}>
          <option value="all">All statuses</option>
          <option value="invited">Invited</option>
          <option value="active">Active</option>
          <option value="disabled">Disabled</option>
        </select>
      </div>
      <DataTable empty="No members match these filters." rowCount={filtered.length}>
        <thead>
          <tr>
            <th>Member</th>
            <th>Organization role</th>
            <th>Status</th>
            <th>SSO identity</th>
            <th><span className="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          {filtered.map((member) => {
            const isCurrent = member.user_id === currentUser.user_id;
            const ownerLocked = currentUser.role !== "owner" && member.role === "owner";
            return (
              <tr key={member.user_id}>
                <td>
                  <div className="identity-cell">
                    <Avatar displayName={member.display_name} email={member.email} imageUrl={null} />
                    <div>
                      <strong>{member.display_name || member.email}</strong>
                      <span>{member.email}{isCurrent ? " · You" : ""}</span>
                    </div>
                  </div>
                </td>
                <td>{titleCase(member.role)}</td>
                <td><StatusBadge value={member.status} /></td>
                <td>{member.external_identity_bound ? "Bound" : "Not bound"}</td>
                <td>
                  <div className="row-actions">
                    <IconButton
                      disabled={isCurrent || ownerLocked}
                      icon={<Pencil aria-hidden="true" />}
                      label="Edit member"
                      onClick={() => setEditor(member)}
                    />
                    <IconButton
                      disabled={isCurrent || member.status === "disabled" || ownerLocked}
                      icon={<Trash2 aria-hidden="true" />}
                      label="Disable member"
                      onClick={() => setDisableTarget(member)}
                      tone="danger"
                    />
                  </div>
                </td>
              </tr>
            );
          })}
        </tbody>
      </DataTable>
      {editor && (
        <MemberEditor
          currentUserRole={currentUser.role}
          member={editor === "new" ? null : editor}
          onClose={() => setEditor(null)}
          onCreate={onCreate}
          onUpdate={onUpdate}
        />
      )}
      {disableTarget && (
        <ConfirmDialog
          confirmLabel="Disable member"
          description={`Disable ${disableTarget.email} and revoke all of their active sessions?`}
          onCancel={() => setDisableTarget(null)}
          onConfirm={async () => {
            const disabled = await onDisable(disableTarget);
            if (disabled) setDisableTarget(null);
            return disabled;
          }}
          title="Disable organization member"
        />
      )}
    </div>
  );
}

function ProjectsPage({
  projects,
  onCreate,
  onDelete,
  onOpen,
  onUpdate,
}: {
  projects: AdminProject[];
  onCreate: (request: { name: string; description?: string }) => Promise<boolean>;
  onDelete: (project: AdminProject) => Promise<boolean>;
  onOpen: (projectId: string) => void;
  onUpdate: (
    project: AdminProject,
    request: { name?: string; description?: string },
  ) => Promise<boolean>;
}) {
  const [query, setQuery] = useState("");
  const [editor, setEditor] = useState<AdminProject | "new" | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<AdminProject | null>(null);
  const filtered = projects.filter((project) =>
    matchesSearch([project.name, project.description], query),
  );

  return (
    <div className="admin-page">
      <PageHeading title="Projects">
        <button className="primary-button" onClick={() => setEditor("new")} type="button">
          <Plus aria-hidden="true" />
          New project
        </button>
      </PageHeading>
      <div className="table-toolbar">
        <SearchField onChange={setQuery} placeholder="Search projects" value={query} />
      </div>
      <DataTable empty="No projects match this search." rowCount={filtered.length}>
        <thead>
          <tr>
            <th>Project</th>
            <th>Members</th>
            <th>Updated</th>
            <th><span className="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          {filtered.map((project) => (
            <tr key={project.project_id}>
              <td>
                <button className="table-link" onClick={() => onOpen(project.project_id)} type="button">
                  <strong>{project.name}</strong>
                  <span>{project.description || "No description"}</span>
                </button>
              </td>
              <td>{project.member_count}</td>
              <td>{formatRelativeTime(project.updated_at)}</td>
              <td>
                <div className="row-actions">
                  <IconButton icon={<Pencil aria-hidden="true" />} label="Edit project" onClick={() => setEditor(project)} />
                  <IconButton icon={<Trash2 aria-hidden="true" />} label="Delete project" onClick={() => setDeleteTarget(project)} tone="danger" />
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </DataTable>
      {editor && (
        <ProjectEditor
          onClose={() => setEditor(null)}
          onCreate={onCreate}
          onUpdate={onUpdate}
          project={editor === "new" ? null : editor}
        />
      )}
      {deleteTarget && (
        <ConfirmDialog
          confirmLabel="Delete project"
          description={`Delete ${deleteTarget.name} and all of its governed memory, drafts, reviews, and history? This cannot be undone.`}
          onCancel={() => setDeleteTarget(null)}
          onConfirm={async () => {
            const deleted = await onDelete(deleteTarget);
            if (deleted) setDeleteTarget(null);
            return deleted;
          }}
          title="Delete project"
        />
      )}
    </div>
  );
}

function ProjectDetailPage({
  api,
  members,
  onBack,
  onError,
  onProjectChanged,
  project,
  projectId,
}: {
  api: ClumsiesAdminApi;
  members: Member[];
  onBack: () => void;
  onError: (error: unknown) => void;
  onProjectChanged: () => Promise<void>;
  project: AdminProject | undefined;
  projectId: string;
}) {
  const [projectMembers, setProjectMembers] = useState<ProjectMember[] | null>(null);
  const [adding, setAdding] = useState(false);
  const [removeTarget, setRemoveTarget] = useState<ProjectMember | null>(null);
  const [workingUserId, setWorkingUserId] = useState<string | null>(null);

  async function loadMembers() {
    try {
      const projectMembers = await loadAllPages((query) =>
        api.listProjectMembers(projectId, query),
      );
      setProjectMembers(projectMembers);
    } catch (error) {
      onError(error);
    }
  }

  useEffect(() => {
    setProjectMembers(null);
    void loadMembers();
    // Project identity is the complete query key.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId]);

  if (!project) {
    return (
      <div className="admin-page">
        <PageHeading title="Project unavailable">
          <button className="secondary-button" onClick={onBack} type="button">Back to projects</button>
        </PageHeading>
        <EmptyState message="This project no longer exists or is not available to this organization." />
      </div>
    );
  }

  const existingIds = new Set(projectMembers?.map((member) => member.user.user_id));
  const candidates = members.filter(
    (member) => member.status !== "disabled" && !existingIds.has(member.user_id),
  );

  async function updateRole(member: ProjectMember, role: ProjectRole) {
    setWorkingUserId(member.user.user_id);
    try {
      await api.updateProjectMember(projectId, member.user.user_id, { role });
      await Promise.all([loadMembers(), onProjectChanged()]);
    } catch (error) {
      onError(error);
    } finally {
      setWorkingUserId(null);
    }
  }

  return (
    <div className="admin-page">
      <PageHeading title={project.name} subtitle={project.description || "No description"}>
        <button className="secondary-button back-button" onClick={onBack} type="button">
          <ArrowLeft aria-hidden="true" />
          Projects
        </button>
        <button className="primary-button" disabled={candidates.length === 0} onClick={() => setAdding(true)} type="button">
          <UserPlus aria-hidden="true" />
          Add member
        </button>
      </PageHeading>
      <SectionHeading title="Project access" detail={`${projectMembers?.length ?? 0} members`} />
      {projectMembers === null ? (
        <InlineLoading label="Loading project members" />
      ) : (
        <DataTable empty="No members have access to this project." rowCount={projectMembers.length}>
          <thead>
            <tr>
              <th>Member</th>
              <th>Project role</th>
              <th>Joined</th>
              <th><span className="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            {projectMembers.map((member) => (
              <tr key={member.user.user_id}>
                <td>
                  <div className="identity-cell">
                    <Avatar displayName={member.user.display_name} email={member.user.email} imageUrl={member.user.avatar_url} />
                    <div>
                      <strong>{member.user.display_name || member.user.email}</strong>
                      <span>{member.user.email}</span>
                    </div>
                  </div>
                </td>
                <td>
                  <select
                    aria-label={`Project role for ${member.user.email}`}
                    disabled={workingUserId === member.user.user_id}
                    onChange={(event) => void updateRole(member, event.target.value as ProjectRole)}
                    value={member.role}
                  >
                    <option value="member">Member</option>
                    <option value="admin">Admin</option>
                  </select>
                </td>
                <td>{formatDateTime(member.joined_at)}</td>
                <td>
                  <div className="row-actions">
                    <IconButton
                      disabled={workingUserId === member.user.user_id}
                      icon={<Trash2 aria-hidden="true" />}
                      label="Remove project access"
                      onClick={() => setRemoveTarget(member)}
                      tone="danger"
                    />
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </DataTable>
      )}
      {adding && (
        <ProjectMemberEditor
          candidates={candidates}
          onClose={() => setAdding(false)}
          onSubmit={async (userId, role) => {
            try {
              await api.createProjectMember(projectId, { user_id: userId, role });
              await Promise.all([loadMembers(), onProjectChanged()]);
              setAdding(false);
              return true;
            } catch (error) {
              onError(error);
              return false;
            }
          }}
        />
      )}
      {removeTarget && (
        <ConfirmDialog
          confirmLabel="Remove access"
          description={`Remove ${removeTarget.user.email} from ${project.name}?`}
          onCancel={() => setRemoveTarget(null)}
          onConfirm={async () => {
            setWorkingUserId(removeTarget.user.user_id);
            try {
              await api.deleteProjectMember(projectId, removeTarget.user.user_id);
              await Promise.all([loadMembers(), onProjectChanged()]);
              setRemoveTarget(null);
              return true;
            } catch (error) {
              onError(error);
              return false;
            } finally {
              setWorkingUserId(null);
            }
          }}
          title="Remove project access"
        />
      )}
    </div>
  );
}

function AccessPage({
  currentTokenId,
  members,
  onRevoke,
  provider,
  tokens,
}: {
  currentTokenId: string;
  members: Member[];
  onRevoke: (token: AccessToken) => Promise<boolean>;
  provider: OidcProviderStatus;
  tokens: AccessToken[];
}) {
  const [revokeTarget, setRevokeTarget] = useState<AccessToken | null>(null);
  const memberMap = new Map(members.map((member) => [member.user_id, member]));
  return (
    <div className="admin-page">
      <PageHeading title="Access" />
      <section className="plain-section provider-section">
        <SectionHeading title="Enterprise identity" />
        <dl className="definition-grid">
          <Definition label="Protocol" value={provider.protocol.toUpperCase()} />
          <Definition label="Status" value={provider.configured ? "Configured" : "Not configured"} />
          <Definition label="Admission" value="Invitation required" />
          <Definition label="Secret source" value="Deployment environment" />
          <Definition label="Issuer" value={provider.issuer ?? "Unavailable"} wide />
          <Definition label="Callback" value={provider.callback_url ?? "Unavailable"} wide />
        </dl>
      </section>
      <section className="plain-section">
        <SectionHeading title="Credentials" detail={`${tokens.length} records`} />
        <DataTable empty="No credentials have been issued." rowCount={tokens.length}>
          <thead>
            <tr>
              <th>Owner</th>
              <th>Type</th>
              <th>Created</th>
              <th>Expires</th>
              <th>Status</th>
              <th><span className="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            {tokens.map((token) => {
              const member = memberMap.get(token.user_id);
              const current = token.token_id === currentTokenId;
              const status = credentialStatus(token.revoked, token.expires_at);
              return (
                <tr key={token.token_id}>
                  <td>{member?.display_name || member?.email || token.user_id}</td>
                  <td>{tokenKindLabel(token.kind)}{current ? " · Current" : ""}</td>
                  <td>{formatDateTime(token.created_at)}</td>
                  <td>{token.expires_at ? formatDateTime(token.expires_at) : "Never"}</td>
                  <td><StatusBadge value={status} /></td>
                  <td>
                    <div className="row-actions">
                      <IconButton
                        disabled={status !== "active"}
                        icon={<Trash2 aria-hidden="true" />}
                        label="Revoke credential"
                        onClick={() => setRevokeTarget(token)}
                        tone="danger"
                      />
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </DataTable>
      </section>
      {revokeTarget && (
        <ConfirmDialog
          confirmLabel="Revoke credential"
          description={
            revokeTarget.token_id === currentTokenId
              ? "Revoke this Web Admin session and sign out now?"
              : `Revoke this ${tokenKindLabel(revokeTarget.kind).toLowerCase()} credential?`
          }
          onCancel={() => setRevokeTarget(null)}
          onConfirm={async () => {
            const revoked = await onRevoke(revokeTarget);
            if (revoked) setRevokeTarget(null);
            return revoked;
          }}
          title="Revoke credential"
        />
      )}
    </div>
  );
}

function AuditPage({ events, members }: { events: AuditEvent[]; members: Member[] }) {
  const [query, setQuery] = useState("");
  const memberMap = new Map(members.map((member) => [member.user_id, member]));
  const filtered = events.filter((event) => {
    const actor = event.actor_user_id ? memberMap.get(event.actor_user_id) : undefined;
    return matchesSearch(
      [event.action, event.target_type, event.target_id, actor?.email, actor?.display_name],
      query,
    );
  });
  return (
    <div className="admin-page">
      <PageHeading title="Audit" />
      <div className="table-toolbar">
        <SearchField onChange={setQuery} placeholder="Search audit events" value={query} />
      </div>
      <DataTable empty="No audit events match this search." rowCount={filtered.length}>
        <thead>
          <tr>
            <th>Time</th>
            <th>Actor</th>
            <th>Action</th>
            <th>Target</th>
          </tr>
        </thead>
        <tbody>
          {filtered.map((event) => {
            const actor = event.actor_user_id ? memberMap.get(event.actor_user_id) : undefined;
            return (
              <tr key={event.event_id}>
                <td>{formatDateTime(event.created_at)}</td>
                <td>{actor?.display_name || actor?.email || event.actor_user_id || "System"}</td>
                <td><code>{event.action}</code><span className="audit-label">{humanizeAction(event.action)}</span></td>
                <td>{titleCase(event.target_type)}{event.target_id ? ` · ${event.target_id}` : ""}</td>
              </tr>
            );
          })}
        </tbody>
      </DataTable>
    </div>
  );
}

function SettingsPage({
  onSave,
  org,
}: {
  onSave: (request: { name?: string; allowed_email_domains?: string[] }) => Promise<boolean>;
  org: AdminOrg;
}) {
  const [name, setName] = useState(org.name);
  const [domains, setDomains] = useState(org.allowed_email_domains.join(", "));
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    setName(org.name);
    setDomains(org.allowed_email_domains.join(", "));
    setSaving(false);
  }, [org]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSaving(true);
    const saved = await onSave({
      name: name.trim(),
      allowed_email_domains: domains
        .split(",")
        .map((domain) => domain.trim())
        .filter(Boolean),
    });
    if (!saved) setSaving(false);
  }

  return (
    <div className="admin-page settings-page">
      <PageHeading title="Settings" />
      <form className="settings-form" onSubmit={(event) => void submit(event)}>
        <SectionHeading title="Organization" />
        <label className="field">
          <span>Name</span>
          <input maxLength={120} onChange={(event) => setName(event.target.value)} required value={name} />
        </label>
        <label className="field">
          <span>Allowed email domains</span>
          <input onChange={(event) => setDomains(event.target.value)} placeholder="example.com, subsidiary.example.com" value={domains} />
          <small className="field-hint">Invited members must use one of these domains. Leave empty to disable the domain filter.</small>
        </label>
        <div className="form-actions">
          <button className="primary-button" disabled={saving || !name.trim()} type="submit">
            {saving ? <LoaderCircle className="spin" aria-hidden="true" /> : null}
            Save changes
          </button>
        </div>
      </form>
    </div>
  );
}

function MemberEditor({
  currentUserRole,
  member,
  onClose,
  onCreate,
  onUpdate,
}: {
  currentUserRole: string;
  member: Member | null;
  onClose: () => void;
  onCreate: (request: { email: string; role: OrgRole }) => Promise<boolean>;
  onUpdate: (
    member: Member,
    request: { role?: OrgRole; status?: MemberStatus },
  ) => Promise<boolean>;
}) {
  const [email, setEmail] = useState(member?.email ?? "");
  const [role, setRole] = useState<OrgRole>(member?.role ?? "member");
  const [status, setStatus] = useState<MemberStatus>(member?.status ?? "invited");
  const [busy, setBusy] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    const completed = member
      ? await onUpdate(member, { role, status })
      : await onCreate({ email: email.trim(), role });
    if (completed) onClose();
    else setBusy(false);
  }

  return (
    <Modal onClose={onClose} title={member ? "Edit member" : "Invite member"}>
      <form className="dialog-form" onSubmit={(event) => void submit(event)}>
        <label className="field">
          <span>Email</span>
          <input autoFocus={!member} disabled={Boolean(member) || busy} onChange={(event) => setEmail(event.target.value)} required type="email" value={email} />
        </label>
        <label className="field">
          <span>Organization role</span>
          <select disabled={busy} onChange={(event) => setRole(event.target.value as OrgRole)} value={role}>
            <option value="member">Member</option>
            <option value="admin">Admin</option>
            {currentUserRole === "owner" && <option value="owner">Owner</option>}
          </select>
        </label>
        {member && (
          <label className="field">
            <span>Status</span>
            <select disabled={busy} onChange={(event) => setStatus(event.target.value as MemberStatus)} value={status}>
              <option value="invited">Invited</option>
              <option value="active">Active</option>
              <option value="disabled">Disabled</option>
            </select>
          </label>
        )}
        <DialogActions busy={busy} onCancel={onClose} submitLabel={member ? "Save changes" : "Create invitation"} />
      </form>
    </Modal>
  );
}

function ProjectEditor({
  onClose,
  onCreate,
  onUpdate,
  project,
}: {
  onClose: () => void;
  onCreate: (request: { name: string; description?: string }) => Promise<boolean>;
  onUpdate: (
    project: AdminProject,
    request: { name?: string; description?: string },
  ) => Promise<boolean>;
  project: AdminProject | null;
}) {
  const [name, setName] = useState(project?.name ?? "");
  const [description, setDescription] = useState(project?.description ?? "");
  const [busy, setBusy] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    const request = { name: name.trim(), description: description.trim() };
    const completed = project ? await onUpdate(project, request) : await onCreate(request);
    if (completed) onClose();
    else setBusy(false);
  }

  return (
    <Modal onClose={onClose} title={project ? "Edit project" : "New project"}>
      <form className="dialog-form" onSubmit={(event) => void submit(event)}>
        <label className="field">
          <span>Name</span>
          <input autoFocus disabled={busy} maxLength={120} onChange={(event) => setName(event.target.value)} required value={name} />
        </label>
        <label className="field">
          <span>Description</span>
          <textarea disabled={busy} maxLength={4000} onChange={(event) => setDescription(event.target.value)} rows={4} value={description} />
        </label>
        <DialogActions busy={busy} onCancel={onClose} submitLabel={project ? "Save changes" : "Create project"} />
      </form>
    </Modal>
  );
}

function ProjectMemberEditor({
  candidates,
  onClose,
  onSubmit,
}: {
  candidates: Member[];
  onClose: () => void;
  onSubmit: (userId: string, role: ProjectRole) => Promise<boolean>;
}) {
  const [userId, setUserId] = useState(candidates[0]?.user_id ?? "");
  const [role, setRole] = useState<ProjectRole>("member");
  const [busy, setBusy] = useState(false);
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    if (!(await onSubmit(userId, role))) setBusy(false);
  }
  return (
    <Modal onClose={onClose} title="Add project member">
      <form className="dialog-form" onSubmit={(event) => void submit(event)}>
        <label className="field">
          <span>Organization member</span>
          <select autoFocus disabled={busy} onChange={(event) => setUserId(event.target.value)} required value={userId}>
            {candidates.map((member) => (
              <option key={member.user_id} value={member.user_id}>{member.display_name || member.email} · {member.email}</option>
            ))}
          </select>
        </label>
        <label className="field">
          <span>Project role</span>
          <select disabled={busy} onChange={(event) => setRole(event.target.value as ProjectRole)} value={role}>
            <option value="member">Member</option>
            <option value="admin">Admin</option>
          </select>
        </label>
        <DialogActions busy={busy} onCancel={onClose} submitLabel="Add member" />
      </form>
    </Modal>
  );
}

function ConfirmDialog({
  confirmLabel,
  description,
  onCancel,
  onConfirm,
  title,
}: {
  confirmLabel: string;
  description: string;
  onCancel: () => void;
  onConfirm: () => Promise<boolean>;
  title: string;
}) {
  const [busy, setBusy] = useState(false);
  return (
    <Modal onClose={onCancel} title={title}>
      <p className="dialog-description">{description}</p>
      <div className="dialog-actions">
        <button className="secondary-button" disabled={busy} onClick={onCancel} type="button">Cancel</button>
        <button
          className="danger-button"
          disabled={busy}
          onClick={() => {
            setBusy(true);
            void onConfirm().then((completed) => {
              if (!completed) setBusy(false);
            }, () => setBusy(false));
          }}
          type="button"
        >
          {busy ? <LoaderCircle className="spin" aria-hidden="true" /> : null}
          {confirmLabel}
        </button>
      </div>
    </Modal>
  );
}

function Modal({ children, onClose, title }: { children: ReactNode; onClose: () => void; title: string }) {
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);
  return (
    <div className="modal-backdrop" onMouseDown={(event) => { if (event.currentTarget === event.target) onClose(); }}>
      <section aria-labelledby="dialog-title" aria-modal="true" className="modal" role="dialog">
        <header>
          <h2 id="dialog-title">{title}</h2>
          <IconButton icon={<X aria-hidden="true" />} label="Close" onClick={onClose} />
        </header>
        {children}
      </section>
    </div>
  );
}

function DialogActions({ busy, onCancel, submitLabel }: { busy: boolean; onCancel: () => void; submitLabel: string }) {
  return (
    <div className="dialog-actions">
      <button className="secondary-button" disabled={busy} onClick={onCancel} type="button">Cancel</button>
      <button className="primary-button" disabled={busy} type="submit">
        {busy ? <LoaderCircle className="spin" aria-hidden="true" /> : null}
        {submitLabel}
      </button>
    </div>
  );
}

function PageHeading({ children, subtitle, title }: { children?: ReactNode; subtitle?: string; title: string }) {
  return (
    <header className="page-heading">
      <div>
        <h1>{title}</h1>
        {subtitle && <p>{subtitle}</p>}
      </div>
      {children && <div className="page-actions">{children}</div>}
    </header>
  );
}

function SectionHeading({ detail, title }: { detail?: string; title: string }) {
  return (
    <header className="section-title">
      <h2>{title}</h2>
      {detail && <span>{detail}</span>}
    </header>
  );
}

function Metric({ detail, label, value }: { detail: string; label: string; value: string }) {
  return (
    <div>
      <dt>{label}</dt>
      <dd>{value}</dd>
      <small>{detail}</small>
    </div>
  );
}

function Definition({ label, value, wide = false }: { label: string; value: string; wide?: boolean }) {
  return (
    <div className={wide ? "wide" : ""}>
      <dt>{label}</dt>
      <dd title={value}>{value}</dd>
    </div>
  );
}

function DataTable({ children, empty, rowCount }: { children: ReactNode; empty: string; rowCount: number }) {
  return (
    <div className="table-region">
      <table>{children}</table>
      {rowCount === 0 && <EmptyState message={empty} />}
    </div>
  );
}

function EmptyState({ message }: { message: string }) {
  return <div className="empty-state">{message}</div>;
}

function SearchField({ onChange, placeholder, value }: { onChange: (value: string) => void; placeholder: string; value: string }) {
  return (
    <label className="search-field">
      <Search aria-hidden="true" />
      <span className="sr-only">{placeholder}</span>
      <input onChange={(event) => onChange(event.target.value)} placeholder={placeholder} type="search" value={value} />
    </label>
  );
}

function IconButton({
  disabled = false,
  icon,
  label,
  onClick,
  spinning = false,
  tone = "default",
}: {
  disabled?: boolean;
  icon: ReactNode;
  label: string;
  onClick: () => void;
  spinning?: boolean;
  tone?: "default" | "danger";
}) {
  return (
    <button
      aria-label={label}
      className={`icon-button${tone === "danger" ? " danger" : ""}${spinning ? " spinning" : ""}`}
      disabled={disabled}
      onClick={onClick}
      title={label}
      type="button"
    >
      {icon}
    </button>
  );
}

function StatusBadge({ value }: { value: string }) {
  const normalized = value.replaceAll("_", "-");
  return <span className={`status-badge ${normalized}`}>{titleCase(value)}</span>;
}

function Avatar({ displayName, email, imageUrl }: { displayName: string | null; email: string; imageUrl: string | null }) {
  return imageUrl ? (
    <img className="avatar" src={imageUrl} alt="" referrerPolicy="no-referrer" />
  ) : (
    <span aria-hidden="true" className="avatar avatar-fallback">{initials(displayName, email)}</span>
  );
}

function ActivityList({ events, members }: { events: AuditEvent[]; members: Member[] }) {
  const memberMap = new Map(members.map((member) => [member.user_id, member]));
  if (events.length === 0) return <EmptyState message="No audit activity yet." />;
  return (
    <ol className="activity-list">
      {events.map((event) => {
        const actor = event.actor_user_id ? memberMap.get(event.actor_user_id) : undefined;
        return (
          <li key={event.event_id}>
            <span>{humanizeAction(event.action)}</span>
            <small>{actor?.display_name || actor?.email || "System"} · {formatRelativeTime(event.created_at)}</small>
          </li>
        );
      })}
    </ol>
  );
}

function InlineLoading({ label }: { label: string }) {
  return (
    <div className="inline-loading">
      <LoaderCircle className="spin" aria-hidden="true" />
      <span>{label}</span>
    </div>
  );
}

function AdminLoading() {
  return (
    <main className="bootstrap-state">
      <LoaderCircle className="spin" aria-hidden="true" />
      <span>Loading administration</span>
    </main>
  );
}

function AdminFailure({ message, onRetry }: { message: string; onRetry: () => void }) {
  return (
    <main className="bootstrap-state bootstrap-error">
      <CircleAlert aria-hidden="true" />
      <h1>Administration unavailable</h1>
      <p>{message}</p>
      <button className="secondary-button" onClick={onRetry} type="button">Retry</button>
    </main>
  );
}

function titleCase(value: string): string {
  return value
    .replaceAll("_", " ")
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function tokenKindLabel(kind: AccessToken["kind"]): string {
  switch (kind) {
    case "web_session":
      return "Web Admin";
    case "access":
      return "Access token";
    case "refresh":
      return "Refresh token";
    case "integration":
      return "Integration token";
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "The Server could not complete this request.";
}
