import type { CSSProperties, KeyboardEvent, PointerEvent, ReactNode } from "react";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { invoke } from "@tauri-apps/api/core";
import {
  ClumsiesApiError,
  type DaemonBootstrapStatus,
  type DaemonHealth,
  type DaemonMcpStatus,
  type DaemonProjectConfig,
  type DaemonSyncStatus,
  type NativeInvoke,
} from "@clumsies/api-client";
import type { LucideIcon } from "lucide-react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import clumsiesMark from "./assets/clumsies-mark.svg";
import {
  AuthenticationRequiredError,
  daemonDiscardOperationForDraft,
  daemonOperationsForDraft,
  DesktopBackend,
  mapBundle,
  mapReviewWithConflict,
  mapReviewSummary,
  syncStateForDaemonDraft,
  type DesktopAccount,
  type DesktopOrganization,
  type ProjectOption,
} from "./backend";
import {
  Activity,
  AlertTriangle,
  ArrowDown,
  ArrowUp,
  Bot,
  Check,
  CheckCircle2,
  ChevronDown,
  CircleDot,
  Cloud,
  CloudOff,
  Code2,
  FilePenLine,
  FileText,
  Eye,
  Folder,
  FolderOpen,
  FolderKanban,
  GitMerge,
  GitPullRequest,
  ListChecks,
  LoaderCircle,
  MoreHorizontal,
  Package,
  PanelLeftClose,
  Plus,
  RefreshCw,
  Search,
  Send,
  Sparkles,
  Trash2,
  Undo2,
  X,
} from "lucide-react";
import { TextEditor } from "./text-editor";
import {
  applyDraft,
  cloneDocument,
  createBlankDraft,
  createDraftFromResource,
  findListItem,
  globalSearch,
  initialBundles,
  initialDrafts,
  initialResources,
  initialReviews,
  listResources,
  memoryKinds,
  reviewDiff,
  resourceWorkingState,
  type AuthorityResource,
  type DraftRecord,
  type MemoryDocument,
  type MemoryKind,
  type MemoryScope,
  type PersonalBundle,
  type ResourceListItem,
  type ResourceWorkingState,
  type ReviewRecord,
  type ReviewStatus,
  type SearchResult,
  type SyncState,
} from "./model";
import {
  closeWorkspaceTab,
  memoryTabKey,
  openWorkspaceTab,
  pinWorkspaceTab,
  retargetMemoryTabs,
  type MemoryTabSurface,
  type WorkspaceTab,
} from "./workspace-tabs";

type PrimaryView = "Hub" | "Local" | "Bundles" | "Reviews";
type UtilityView = "Diagnostics" | "Settings";
type View = PrimaryView | UtilityView;
type ReviewFilter = ReviewStatus;

type LoadState =
  | { status: "loading" }
  | { status: "preview" }
  | { status: "authentication_required"; message?: string }
  | { status: "failed"; message: string }
  | {
      status: "ready";
      bootstrap: DaemonBootstrapStatus;
      health: DaemonHealth | null;
      projectConfig: DaemonProjectConfig | null;
      syncStatus: DaemonSyncStatus | null;
      mcpStatus: DaemonMcpStatus | null;
    };

type ConfirmState = {
  title: string;
  message: string;
  confirmLabel: string;
  tone?: "danger";
  onConfirm: () => void;
};

type UndoState = { message: string; run: () => void };

type AgentTarget = {
  key: string;
  label: string;
  quickActions: string[];
  proposal: string;
  applyLabel: string;
  onApply: () => void;
};

type NavigationItem = {
  view: PrimaryView;
  label: string;
  icon: LucideIcon;
};
type WorkspaceTabPresentation = {
  tab: WorkspaceTab;
  label: string;
  title: string;
  syncState?: SyncState;
};

const defaultOrganization: DesktopOrganization = {
  id: "preview-org",
  name: "Clumsies Lab",
};
const previewAccount: DesktopAccount = {
  userId: "preview-user",
  email: "weiwang@example.com",
  displayName: "Wei Wang",
  avatarUrl: null,
};

const primaryNavigation: NavigationItem[] = [
  { view: "Hub", label: "Hub", icon: Cloud },
  { view: "Local", label: "Local", icon: FolderKanban },
  { view: "Bundles", label: "Bundles", icon: Package },
  { view: "Reviews", label: "Reviews", icon: GitPullRequest },
];

const previewProjects: ProjectOption[] = [
  { id: "koal", name: "Koal", refCommitId: null },
  { id: "infinite", name: "Infinite", refCommitId: null },
  { id: "clumsies", name: "Clumsies", refCommitId: null },
  { id: "pi-mono", name: "Pi Mono", refCommitId: null },
  { id: "aider", name: "Aider", refCommitId: null },
  { id: "okra", name: "Okra", refCommitId: null },
  { id: "hands-on-os", name: "Hands on OS", refCommitId: null },
];

const projectPreviewLimit = 3;

const kindIcons: Record<MemoryKind, LucideIcon> = {
  Context: FileText,
  Rules: CircleDot,
  Workflows: ListChecks,
  Metaprompt: Bot,
};

const reviewFilters: ReviewFilter[] = ["open", "approved", "rejected", "merged"];

const reviewFilterIcons: Record<ReviewFilter, LucideIcon> = {
  open: GitPullRequest,
  approved: CheckCircle2,
  rejected: X,
  merged: GitMerge,
};

const initialWorkspaceTab: WorkspaceTab = {
  key: memoryTabKey("Local", "project-context-daemon", "source"),
  view: "Local",
  targetId: "project-context-daemon",
  kind: "Context",
  projectId: "koal",
  surface: "source",
  pinned: true,
};

function isTauriRuntime(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

export function App() {
  const previewMode = !isTauriRuntime();
  const backendRef = useRef<DesktopBackend | null>(null);
  if (!previewMode && backendRef.current === null) {
    const nativeInvoke: NativeInvoke = <T,>(
      command: string,
      args?: Record<string, unknown>,
    ) => invoke<T>(command, args);
    backendRef.current = new DesktopBackend(nativeInvoke);
  }
  const [selectedView, setSelectedView] = useState<View>("Local");
  const [projects, setProjects] = useState<ProjectOption[]>(
    previewMode ? previewProjects : [],
  );
  const [account, setAccount] = useState<DesktopAccount | null>(
    previewMode ? previewAccount : null,
  );
  const [organization, setOrganization] = useState(defaultOrganization);
  const [selectedProjectId, setSelectedProjectId] = useState(
    previewMode ? "koal" : "",
  );
  const [hubRefCommitId, setHubRefCommitId] = useState<string | null>(null);
  const [hubKind, setHubKind] = useState<MemoryKind>("Context");
  const [projectKind, setProjectKind] = useState<MemoryKind>("Context");
  const [selectedHubId, setSelectedHubId] = useState<string | null>(
    previewMode ? "hub-context-desktop-product" : null,
  );
  const [selectedProjectResourceId, setSelectedProjectResourceId] = useState<
    string | null
  >(previewMode ? "project-context-daemon" : null);
  const [resources, setResources] =
    useState<AuthorityResource[]>(previewMode ? initialResources : []);
  const [drafts, setDrafts] = useState<DraftRecord[]>(
    previewMode ? initialDrafts : [],
  );
  const [reviews, setReviews] = useState<ReviewRecord[]>(
    previewMode ? initialReviews : [],
  );
  const [bundles, setBundles] = useState<PersonalBundle[]>(
    previewMode ? initialBundles : [],
  );
  const [selectedBundleId, setSelectedBundleId] = useState(
    previewMode ? (initialBundles[0]?.id ?? "") : "",
  );
  const [reviewFilter, setReviewFilter] = useState<ReviewFilter>("open");
  const [selectedReviewId, setSelectedReviewId] = useState(
    previewMode ? (initialReviews[0]?.id ?? "") : "",
  );
  const [workspaceTabs, setWorkspaceTabs] = useState<WorkspaceTab[]>(
    previewMode ? [initialWorkspaceTab] : [],
  );
  const [activeTabKey, setActiveTabKey] = useState<string | null>(
    previewMode ? initialWorkspaceTab.key : null,
  );
  const [searchQuery, setSearchQuery] = useState("");
  const [searchOpen, setSearchOpen] = useState(false);
  const [agentOpen, setAgentOpen] = useState(false);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(() => {
    try {
      return window.localStorage.getItem("clumsies.sidebar.collapsed") === "true";
    } catch {
      return false;
    }
  });
  const [userMenuOpen, setUserMenuOpen] = useState(false);
  const [agentWidth, setAgentWidth] = useState(320);
  const [sourceWidth, setSourceWidth] = useState(244);
  const [confirmState, setConfirmState] = useState<ConfirmState | null>(null);
  const [undoState, setUndoState] = useState<UndoState | null>(null);
  const [bundlePickerOpen, setBundlePickerOpen] = useState(false);
  const [loadState, setLoadState] = useState<LoadState>({ status: "loading" });

  const searchRef = useRef<HTMLInputElement>(null);
  const draftSyncTimers = useRef(new Map<string, number>());
  const bundleSyncTimers = useRef(new Map<string, number>());
  const undoTimer = useRef<number | null>(null);

  const refreshBackend = useCallback(async () => {
    const backend = backendRef.current;
    if (!backend) {
      setLoadState({ status: "preview" });
      return;
    }
    setLoadState({ status: "loading" });
    try {
      const backendState = await backend.load();
      setAccount(backendState.account);
      setOrganization(backendState.organization);
      setProjects(backendState.projects);
      setHubRefCommitId(backendState.orgRefCommitId);
      setResources(backendState.resources);
      setDrafts(backendState.drafts);
      setBundles(backendState.bundles);
      setReviews(backendState.reviews);
      setSelectedProjectId(backendState.activeProjectId ?? "");
      setSelectedBundleId(backendState.bundles[0]?.id ?? "");
      setSelectedReviewId(backendState.reviews[0]?.id ?? "");

      const firstProjectItem = backendState.resources.find(
        (resource) =>
          resource.scope === "Project" &&
          resource.projectId === backendState.activeProjectId,
      );
      const firstDraft = backendState.drafts.find(
        (draft) => draft.projectId === backendState.activeProjectId,
      );
      const initialItem = firstProjectItem ?? firstDraft ?? null;
      if (initialItem) {
        const targetId =
          "baseResourceId" in initialItem
            ? (initialItem.baseResourceId ?? initialItem.id)
            : initialItem.id;
        const tab: WorkspaceTab = {
          key: memoryTabKey("Local", targetId, "source"),
          view: "Local",
          targetId,
          kind: initialItem.kind,
          projectId: initialItem.projectId,
          surface: "source",
          pinned: true,
        };
        setProjectKind(initialItem.kind);
        setSelectedProjectResourceId(targetId);
        setWorkspaceTabs([tab]);
        setActiveTabKey(tab.key);
      } else {
        setSelectedProjectResourceId(null);
        setWorkspaceTabs([]);
        setActiveTabKey(null);
      }
      setLoadState({
        status: "ready",
        bootstrap: backendState.runtime.bootstrap,
        health: backendState.runtime.health,
        projectConfig: backendState.runtime.projectConfig,
        syncStatus: backendState.runtime.syncStatus,
        mcpStatus: backendState.runtime.mcpStatus,
      });
    } catch (error) {
      if (error instanceof AuthenticationRequiredError) {
        setAccount(null);
        setLoadState({
          status: "authentication_required",
        });
        return;
      }
      setLoadState({
        status: "failed",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }, []);

  const runDaemonCommand = useCallback(async (command: string) => {
    const backend = backendRef.current;
    if (!backend) {
      setLoadState({ status: "preview" });
      return;
    }
    setLoadState({ status: "loading" });
    try {
      const commands: Record<string, () => Promise<DaemonBootstrapStatus>> = {
        install_daemon_launch_agent: backend.daemon.install,
        start_daemon_launch_agent: backend.daemon.start,
        restart_daemon_launch_agent: backend.daemon.restart,
        stop_daemon_launch_agent: backend.daemon.stop,
      };
      const run = commands[command];
      if (!run) {
        throw new Error(`Unknown daemon command: ${command}`);
      }
      const bootstrap = await run();
      if (command === "start_daemon_launch_agent" || command === "restart_daemon_launch_agent") {
        await refreshBackend();
      } else {
        setLoadState({
          status: "ready",
          bootstrap,
          health: null,
          projectConfig: null,
          syncStatus: null,
          mcpStatus: null,
        });
      }
    } catch (error) {
      setLoadState({
        status: "failed",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }, [refreshBackend]);

  const retryDaemonSync = useCallback(async () => {
    const backend = backendRef.current;
    if (!backend) {
      return;
    }
    setLoadState({ status: "loading" });
    try {
      await backend.daemon.retrySync({ channel: "all" });
      await refreshBackend();
    } catch (error) {
      setLoadState({
        status: "failed",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }, [refreshBackend]);

  const authenticateDesktop = useCallback(async () => {
    const backend = backendRef.current;
    if (!backend) {
      return;
    }
    setLoadState({ status: "loading" });
    try {
      await backend.authenticate();
      await refreshBackend();
    } catch (error) {
      setLoadState({
        status: "authentication_required",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }, [refreshBackend]);

  useEffect(() => {
    void refreshBackend();
  }, [refreshBackend]);

  useEffect(() => {
    try {
      window.localStorage.setItem(
        "clumsies.sidebar.collapsed",
        String(sidebarCollapsed),
      );
    } catch {
      // The layout still works when persistent browser storage is unavailable.
    }
  }, [sidebarCollapsed]);

  useEffect(
    () => () => {
      for (const timer of draftSyncTimers.current.values()) {
        window.clearTimeout(timer);
      }
      for (const timer of bundleSyncTimers.current.values()) {
        window.clearTimeout(timer);
      }
      if (undoTimer.current !== null) {
        window.clearTimeout(undoTimer.current);
      }
    },
    [],
  );

  const showUndo = useCallback((state: UndoState) => {
    if (undoTimer.current !== null) {
      window.clearTimeout(undoTimer.current);
    }
    setUndoState(state);
    undoTimer.current = window.setTimeout(() => setUndoState(null), 7000);
  }, []);

  useEffect(() => {
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setSearchOpen(true);
      }
      if (
        (event.metaKey || event.ctrlKey) &&
        event.shiftKey &&
        event.key.toLowerCase() === "a"
      ) {
        event.preventDefault();
        setAgentOpen((current) => !current);
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "z") {
        const target = event.target;
        const editingText =
          target instanceof HTMLElement &&
          (target.isContentEditable || target.tagName === "INPUT" || target.tagName === "TEXTAREA");
        if (undoState && !editingText) {
          event.preventDefault();
          undoState.run();
          setUndoState(null);
        }
      }
      if (event.key === "Escape") {
        setSearchOpen(false);
        setBundlePickerOpen(false);
        setConfirmState(null);
        setUserMenuOpen(false);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [undoState]);

  useEffect(() => {
    if (!searchOpen) {
      return;
    }
    const frame = window.requestAnimationFrame(() => {
      searchRef.current?.focus();
      searchRef.current?.select();
    });
    return () => window.cancelAnimationFrame(frame);
  }, [searchOpen]);

  const queueDraftSync = useCallback((draft: DraftRecord, resource: AuthorityResource | null) => {
    const previous = draftSyncTimers.current.get(draft.id);
    if (previous !== undefined) {
      window.clearTimeout(previous);
    }
    const timer = window.setTimeout(async () => {
      const backend = backendRef.current;
      if (!backend) {
        setDrafts((current) =>
          current.map((item) =>
            item.id === draft.id && item.syncState !== "conflict"
              ? { ...item, syncState: "synced", updatedAt: "just now" }
              : item,
          ),
        );
        draftSyncTimers.current.delete(draft.id);
        return;
      }
      try {
        let localId = draft.localId ?? null;
        for (const request of daemonOperationsForDraft(draft, resource)) {
          const response = await backend.daemon.storeDraftOperation(request);
          localId = response.draft_id;
        }
        if (!localId) {
          draftSyncTimers.current.delete(draft.id);
          return;
        }
        setDrafts((current) =>
          current.map((item) =>
            item.id === draft.id
              ? { ...item, localId, syncState: "syncing", updatedAt: "just now" }
              : item,
          ),
        );

        const poll = (attempt: number) => {
          const pollTimer = window.setTimeout(async () => {
            try {
              const detail = await backend.daemon.draft(localId);
              const syncState = syncStateForDaemonDraft(detail);
              setDrafts((current) =>
                current.map((item) =>
                  item.id === draft.id
                    ? {
                        ...item,
                        localId,
                        serverId: detail.draft.server_draft_id,
                        serverVersion: detail.draft.server_version,
                        syncState,
                        updatedAt: "just now",
                      }
                    : item,
                ),
              );
              if (syncState === "syncing" && attempt < 20) {
                poll(attempt + 1);
              } else {
                draftSyncTimers.current.delete(draft.id);
              }
            } catch {
              setDrafts((current) =>
                current.map((item) =>
                  item.id === draft.id ? { ...item, syncState: "failed" } : item,
                ),
              );
              draftSyncTimers.current.delete(draft.id);
            }
          }, 500);
          draftSyncTimers.current.set(draft.id, pollTimer);
        };
        poll(0);
      } catch {
        setDrafts((current) =>
          current.map((item) =>
            item.id === draft.id ? { ...item, syncState: "failed" } : item,
          ),
        );
        draftSyncTimers.current.delete(draft.id);
      }
    }, 650);
    draftSyncTimers.current.set(draft.id, timer);
  }, []);

  const queueBundleSync = useCallback((bundle: PersonalBundle) => {
    const previous = bundleSyncTimers.current.get(bundle.id);
    if (previous !== undefined) {
      window.clearTimeout(previous);
    }
    const timer = window.setTimeout(async () => {
      const backend = backendRef.current;
      if (!backend?.api || bundle.revision === undefined) {
        setBundles((current) =>
          current.map((item) =>
            item.id === bundle.id
              ? { ...item, syncState: backend ? "failed" : "synced", updatedAt: "just now" }
              : item,
          ),
        );
        bundleSyncTimers.current.delete(bundle.id);
        return;
      }
      const selected = resources.filter((resource) =>
        bundle.resourceIds.includes(resource.id),
      );
      try {
        const detail = await backend.api.updateBundle(bundle.id, bundle.revision, {
          name: bundle.name,
          description: bundle.description,
          rule_ids: selected.filter((item) => item.kind === "Rules").map((item) => item.id),
          context_ids: selected.filter((item) => item.kind === "Context").map((item) => item.id),
          workflow_ids: selected
            .filter((item) => item.kind === "Workflows")
            .map((item) => item.id),
        });
        const saved = mapBundle(detail);
        setBundles((current) =>
          current.map((item) => (item.id === bundle.id ? saved : item)),
        );
      } catch {
        setBundles((current) =>
          current.map((item) =>
            item.id === bundle.id ? { ...item, syncState: "failed" } : item,
          ),
        );
      }
      bundleSyncTimers.current.delete(bundle.id);
    }, 500);
    bundleSyncTimers.current.set(bundle.id, timer);
  }, [resources]);

  const showWorkspaceTab = useCallback((tab: WorkspaceTab, pin = tab.pinned) => {
    setWorkspaceTabs((current) => openWorkspaceTab(current, tab, pin));
    setActiveTabKey(tab.key);
  }, []);

  const pinWorkspaceTabByKey = useCallback((key: string) => {
    setWorkspaceTabs((current) => pinWorkspaceTab(current, key));
  }, []);

  const removeWorkspaceTabByKey = useCallback((key: string) => {
    setWorkspaceTabs((current) => current.filter((tab) => tab.key !== key));
    setActiveTabKey((current) => (current === key ? null : current));
  }, []);

  const removeMemoryWorkspaceTabs = useCallback(
    (view: "Hub" | "Local", targetId: string) => {
      const sourceKey = memoryTabKey(view, targetId, "source");
      const previewKey = memoryTabKey(view, targetId, "markdown-preview");
      setWorkspaceTabs((current) =>
        current.filter((tab) => tab.key !== sourceKey && tab.key !== previewKey),
      );
      setActiveTabKey((current) =>
        current === sourceKey || current === previewKey ? null : current,
      );
    },
    [],
  );

  const openMemoryWorkspaceTab = useCallback(
    (
      view: "Hub" | "Local",
      targetId: string,
      kind: MemoryKind,
      projectId: string | null,
      pin = false,
    ) => {
      const tab: WorkspaceTab = {
        key: memoryTabKey(view, targetId, "source"),
        view,
        targetId,
        kind,
        projectId,
        surface: "source",
        pinned: pin,
      };
      setSelectedView(view);
      if (view === "Hub") {
        setHubKind(kind);
        setSelectedHubId(targetId);
      } else {
        setSelectedProjectId(projectId ?? "koal");
        setProjectKind(kind);
        setSelectedProjectResourceId(targetId);
      }
      showWorkspaceTab(tab, pin);
    },
    [showWorkspaceTab],
  );

  const openMarkdownPreview = useCallback(
    (item: ResourceListItem) => {
      const view = item.scope === "Hub" ? "Hub" : "Local";
      showWorkspaceTab(
        {
          key: memoryTabKey(view, item.selectionId, "markdown-preview"),
          view,
          targetId: item.selectionId,
          kind: item.kind,
          projectId: item.projectId,
          surface: "markdown-preview",
          pinned: true,
        },
        true,
      );
    },
    [showWorkspaceTab],
  );

  const hubItems = useMemo(
    () => listResources(resources, drafts, "Hub", null, hubKind),
    [drafts, hubKind, resources],
  );
  const projectItems = useMemo(
    () =>
      listResources(resources, drafts, "Project", selectedProjectId, projectKind),
    [drafts, projectKind, resources, selectedProjectId],
  );
  const selectedHubItem = findListItem(hubItems, selectedHubId);
  const selectedProjectItem = findListItem(
    projectItems,
    selectedProjectResourceId,
  );

  useEffect(() => {
    if (selectedHubItem && selectedHubItem.selectionId !== selectedHubId) {
      setSelectedHubId(selectedHubItem.selectionId);
    }
  }, [selectedHubId, selectedHubItem]);

  useEffect(() => {
    if (
      selectedProjectItem &&
      selectedProjectItem.selectionId !== selectedProjectResourceId
    ) {
      setSelectedProjectResourceId(selectedProjectItem.selectionId);
    }
  }, [selectedProjectItem, selectedProjectResourceId]);

  const updateDocument = useCallback(
    (
      item: ResourceListItem,
      update: (document: MemoryDocument) => MemoryDocument,
    ) => {
      if (item.draft?.status === "in_review") {
        return;
      }
      const baseDraft = item.draft
        ? { ...item.draft, document: cloneDocument(item.draft.document) }
        : item.resource
          ? createDraftFromResource(item.resource)
          : null;
      const project =
        projects.find((entry) => entry.id === selectedProjectId) ?? projects[0] ?? null;
      const startingDraft =
        baseDraft?.scope === "Hub" && !baseDraft.projectId && project
          ? { ...baseDraft, projectId: project.id, projectName: project.name }
          : baseDraft;
      if (!startingDraft) {
        return;
      }
      const draftId = startingDraft.id;
      pinWorkspaceTabByKey(
        memoryTabKey(
          item.scope === "Hub" ? "Hub" : "Local",
          item.selectionId,
          "source",
        ),
      );
      const updated: DraftRecord = {
        ...startingDraft,
        operation: "upsert",
        syncState: "syncing",
        updatedAt: "just now",
        document: update(cloneDocument(startingDraft.document)),
      };
      setDrafts((current) =>
        current.some((draft) => draft.id === draftId)
          ? current.map((draft) => (draft.id === draftId ? updated : draft))
          : [updated, ...current],
      );
      queueDraftSync(updated, item.resource);
    },
    [pinWorkspaceTabByKey, projects, queueDraftSync, selectedProjectId],
  );

  const createMemoryDraft = useCallback(
    (scope: MemoryScope, kind: MemoryKind) => {
      const project =
        projects.find((item) => item.id === selectedProjectId) ?? projects[0] ?? null;
      if (!project) {
        setLoadState({
          status: "failed",
          message: "A project is required to create a draft.",
        });
        return;
      }
      const baseCommitId =
        scope === "Hub"
          ? hubRefCommitId
          : project.refCommitId;
      const draft = {
        ...createBlankDraft(
          scope,
          kind,
          project.id,
          project.name,
          baseCommitId,
        ),
        syncState: "syncing" as const,
      };
      setDrafts((current) => [draft, ...current]);
      queueDraftSync(draft, null);
      openMemoryWorkspaceTab(
        scope === "Hub" ? "Hub" : "Local",
        draft.id,
        kind,
        project.id,
        true,
      );
    },
    [hubRefCommitId, openMemoryWorkspaceTab, projects, queueDraftSync, selectedProjectId],
  );

  const submitReview = useCallback(
    async (item: ResourceListItem) => {
      if (!item.draft || item.draft.status !== "editing") {
        return;
      }
      const backend = backendRef.current;
      let review: ReviewRecord;
      if (backend) {
        if (!backend.api || !item.draft.serverId || item.draft.serverVersion === undefined) {
          setDrafts((current) =>
            current.map((draft) =>
              draft.id === item.draft?.id ? { ...draft, syncState: "failed" } : draft,
            ),
          );
          return;
        }
        try {
          review = mapReviewSummary(
            await backend.api.createReview({
              draft_id: item.draft.serverId,
              expected_draft_version: item.draft.serverVersion,
              title: item.draft.document.title,
            }),
          );
        } catch {
          setDrafts((current) =>
            current.map((draft) =>
              draft.id === item.draft?.id ? { ...draft, syncState: "failed" } : draft,
            ),
          );
          return;
        }
      } else {
        review = {
          id: `review-${Date.now().toString(36)}`,
          draftId: item.draft.id,
          title: item.draft.document.title,
          author: "weiwang",
          status: "open",
          createdAt: "just now",
          decisionNote: null,
          comments: [],
        };
      }
      setDrafts((current) =>
        current.map((draft) =>
          draft.id === item.draft?.id
            ? { ...draft, status: "in_review", syncState: "synced" }
            : draft,
        ),
      );
      setReviews((current) => [review, ...current]);
      setReviewFilter("open");
      setSelectedReviewId(review.id);
      setSelectedView("Reviews");
      showWorkspaceTab(
        {
          key: `review:${review.id}`,
          view: "Reviews",
          targetId: review.id,
          pinned: true,
        },
        true,
      );
    },
    [showWorkspaceTab],
  );

  const openReviewForDraft = useCallback(
    (draftId: string) => {
      const draft = drafts.find((entry) => entry.id === draftId);
      const review = reviews.find(
        (entry) =>
          entry.draftId === draftId ||
          (draft?.serverId !== null && entry.draftId === draft?.serverId),
      );
      if (!review) {
        return;
      }
      setReviewFilter(review.status);
      setSelectedReviewId(review.id);
      setSelectedView("Reviews");
      showWorkspaceTab(
        {
          key: `review:${review.id}`,
          view: "Reviews",
          targetId: review.id,
          pinned: true,
        },
        true,
      );
    },
    [drafts, reviews, showWorkspaceTab],
  );

  const discardDraft = useCallback(
    (item: ResourceListItem) => {
      if (!item.draft || item.draft.status === "in_review") {
        return;
      }
      const removed = item.draft;
      setConfirmState({
        title: "Discard draft?",
        message:
          "The published resource is unchanged. You can undo this action for a short time.",
        confirmLabel: "Discard Draft",
        tone: "danger",
        onConfirm: async () => {
          const backend = backendRef.current;
          const request = daemonDiscardOperationForDraft(removed);
          if (backend && request) {
            try {
              await backend.daemon.storeDraftOperation(request);
            } catch {
              setDrafts((current) =>
                current.map((draft) =>
                  draft.id === removed.id ? { ...draft, syncState: "failed" } : draft,
                ),
              );
              setConfirmState(null);
              return;
            }
          }
          setDrafts((current) => current.filter((draft) => draft.id !== removed.id));
          setConfirmState(null);
          if (!item.resource) {
            removeMemoryWorkspaceTabs(
              item.scope === "Hub" ? "Hub" : "Local",
              removed.id,
            );
            if (item.scope === "Hub") {
              setSelectedHubId(null);
            } else {
              setSelectedProjectResourceId(null);
            }
          }
          if (!backend) {
            showUndo({
              message: "Draft discarded",
              run: () => setDrafts((current) => [removed, ...current]),
            });
          }
        },
      });
    },
    [removeMemoryWorkspaceTabs, showUndo],
  );

  const proposeDeletion = useCallback(
    (item: ResourceListItem) => {
      if (!item.resource || item.draft?.status === "in_review") {
        return;
      }
      setConfirmState({
        title: "Propose deletion?",
        message:
          "This creates a personal deletion draft. The published resource remains unchanged until the review is merged.",
        confirmLabel: "Create Draft",
        onConfirm: () => {
          const startingDraft = item.draft ?? createDraftFromResource(item.resource!);
          const updated = {
            ...startingDraft,
            operation: "delete" as const,
            syncState: "syncing" as const,
            updatedAt: "just now",
          };
          setDrafts((current) => {
            const exists = current.some((draft) => draft.id === updated.id);
            return exists
              ? current.map((draft) => (draft.id === updated.id ? updated : draft))
              : [updated, ...current];
          });
          pinWorkspaceTabByKey(
            memoryTabKey(
              item.scope === "Hub" ? "Hub" : "Local",
              item.selectionId,
              "source",
            ),
          );
          queueDraftSync(updated, item.resource);
          setConfirmState(null);
        },
      });
    },
    [pinWorkspaceTabByKey, queueDraftSync],
  );

  const updateReviewStatus = useCallback(
    async (reviewId: string, status: ReviewStatus, note: string | null) => {
      const review = reviews.find((item) => item.id === reviewId);
      if (!review) {
        return;
      }
      const backend = backendRef.current;
      let saved = { ...review, status, decisionNote: note };
      if (backend) {
        if (!backend.api || review.version === undefined || status === "merged") {
          return;
        }
        try {
          const response = await backend.api.createReviewDecision(reviewId, {
            decision: status === "approved" ? "approved" : "rejected",
            expected_review_version: review.version,
            body: note ?? undefined,
          });
          saved = {
            ...mapReviewSummary(response),
            comments: review.comments,
            decisionNote: note,
          };
        } catch (error) {
          setLoadState({
            status: "failed",
            message: error instanceof Error ? error.message : "Review decision failed.",
          });
          return;
        }
      }
      setReviews((current) =>
        current.map((item) =>
          item.id === reviewId ? saved : item,
        ),
      );
      if (status === "rejected") {
        if (!backend) {
          setDrafts((current) =>
            current.map((draft) =>
              draft.id === review.draftId || draft.serverId === review.draftId
                ? { ...draft, status: "editing" }
                : draft,
            ),
          );
        }
        setReviewFilter("rejected");
      } else if (status === "approved") {
        setReviewFilter("approved");
      }
    },
    [reviews],
  );

  const mergeReview = useCallback(
    async (reviewId: string) => {
      const review = reviews.find((item) => item.id === reviewId);
      const draft = drafts.find(
        (item) => item.id === review?.draftId || item.serverId === review?.draftId,
      );
      if (!review || !draft || review.status !== "approved") {
        return;
      }
      const backend = backendRef.current;
      let mergedCommitId: string | null = null;
      if (backend) {
        if (!backend.api || review.version === undefined) {
          return;
        }
        try {
          if (!draft.projectId) {
            return;
          }
          const commitState =
            draft.scope === "Hub"
              ? await backend.api.orgCommitState()
              : await backend.api.projectCommitState(draft.projectId);
          const merge = await backend.api.createReviewMerge(
            reviewId,
            commitState.etag,
            { expected_review_version: review.version },
          );
          mergedCommitId = merge.commit_id;
        } catch (error) {
          if (error instanceof ClumsiesApiError && apiErrorCode(error) === "draft_conflict") {
            try {
              const detail = await backend.api.review(reviewId);
              const conflictedReview = await mapReviewWithConflict(backend.api, detail);
              setReviews((current) =>
                current.map((item) => (item.id === reviewId ? conflictedReview : item)),
              );
              setDrafts((current) =>
                current.map((item) =>
                  item.id === draft.id
                    ? {
                        ...item,
                        serverVersion: detail.draft.version,
                        status: "in_review",
                        syncState: "conflict",
                        conflict: conflictedReview.conflict
                          ? {
                              baseCommitId: conflictedReview.conflict.baseCommitId,
                              currentCommitId: conflictedReview.conflict.currentCommitId,
                              detectedAt: conflictedReview.conflict.detectedAt,
                            }
                          : null,
                      }
                    : item,
                ),
              );
              setReviewFilter("approved");
            } catch {
              setLoadState({ status: "failed", message: "Conflict details could not be loaded." });
            }
          } else {
            setLoadState({
              status: "failed",
              message: error instanceof Error ? error.message : "Review merge failed.",
            });
          }
          return;
        }
      }
      setResources((current) => {
        const applied = applyDraft(current, draft);
        if (!mergedCommitId) {
          return applied;
        }
        return applied.map((resource) =>
          resource.scope === draft.scope &&
          (draft.scope === "Hub" || resource.projectId === draft.projectId)
            ? { ...resource, refCommitId: mergedCommitId }
            : resource,
        );
      });
      if (mergedCommitId) {
        if (draft.scope === "Hub") {
          setHubRefCommitId(mergedCommitId);
        } else {
          setProjects((current) =>
            current.map((project) =>
              project.id === draft.projectId
                ? { ...project, refCommitId: mergedCommitId }
                : project,
            ),
          );
        }
      }
      const memoryView = draft.scope === "Hub" ? "Hub" : "Local";
      if (draft.operation === "delete" && draft.baseResourceId) {
        removeMemoryWorkspaceTabs(memoryView, draft.baseResourceId);
      } else if (!draft.baseResourceId) {
        const resourceId = `memory-${draft.id}`;
        setWorkspaceTabs((current) =>
          retargetMemoryTabs(current, memoryView, draft.id, resourceId),
        );
        setActiveTabKey((current) => {
          if (current === memoryTabKey(memoryView, draft.id, "source")) {
            return memoryTabKey(memoryView, resourceId, "source");
          }
          if (current === memoryTabKey(memoryView, draft.id, "markdown-preview")) {
            return memoryTabKey(memoryView, resourceId, "markdown-preview");
          }
          return current;
        });
        if (memoryView === "Hub") {
          setSelectedHubId(resourceId);
        } else {
          setSelectedProjectResourceId(resourceId);
        }
      }
      setDrafts((current) =>
        current.map((item) =>
          item.id === draft.id ? { ...item, status: "merged", syncState: "synced" } : item,
        ),
      );
      setReviews((current) =>
        current.map((item) =>
          item.id === reviewId ? { ...item, status: "merged" } : item,
        ),
      );
      setReviewFilter("merged");
    },
    [drafts, removeMemoryWorkspaceTabs, reviews],
  );

  const resolveReviewConflict = useCallback(
    async (reviewId: string, resolvedContent: string | null) => {
      const review = reviews.find((item) => item.id === reviewId);
      const draft = drafts.find(
        (item) => item.id === review?.draftId || item.serverId === review?.draftId,
      );
      if (
        !review?.conflict
        || review.version === undefined
        || review.draftVersion === undefined
        || !review.operations?.length
        || !draft
      ) {
        return;
      }

      const operations = review.operations.map((operation) => ({
        action: operation.action,
        resource: operation.resource,
        base_hash: operation.baseHash,
        body: operation.body,
        new_path: operation.newPath,
      }));
      if (resolvedContent !== null) {
        let bodyOperationIndex = -1;
        for (let index = operations.length - 1; index >= 0; index -= 1) {
          if (operations[index]?.action === "create" || operations[index]?.action === "update") {
            bodyOperationIndex = index;
            break;
          }
        }
        if (bodyOperationIndex < 0) {
          return;
        }
        operations[bodyOperationIndex] = {
          ...operations[bodyOperationIndex],
          body: resolvedContent,
        };
      }

      const backend = backendRef.current;
      if (backend?.api) {
        try {
          const detail = await backend.api.createReviewConflictResolution(
            reviewId,
            refEtag(review.conflict.currentCommitId),
            {
              expected_review_version: review.version,
              expected_draft_version: review.draftVersion,
              operations,
            },
          );
          const resolvedReview = await mapReviewWithConflict(backend.api, detail);
          setReviews((current) =>
            current.map((item) => (item.id === reviewId ? resolvedReview : item)),
          );
          setDrafts((current) =>
            current.map((item) =>
              item.id === draft.id
                ? {
                    ...item,
                    baseCommitId: review.conflict?.currentCommitId ?? null,
                    serverVersion: detail.draft.version,
                    status: "in_review",
                    syncState: "synced",
                    conflict: null,
                    document:
                      resolvedContent === null
                        ? item.document
                        : { ...item.document, body: resolvedContent },
                  }
                : item,
            ),
          );
          setReviewFilter("open");
        } catch (error) {
          setLoadState({
            status: "failed",
            message:
              error instanceof ClumsiesApiError && error.status === 412
                ? "The current Ref changed. Refresh the conflict before resolving it."
                : error instanceof Error
                  ? error.message
                  : "Conflict resolution failed.",
          });
        }
        return;
      }

      setReviews((current) =>
        current.map((item) =>
          item.id === reviewId ? { ...item, status: "open", conflict: null } : item,
        ),
      );
      setReviewFilter("open");
    },
    [drafts, reviews],
  );

  const discardReviewConflict = useCallback(
    async (reviewId: string) => {
      const review = reviews.find((item) => item.id === reviewId);
      const draft = drafts.find(
        (item) => item.id === review?.draftId || item.serverId === review?.draftId,
      );
      if (!review?.conflict || review.draftVersion === undefined || !draft) {
        return;
      }
      const backend = backendRef.current;
      if (backend?.api) {
        try {
          await backend.api.discardDraft(review.draftId, review.draftVersion);
          const detail = await backend.api.review(reviewId);
          const discardedReview = await mapReviewWithConflict(backend.api, detail);
          setReviews((current) =>
            current.map((item) => (item.id === reviewId ? discardedReview : item)),
          );
        } catch (error) {
          setLoadState({
            status: "failed",
            message: error instanceof Error ? error.message : "Draft discard failed.",
          });
          return;
        }
      } else {
        setReviews((current) =>
          current.map((item) =>
            item.id === reviewId
              ? { ...item, status: "rejected", conflict: null }
              : item,
          ),
        );
      }
      setDrafts((current) => current.filter((item) => item.id !== draft.id));
      setReviewFilter("rejected");
    },
    [drafts, reviews],
  );

  const addReviewComment = useCallback(async (reviewId: string, body: string) => {
    const trimmed = body.trim();
    if (!trimmed) {
      return;
    }
    const backend = backendRef.current;
    if (backend) {
      if (!backend.api) {
        return;
      }
      try {
        const comment = await backend.api.createReviewComment(reviewId, {
          body: trimmed,
        });
        setReviews((current) =>
          current.map((review) =>
            review.id === reviewId
              ? {
                  ...review,
                  comments: [
                    ...review.comments,
                    {
                      id: comment.comment_id,
                      author: comment.author.display_name ?? comment.author.email,
                      body: comment.body,
                      createdAt: comment.created_at.slice(0, 10),
                    },
                  ],
                }
              : review,
          ),
        );
      } catch {
        return;
      }
      return;
    }
    setReviews((current) =>
      current.map((review) =>
        review.id === reviewId
          ? {
              ...review,
              comments: [
                ...review.comments,
                {
                  id: `comment-${Date.now().toString(36)}`,
                  author: "weiwang",
                  body: trimmed,
                  createdAt: "just now",
                },
              ],
            }
          : review,
      ),
    );
  }, []);

  const updateBundle = useCallback(
    (bundleId: string, update: (bundle: PersonalBundle) => PersonalBundle) => {
      const bundle = bundles.find((item) => item.id === bundleId);
      if (!bundle) {
        return;
      }
      const updated = {
        ...update(bundle),
        syncState: "syncing" as const,
        updatedAt: "just now",
      };
      pinWorkspaceTabByKey(`bundle:${bundleId}`);
      setBundles((current) =>
        current.map((item) => (item.id === bundleId ? updated : item)),
      );
      queueBundleSync(updated);
    },
    [bundles, pinWorkspaceTabByKey, queueBundleSync],
  );

  const createBundle = useCallback(async () => {
    const backend = backendRef.current;
    let bundle: PersonalBundle;
    if (backend) {
      if (!backend.api) {
        return;
      }
      try {
        bundle = mapBundle(
          await backend.api.createBundle({
            name: "Untitled bundle",
            description: "",
            rule_ids: [],
            context_ids: [],
            workflow_ids: [],
          }),
        );
      } catch {
        return;
      }
    } else {
      bundle = {
        id: `bundle-${Date.now().toString(36)}`,
        name: "Untitled bundle",
        description: "",
        resourceIds: [],
        syncState: "syncing",
        updatedAt: "just now",
      };
    }
    setBundles((current) => [bundle, ...current]);
    setSelectedBundleId(bundle.id);
    setSelectedView("Bundles");
    showWorkspaceTab(
      {
        key: `bundle:${bundle.id}`,
        view: "Bundles",
        targetId: bundle.id,
        pinned: true,
      },
      true,
    );
    if (!backend) {
      queueBundleSync(bundle);
    }
  }, [queueBundleSync, showWorkspaceTab]);

  const deleteBundle = useCallback(
    (bundle: PersonalBundle) => {
      setConfirmState({
        title: "Delete bundle?",
        message: "This only removes your personal selection set. It does not delete resources.",
        confirmLabel: "Delete Bundle",
        tone: "danger",
        onConfirm: async () => {
          const backend = backendRef.current;
          if (backend) {
            if (!backend.api || bundle.revision === undefined) {
              return;
            }
            try {
              await backend.api.deleteBundle(bundle.id, bundle.revision);
            } catch {
              return;
            }
          }
          setBundles((current) => current.filter((item) => item.id !== bundle.id));
          removeWorkspaceTabByKey(`bundle:${bundle.id}`);
          setSelectedBundleId("");
          setConfirmState(null);
          if (!backend) {
            showUndo({
              message: "Bundle deleted",
              run: () => setBundles((current) => [bundle, ...current]),
            });
          }
        },
      });
    },
    [removeWorkspaceTabByKey, showUndo],
  );

  const searchResults = useMemo(
    () => globalSearch(searchQuery, resources, drafts, bundles, reviews),
    [bundles, drafts, resources, reviews, searchQuery],
  );

  const openDraft = useCallback(
    (draft: DraftRecord, pin = true) => {
      openMemoryWorkspaceTab(
        draft.scope === "Hub" ? "Hub" : "Local",
        draft.baseResourceId ?? draft.id,
        draft.kind,
        draft.projectId,
        pin,
      );
    },
    [openMemoryWorkspaceTab],
  );

  const openSearchResult = useCallback(
    (result: SearchResult) => {
      setSearchOpen(false);
      setSearchQuery("");
      if (result.type === "memory") {
        const resource = resources.find((item) => item.id === result.id);
        if (!resource) {
          return;
        }
        if (resource.scope === "Hub") {
          openMemoryWorkspaceTab("Hub", resource.id, resource.kind, null);
        } else {
          openMemoryWorkspaceTab(
            "Local",
            resource.id,
            resource.kind,
            resource.projectId,
          );
        }
      } else if (result.type === "draft") {
        const draft = drafts.find((item) => item.id === result.id);
        if (draft) {
          openDraft(draft, false);
        }
      } else if (result.type === "bundle") {
        setSelectedView("Bundles");
        setSelectedBundleId(result.id);
        showWorkspaceTab({
          key: `bundle:${result.id}`,
          view: "Bundles",
          targetId: result.id,
          pinned: false,
        });
      } else {
        const review = reviews.find((item) => item.id === result.id);
        setSelectedView("Reviews");
        setSelectedReviewId(result.id);
        showWorkspaceTab({
          key: `review:${result.id}`,
          view: "Reviews",
          targetId: result.id,
          pinned: false,
        });
        if (review) {
          setReviewFilter(review.status);
        }
      }
    },
    [drafts, openDraft, openMemoryWorkspaceTab, resources, reviews, showWorkspaceTab],
  );

  const selectedBundle =
    bundles.find((bundle) => bundle.id === selectedBundleId) ?? bundles[0] ?? null;
  const filteredReviews = reviews.filter((review) => review.status === reviewFilter);
  const selectedReview =
    filteredReviews.find((review) => review.id === selectedReviewId) ??
    filteredReviews[0] ??
    null;
  const activeWorkspaceTab =
    workspaceTabs.find((tab) => tab.key === activeTabKey) ?? null;
  const currentHubItem =
    activeWorkspaceTab?.view === "Hub"
      ? findMemoryTabItem(activeWorkspaceTab, resources, drafts)
      : null;
  const currentProjectItem =
    activeWorkspaceTab?.view === "Local"
      ? findMemoryTabItem(activeWorkspaceTab, resources, drafts)
      : null;
  const currentBundle =
    activeWorkspaceTab?.view === "Bundles"
      ? bundles.find((bundle) => bundle.id === activeWorkspaceTab.targetId) ?? null
      : null;
  const currentReview =
    activeWorkspaceTab?.view === "Reviews"
      ? reviews.find((review) => review.id === activeWorkspaceTab.targetId) ?? null
      : null;
  const currentReviewDraft = currentReview
    ? drafts.find(
        (draft) =>
          draft.id === currentReview.draftId || draft.serverId === currentReview.draftId,
      ) ?? null
    : null;
  const currentReviewResource = currentReviewDraft?.baseResourceId
    ? resources.find((resource) => resource.id === currentReviewDraft.baseResourceId) ?? null
    : null;

  useEffect(() => {
    if (selectedReview && selectedReview.id !== selectedReviewId) {
      setSelectedReviewId(selectedReview.id);
    }
  }, [selectedReview, selectedReviewId]);

  const workspaceTabPresentations = useMemo<WorkspaceTabPresentation[]>(
    () =>
      workspaceTabs.map((tab) => {
        if (tab.view === "Hub" || tab.view === "Local") {
          const item = findMemoryTabItem(tab, resources, drafts);
          const path = item?.document.path;
          const preview = tab.surface === "markdown-preview";
          return {
            tab,
            label: path
              ? `${fileNameFromPath(path)}${preview ? " Preview" : ""}`
              : "Missing resource",
            title: path ? `${path}${preview ? " · Preview" : ""}` : "Missing resource",
            syncState: item?.draft?.syncState,
          };
        }
        if (tab.view === "Bundles") {
          const bundle = bundles.find((entry) => entry.id === tab.targetId);
          return {
            tab,
            label: bundle?.name ?? "Missing bundle",
            title: bundle?.name ?? "Missing bundle",
            syncState: bundle?.syncState,
          };
        }
        const review = reviews.find((entry) => entry.id === tab.targetId);
        const draft = drafts.find(
          (entry) => entry.id === review?.draftId || entry.serverId === review?.draftId,
        );
        return {
          tab,
          label: draft
            ? fileNameFromPath(draft.document.path)
            : review?.title ?? "Missing review",
          title: draft?.document.path ?? review?.title ?? "Missing review",
          syncState: draft?.syncState,
        };
      }),
    [bundles, drafts, resources, reviews, workspaceTabs],
  );

  const activateWorkspaceTab = useCallback(
    (tab: WorkspaceTab) => {
      setActiveTabKey(tab.key);
      setSelectedView(tab.view);
      if (tab.view === "Hub") {
        setHubKind(tab.kind);
        setSelectedHubId(tab.targetId);
      } else if (tab.view === "Local") {
        setSelectedProjectId(tab.projectId ?? "koal");
        setProjectKind(tab.kind);
        setSelectedProjectResourceId(tab.targetId);
      } else if (tab.view === "Bundles") {
        setSelectedBundleId(tab.targetId);
      } else if (tab.view === "Reviews") {
        const review = reviews.find((entry) => entry.id === tab.targetId);
        setSelectedReviewId(tab.targetId);
        if (review) {
          setReviewFilter(review.status);
        }
      }
    },
    [reviews],
  );

  const closeWorkspaceTabByKey = useCallback(
    (key: string) => {
      const closing = workspaceTabs.find((tab) => tab.key === key);
      if (!closing) {
        return;
      }
      const scopedTabs = workspaceTabs.filter((tab) => tab.view === closing.view);
      const result = closeWorkspaceTab(scopedTabs, key, activeTabKey);
      setWorkspaceTabs((current) => current.filter((tab) => tab.key !== key));
      if (activeTabKey !== key) {
        return;
      }
      setActiveTabKey(result.activeKey);
      if (result.activeKey) {
        const next = result.tabs.find((tab) => tab.key === result.activeKey);
        if (next) {
          activateWorkspaceTab(next);
        }
      }
    },
    [activateWorkspaceTab, activeTabKey, workspaceTabs],
  );

  const navigateToView = useCallback(
    (view: View) => {
      if (view === "Diagnostics" || view === "Settings") {
        setSelectedView(view);
        setActiveTabKey(null);
        return;
      }
      const existing = [...workspaceTabs].reverse().find((tab) => tab.view === view);
      if (existing) {
        activateWorkspaceTab(existing);
        return;
      }
      if (view === "Hub") {
        const item = selectedHubItem ?? hubItems[0];
        if (item) {
          openMemoryWorkspaceTab("Hub", item.selectionId, item.kind, null);
          return;
        }
      } else if (view === "Local") {
        const item = selectedProjectItem ?? projectItems[0];
        if (item) {
          openMemoryWorkspaceTab(
            "Local",
            item.selectionId,
            item.kind,
            item.projectId,
          );
          return;
        }
      } else if (view === "Bundles" && selectedBundle) {
        setSelectedView(view);
        showWorkspaceTab({
          key: `bundle:${selectedBundle.id}`,
          view,
          targetId: selectedBundle.id,
          pinned: false,
        });
        return;
      } else if (view === "Reviews" && selectedReview) {
        setSelectedView(view);
        showWorkspaceTab({
          key: `review:${selectedReview.id}`,
          view,
          targetId: selectedReview.id,
          pinned: false,
        });
        return;
      }
      setSelectedView(view);
      setActiveTabKey(null);
    },
    [
      activateWorkspaceTab,
      hubItems,
      openMemoryWorkspaceTab,
      projectItems,
      selectedBundle,
      selectedHubItem,
      selectedProjectItem,
      selectedReview,
      showWorkspaceTab,
      workspaceTabs,
    ],
  );

  const selectProject = useCallback(
    (projectId: string) => {
      setUserMenuOpen(false);
      const item = listResources(
        resources,
        drafts,
        "Project",
        projectId,
        projectKind,
      )[0];
      if (item) {
        openMemoryWorkspaceTab(
          "Local",
          item.selectionId,
          item.kind,
          projectId,
        );
        return;
      }
      setSelectedProjectId(projectId);
      setSelectedProjectResourceId(null);
      setSelectedView("Local");
      setActiveTabKey(null);
    },
    [drafts, openMemoryWorkspaceTab, projectKind, resources],
  );

  const applyAgentToMemory = useCallback(
    (item: ResourceListItem) => {
      updateDocument(item, (document) => {
        const marker = "## Retrieval cues";
        if (document.body.includes(marker)) {
          return document;
        }
        return {
          ...document,
          body: `${document.body.trimEnd()}\n\n${marker}\n\n- Use this resource when the current task matches its scope and constraints.\n- Prefer durable decisions over task-only history.`,
          tags:
            item.kind === "Rules"
              ? Array.from(new Set([...document.tags, "retrieval-ready"]))
              : document.tags,
        };
      });
    },
    [updateDocument],
  );

  const agentTarget = useMemo<AgentTarget | null>(() => {
    if ((selectedView === "Hub" || selectedView === "Local")) {
      const item = selectedView === "Hub" ? currentHubItem : currentProjectItem;
      if (!item) {
        return null;
      }
      return {
        key: `memory-${item.selectionId}`,
        label: item.document.title,
        quickActions: ["Find durable facts", "Remove task-only details", "Add retrieval cues"],
        proposal:
          "Add a compact retrieval-cues section and preserve the existing document structure. The proposal will be applied to a personal draft, never to the published resource.",
        applyLabel: "Apply to Draft",
        onApply: () => applyAgentToMemory(item),
      };
    }
    if (selectedView === "Reviews" && currentReview) {
      return {
        key: `review-${currentReview.id}`,
        label: currentReview.title,
        quickActions: ["Summarize diff", "Check conflicts", "Draft review note"],
        proposal:
          "The change preserves the authority boundary and adds task-relevant retrieval guidance. No conflict with the selected base version is visible in this diff.",
        applyLabel: "Add Review Note",
        onApply: () =>
          addReviewComment(
            currentReview.id,
            "Agent review: The change preserves the authority boundary and adds task-relevant retrieval guidance. No conflict is visible in the current diff.",
          ),
      };
    }
    if (selectedView === "Bundles" && currentBundle) {
      const candidate = resources.find(
        (resource) =>
          resource.scope === "Hub" && !currentBundle.resourceIds.includes(resource.id),
      );
      return {
        key: `bundle-${currentBundle.id}`,
        label: currentBundle.name,
        quickActions: ["Find missing resources", "Remove noise", "Check task boundary"],
        proposal: candidate
          ? `Add “${candidate.document.title}” because it complements the current bundle without duplicating an included resource.`
          : "The bundle already covers the available Hub resources in this prototype.",
        applyLabel: candidate ? "Add Resource" : "No Change",
        onApply: () => {
          if (candidate) {
            updateBundle(currentBundle.id, (bundle) => ({
              ...bundle,
              resourceIds: [...bundle.resourceIds, candidate.id],
            }));
          }
        },
      };
    }
    return null;
  }, [
    addReviewComment,
    applyAgentToMemory,
    currentBundle,
    currentHubItem,
    currentProjectItem,
    currentReview,
    resources,
    selectedView,
    updateBundle,
  ]);

  const contentSupportsTabs =
    selectedView === "Hub" ||
    selectedView === "Local" ||
    selectedView === "Bundles" ||
    selectedView === "Reviews";
  const contentTabs = contentSupportsTabs
    ? workspaceTabPresentations.filter(({ tab }) => tab.view === selectedView)
    : [];
  const contentTabStrip = contentSupportsTabs ? (
    <WorkspaceTabBar
      activeTabKey={activeTabKey}
      tabs={contentTabs}
      onActivateTab={activateWorkspaceTab}
      onCloseTab={closeWorkspaceTabByKey}
      onPinTab={pinWorkspaceTabByKey}
    />
  ) : null;
  const workbenchStyle = {
    "--agent-width": `${agentWidth}px`,
  } as CSSProperties;

  return (
    <main className={sidebarCollapsed ? "app-shell sidebar-collapsed" : "app-shell"}>
      <TitleBar />
      <Sidebar
        account={account}
        collapsed={sidebarCollapsed}
        organization={organization}
        projects={projects}
        selectedProjectId={selectedProjectId}
        selectedView={selectedView}
        userMenuOpen={userMenuOpen}
        onCloseUserMenu={() => setUserMenuOpen(false)}
        onOpenSettings={() => {
          setUserMenuOpen(false);
          navigateToView("Settings");
        }}
        onSelectView={(view) => {
          setUserMenuOpen(false);
          navigateToView(view);
        }}
        onSelectProject={selectProject}
        onToggleCollapsed={() => {
          setUserMenuOpen(false);
          setSidebarCollapsed((current) => !current);
        }}
        onToggleUserMenu={() => setUserMenuOpen((current) => !current)}
      />

      <section className="workspace">
        <div
          className={agentOpen ? "workbench-frame agent-open" : "workbench-frame"}
          style={workbenchStyle}
        >
          <section className="content-region">
            <div className="workspace-content">
              {loadState.status === "authentication_required" ? (
                <AuthenticationView
                  message={loadState.message}
                  onAuthenticate={authenticateDesktop}
                />
              ) : loadState.status === "loading" && !previewMode ? (
                <ConnectionStateView state="loading" onRetry={refreshBackend} />
              ) : loadState.status === "failed" && selectedView !== "Diagnostics" ? (
                <ConnectionStateView
                  message={loadState.message}
                  state="failed"
                  onRetry={refreshBackend}
                />
              ) : selectedView === "Hub" ? (
                <MemoryWorkspace
              counts={kindCounts(resources, drafts, "Hub", null)}
              item={currentHubItem}
              items={hubItems}
              kind={hubKind}
              surface={
                activeWorkspaceTab?.view === "Hub"
                  ? activeWorkspaceTab.surface
                  : "source"
              }
              selectedId={selectedHubId}
              scope="Hub"
              sourceWidth={sourceWidth}
              tabStrip={contentTabStrip}
              onCreate={(kind) => createMemoryDraft("Hub", kind)}
              onDiscardDraft={discardDraft}
              onDocumentChange={updateDocument}
              onKindChange={setHubKind}
              onOpenSearch={() => setSearchOpen(true)}
              onOpenMarkdownPreview={openMarkdownPreview}
              onOpenReview={openReviewForDraft}
              onPinItem={(id) =>
                openMemoryWorkspaceTab("Hub", id, hubKind, null, true)
              }
              onProposeDeletion={proposeDeletion}
              onSelectItem={(id) =>
                openMemoryWorkspaceTab("Hub", id, hubKind, null)
              }
              onSourceWidthChange={setSourceWidth}
              onSubmitReview={submitReview}
            />
              ) : selectedView === "Local" ? (
                <MemoryWorkspace
              counts={kindCounts(resources, drafts, "Project", selectedProjectId)}
              item={currentProjectItem}
              items={projectItems}
              kind={projectKind}
              surface={
                activeWorkspaceTab?.view === "Local"
                  ? activeWorkspaceTab.surface
                  : "source"
              }
              selectedId={selectedProjectResourceId}
              scope="Project"
              sourceWidth={sourceWidth}
              tabStrip={contentTabStrip}
              onCreate={(kind) => createMemoryDraft("Project", kind)}
              onDiscardDraft={discardDraft}
              onDocumentChange={updateDocument}
              onKindChange={setProjectKind}
              onOpenSearch={() => setSearchOpen(true)}
              onOpenMarkdownPreview={openMarkdownPreview}
              onOpenReview={openReviewForDraft}
              onPinItem={(id) =>
                openMemoryWorkspaceTab(
                  "Local",
                  id,
                  projectKind,
                  selectedProjectId,
                  true,
                )
              }
              onProposeDeletion={proposeDeletion}
              onSelectItem={(id) =>
                openMemoryWorkspaceTab(
                  "Local",
                  id,
                  projectKind,
                  selectedProjectId,
                )
              }
              onSourceWidthChange={setSourceWidth}
              onSubmitReview={submitReview}
            />
              ) : selectedView === "Bundles" ? (
                <BundlesWorkspace
              bundle={currentBundle}
              bundles={bundles}
              resources={resources}
              sourceWidth={sourceWidth}
              tabStrip={contentTabStrip}
              onCreate={createBundle}
              onDelete={deleteBundle}
              onOpenSearch={() => setSearchOpen(true)}
              onOpenPicker={() => setBundlePickerOpen(true)}
              onPin={(id) => {
                setSelectedBundleId(id);
                showWorkspaceTab(
                  { key: `bundle:${id}`, view: "Bundles", targetId: id, pinned: true },
                  true,
                );
              }}
              onSelect={(id) => {
                setSelectedBundleId(id);
                showWorkspaceTab({
                  key: `bundle:${id}`,
                  view: "Bundles",
                  targetId: id,
                  pinned: false,
                });
              }}
              selectedId={selectedBundleId}
              onSourceWidthChange={setSourceWidth}
              onUpdate={updateBundle}
            />
              ) : selectedView === "Reviews" ? (
                <ReviewsWorkspace
              draft={currentReviewDraft}
              filter={reviewFilter}
              filteredReviews={filteredReviews}
              resource={currentReviewResource}
              review={currentReview}
              reviews={reviews}
              sourceWidth={sourceWidth}
              tabStrip={contentTabStrip}
              onAddComment={addReviewComment}
              onDiscardConflict={discardReviewConflict}
              onFilterChange={setReviewFilter}
              onMerge={mergeReview}
              onOpenSearch={() => setSearchOpen(true)}
              onPin={(id) => {
                setSelectedReviewId(id);
                showWorkspaceTab(
                  { key: `review:${id}`, view: "Reviews", targetId: id, pinned: true },
                  true,
                );
              }}
              onSelect={(id) => {
                setSelectedReviewId(id);
                showWorkspaceTab({
                  key: `review:${id}`,
                  view: "Reviews",
                  targetId: id,
                  pinned: false,
                });
              }}
              selectedId={selectedReviewId}
              onResolveConflict={resolveReviewConflict}
              onSourceWidthChange={setSourceWidth}
              onUpdateStatus={updateReviewStatus}
            />
              ) : selectedView === "Diagnostics" ? (
                <DiagnosticsView
                  loadState={loadState}
                  onCommand={runDaemonCommand}
                  onRefresh={refreshBackend}
                  onRetrySync={retryDaemonSync}
                />
              ) : selectedView === "Settings" ? (
                <SettingsView
                  loadState={loadState}
                  projectName={
                    projects.find((project) => project.id === selectedProjectId)?.name ??
                    "Not selected"
                  }
                  onOpenDiagnostics={() => navigateToView("Diagnostics")}
                />
              ) : (
                <EmptyState icon={FileText} title="No open item" />
              )}
            </div>
          </section>
          {agentOpen ? (
            <>
              <PaneResizer
                ariaLabel="Resize Agent panel"
                side="right"
                value={agentWidth}
                min={300}
                max={560}
                onChange={setAgentWidth}
              />
              <AgentPanel target={agentTarget} onClose={() => setAgentOpen(false)} />
            </>
          ) : null}
        </div>
      </section>

      <BottomToolbar
        agentOpen={agentOpen}
        onToggleAgent={() => setAgentOpen((current) => !current)}
      />

      {searchOpen ? (
        <SearchPalette
          query={searchQuery}
          results={searchResults}
          searchRef={searchRef}
          onClose={() => setSearchOpen(false)}
          onOpenResult={openSearchResult}
          onQueryChange={setSearchQuery}
        />
      ) : null}

      {bundlePickerOpen && currentBundle ? (
        <ResourcePicker
          bundle={currentBundle}
          resources={resources.filter((resource) => resource.scope === "Hub")}
          onAdd={(resourceId) => {
            updateBundle(currentBundle.id, (bundle) => ({
              ...bundle,
              resourceIds: Array.from(new Set([...bundle.resourceIds, resourceId])),
            }));
          }}
          onClose={() => setBundlePickerOpen(false)}
        />
      ) : null}

      {confirmState ? (
        <ConfirmDialog state={confirmState} onCancel={() => setConfirmState(null)} />
      ) : null}

      {undoState ? (
        <div className="toast" role="status">
          <span>{undoState.message}</span>
          <button
            className="toast-action"
            onClick={() => {
              undoState.run();
              setUndoState(null);
            }}
            type="button"
          >
            <Undo2 size={14} />
            Undo
          </button>
        </div>
      ) : null}
    </main>
  );
}

function TitleBar() {
  return (
    <div className="title-bar" data-tauri-drag-region>
      {!isTauriRuntime() ? (
        <div className="preview-traffic-lights" aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
      ) : null}
    </div>
  );
}

function Sidebar({
  account,
  collapsed,
  onCloseUserMenu,
  onOpenSettings,
  onSelectProject,
  onSelectView,
  onToggleCollapsed,
  onToggleUserMenu,
  organization,
  projects,
  selectedProjectId,
  selectedView,
  userMenuOpen,
}: {
  account: DesktopAccount | null;
  collapsed: boolean;
  onCloseUserMenu: () => void;
  onOpenSettings: () => void;
  onSelectProject: (projectId: string) => void;
  onSelectView: (view: PrimaryView) => void;
  onToggleCollapsed: () => void;
  onToggleUserMenu: () => void;
  organization: DesktopOrganization;
  projects: ProjectOption[];
  selectedProjectId: string;
  selectedView: View;
  userMenuOpen: boolean;
}) {
  const [showAllProjects, setShowAllProjects] = useState(false);
  const [collapsedProjectsOpen, setCollapsedProjectsOpen] = useState(false);
  const selectedProject =
    projects.find((project) => project.id === selectedProjectId) ?? projects[0] ?? null;
  const projectPreview = projects.slice(0, projectPreviewLimit);
  const visibleProjects = showAllProjects
    ? projects
    : !selectedProject || projectPreview.some((project) => project.id === selectedProjectId)
      ? projectPreview
      : [...projectPreview.slice(0, projectPreviewLimit - 1), selectedProject];
  const accountLabel = account
    ? account.displayName?.trim() || account.email
    : "";
  const showAccountEmail = Boolean(
    account?.displayName?.trim() && account.displayName.trim() !== account.email,
  );

  useEffect(() => {
    if (!collapsed) {
      setCollapsedProjectsOpen(false);
    }
  }, [collapsed]);

  const selectView = (view: PrimaryView) => {
    setCollapsedProjectsOpen(false);
    onSelectView(view);
  };

  const selectProject = (projectId: string) => {
    setCollapsedProjectsOpen(false);
    onSelectProject(projectId);
  };

  return (
    <aside className={collapsed ? "sidebar collapsed" : "sidebar"}>
      <div className="sidebar-control-row">
        {collapsed ? (
          <button
            aria-label="Expand Global Sidebar"
            className="sidebar-brand-button"
            onClick={onToggleCollapsed}
            title={`${organization.name} · Expand sidebar`}
            type="button"
          >
            <img
              alt=""
              aria-hidden="true"
              className="sidebar-brand-logo"
              src={clumsiesMark}
            />
          </button>
        ) : (
          <>
            <div className="sidebar-brand">
              <img
                alt=""
                aria-hidden="true"
                className="sidebar-brand-logo"
                src={clumsiesMark}
              />
              <span>{organization.name}</span>
            </div>
            <button
              aria-label="Collapse Global Sidebar"
              className="sidebar-toggle"
              onClick={onToggleCollapsed}
              title="Collapse Global Sidebar"
              type="button"
            >
              <PanelLeftClose aria-hidden="true" size={14} />
            </button>
          </>
        )}
      </div>
      <nav className="primary-nav" aria-label="Primary">
        {primaryNavigation.map((item) => {
          const active = selectedView === item.view;
          if (collapsed && item.view === "Local" && selectedProject) {
            return (
              <div className="nav-entry local-nav-entry" key={item.view}>
                <button
                  aria-expanded={collapsedProjectsOpen}
                  aria-haspopup="menu"
                  aria-label={`Local projects, current project ${selectedProject.name}`}
                  className={active ? "nav-item active" : "nav-item"}
                  onClick={() => setCollapsedProjectsOpen((current) => !current)}
                  title={`Local · ${selectedProject.name}`}
                  type="button"
                >
                  <item.icon aria-hidden="true" size={15} strokeWidth={1.8} />
                </button>
                {collapsedProjectsOpen ? (
                  <>
                    <div
                      aria-hidden="true"
                      className="sidebar-project-popover-backdrop"
                      onMouseDown={() => setCollapsedProjectsOpen(false)}
                    />
                    <div
                      aria-label="Local projects"
                      className="sidebar-project-popover"
                      role="menu"
                    >
                      {projects.map((project) => {
                        const selected = project.id === selectedProjectId;
                        return (
                          <button
                            aria-checked={selected}
                            className={
                              selected
                                ? "project-popover-item active"
                                : "project-popover-item"
                            }
                            key={project.id}
                            onClick={() => selectProject(project.id)}
                            role="menuitemradio"
                            type="button"
                          >
                            <span>{project.name}</span>
                          </button>
                        );
                      })}
                    </div>
                  </>
                ) : null}
              </div>
            );
          }
          const itemIsCurrent = active && item.view !== "Local";
          return (
            <div
              className={
                item.view === "Local"
                  ? active
                    ? "nav-entry local-nav-entry has-active-project"
                    : "nav-entry local-nav-entry"
                  : "nav-entry"
              }
              key={item.view}
            >
              <button
                aria-label={item.label}
                aria-current={itemIsCurrent ? "page" : undefined}
                aria-expanded={item.view === "Local" ? true : undefined}
                className={itemIsCurrent ? "nav-item active" : "nav-item"}
                onClick={() => selectView(item.view)}
                title={collapsed ? item.label : undefined}
                type="button"
              >
                <item.icon aria-hidden="true" size={15} strokeWidth={1.8} />
                <span className="nav-label">{item.label}</span>
              </button>
              {item.view === "Local" ? (
                <div aria-label="Local projects" className="sidebar-project-list">
                  {visibleProjects.map((project) => {
                    const selected =
                      selectedView === "Local" && project.id === selectedProjectId;
                    return (
                      <button
                        aria-current={selected ? "page" : undefined}
                        className={
                          selected ? "sidebar-project-item active" : "sidebar-project-item"
                        }
                        key={project.id}
                        onClick={() => selectProject(project.id)}
                        type="button"
                      >
                        <span>{project.name}</span>
                      </button>
                    );
                  })}
                  {projects.length > projectPreviewLimit ? (
                    <button
                      aria-expanded={showAllProjects}
                      className="sidebar-project-more"
                      onClick={() => setShowAllProjects((current) => !current)}
                      type="button"
                    >
                      <span>{showAllProjects ? "Show less" : "Show more"}</span>
                    </button>
                  ) : null}
                </div>
              ) : null}
            </div>
          );
        })}
      </nav>
      {account && userMenuOpen ? (
        <div
          aria-hidden="true"
          className="user-menu-backdrop"
          onMouseDown={onCloseUserMenu}
        />
      ) : null}
      {account ? <div className="user-area">
        {userMenuOpen ? (
          <div aria-label="User menu" className="user-menu" role="menu">
            <div className="user-menu-identity">
              <UserAvatar account={account} />
              <span className="user-menu-copy">
                <strong>{accountLabel}</strong>
                {showAccountEmail ? <span>{account.email}</span> : null}
              </span>
            </div>
            <button
              aria-current={selectedView === "Settings" ? "page" : undefined}
              className={
                selectedView === "Settings"
                  ? "user-menu-item active"
                  : "user-menu-item"
              }
              onClick={onOpenSettings}
              role="menuitem"
              type="button"
            >
              <span>Settings</span>
            </button>
          </div>
        ) : null}
        <button
          aria-expanded={userMenuOpen}
          aria-haspopup="menu"
          aria-label={`User menu for ${accountLabel}`}
          className={selectedView === "Settings" ? "user-item active" : "user-item"}
          onClick={onToggleUserMenu}
          title={collapsed ? accountLabel : undefined}
          type="button"
        >
          <UserAvatar account={account} />
          <span className="user-name">{accountLabel}</span>
          <ChevronDown aria-hidden="true" className="user-menu-chevron" size={13} />
        </button>
      </div> : null}
    </aside>
  );
}

function UserAvatar({ account }: { account: DesktopAccount }) {
  const [imageFailed, setImageFailed] = useState(false);

  useEffect(() => setImageFailed(false), [account.avatarUrl]);

  return (
    <span aria-hidden="true" className="user-avatar">
      {account.avatarUrl && !imageFailed ? (
        <img
          alt=""
          onError={() => setImageFailed(true)}
          referrerPolicy="no-referrer"
          src={account.avatarUrl}
        />
      ) : accountInitials(account)}
    </span>
  );
}

function BottomToolbar({
  agentOpen,
  onToggleAgent,
}: {
  agentOpen: boolean;
  onToggleAgent: () => void;
}) {
  return (
    <footer className="bottom-toolbar" aria-label="Workspace tools">
      <div className="bottom-toolbar-drag" data-tauri-drag-region />
      <div className="bottom-toolbar-right">
        <button
          aria-label={agentOpen ? "Hide Agent" : "Show Agent"}
          aria-pressed={agentOpen}
          className={agentOpen ? "toolbar-tool active" : "toolbar-tool"}
          onClick={onToggleAgent}
          title={agentOpen ? "Hide Agent" : "Show Agent"}
          type="button"
        >
          <Sparkles aria-hidden="true" size={14} />
        </button>
      </div>
    </footer>
  );
}

function WorkspaceTabBar({
  activeTabKey,
  onActivateTab,
  onCloseTab,
  onPinTab,
  tabs,
}: {
  activeTabKey: string | null;
  onActivateTab: (tab: WorkspaceTab) => void;
  onCloseTab: (key: string) => void;
  onPinTab: (key: string) => void;
  tabs: WorkspaceTabPresentation[];
}) {
  return (
    <header className="workspace-tab-bar" data-tauri-drag-region>
      <div aria-label="Open items" className="workspace-tabs" role="tablist">
        {tabs.map(({ label, syncState, tab, title }) => (
          <div
            className={[
              "workspace-tab",
              activeTabKey === tab.key ? "active" : "",
              tab.pinned ? "" : "preview",
            ]
              .filter(Boolean)
              .join(" ")}
            key={tab.key}
          >
            <button
              aria-selected={activeTabKey === tab.key}
              className="workspace-tab-select"
              onClick={() => onActivateTab(tab)}
              onDoubleClick={() => onPinTab(tab.key)}
              role="tab"
              title={title}
              type="button"
            >
              <span>{label}</span>
              {syncState === "syncing" ? (
                <LoaderCircle aria-hidden="true" className="spin" size={12} />
              ) : syncState === "conflict" ? (
                <CloudOff aria-hidden="true" className="tab-conflict" size={12} />
              ) : null}
            </button>
            <button
              aria-label={`Close ${label}`}
              className="workspace-tab-close"
              onClick={(event) => {
                event.stopPropagation();
                onCloseTab(tab.key);
              }}
              title="Close"
              type="button"
            >
              <X aria-hidden="true" size={12} />
            </button>
          </div>
        ))}
        <div className="tab-drag-space" data-tauri-drag-region />
      </div>
    </header>
  );
}

function SearchPalette({
  onClose,
  onOpenResult,
  onQueryChange,
  query,
  results,
  searchRef,
}: {
  onClose: () => void;
  onOpenResult: (result: SearchResult) => void;
  onQueryChange: (query: string) => void;
  query: string;
  results: SearchResult[];
  searchRef: React.RefObject<HTMLInputElement | null>;
}) {
  return (
    <div className="search-overlay" onMouseDown={onClose} role="presentation">
      <section
        aria-label="Search workspace"
        aria-modal="true"
        className="search-palette"
        onMouseDown={(event) => event.stopPropagation()}
        role="dialog"
      >
        <div className="search-palette-input">
          <Search aria-hidden="true" size={16} />
          <input
            aria-expanded={Boolean(query)}
            aria-haspopup="listbox"
            aria-label="Search all resources, drafts, bundles, and reviews"
            onChange={(event) => onQueryChange(event.currentTarget.value)}
            placeholder="Search resources, drafts, bundles, reviews…"
            ref={searchRef}
            type="search"
            value={query}
          />
          <IconButton icon={X} label="Close search" onClick={onClose} />
        </div>
        {query ? <SearchResults results={results} onOpen={onOpenResult} /> : null}
      </section>
    </div>
  );
}

function SearchResults({
  onOpen,
  results,
}: {
  onOpen: (result: SearchResult) => void;
  results: SearchResult[];
}) {
  return (
    <div className="search-results" role="listbox">
      {results.length ? (
        results.map((result) => (
          <button
            className="search-result"
            key={`${result.type}-${result.id}`}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => onOpen(result)}
            role="option"
            type="button"
          >
            <SearchResultIcon type={result.type} />
            <span>
              <strong>{result.label}</strong>
              <small>{result.detail}</small>
            </span>
            <em>{result.type}</em>
          </button>
        ))
      ) : (
        <div className="search-empty">No matching resources or work in progress.</div>
      )}
    </div>
  );
}

function SearchResultIcon({ type }: { type: SearchResult["type"] }) {
  const Icon =
    type === "memory"
      ? FileText
      : type === "draft"
        ? FilePenLine
        : type === "bundle"
          ? Package
          : GitPullRequest;
  return <Icon aria-hidden="true" size={15} />;
}

function MemoryWorkspace({
  counts,
  item,
  items,
  kind,
  onCreate,
  onDiscardDraft,
  onDocumentChange,
  onKindChange,
  onOpenMarkdownPreview,
  onOpenReview,
  onOpenSearch,
  onPinItem,
  onProposeDeletion,
  onSelectItem,
  onSourceWidthChange,
  onSubmitReview,
  scope,
  selectedId,
  sourceWidth,
  surface,
  tabStrip,
}: {
  counts: Record<MemoryKind, number>;
  item: ResourceListItem | null;
  items: ResourceListItem[];
  kind: MemoryKind;
  onCreate: (kind: MemoryKind) => void;
  onDiscardDraft: (item: ResourceListItem) => void;
  onDocumentChange: (
    item: ResourceListItem,
    update: (document: MemoryDocument) => MemoryDocument,
  ) => void;
  onKindChange: (kind: MemoryKind) => void;
  onOpenMarkdownPreview: (item: ResourceListItem) => void;
  onOpenReview: (draftId: string) => void;
  onOpenSearch: () => void;
  onPinItem: (id: string) => void;
  onProposeDeletion: (item: ResourceListItem) => void;
  onSelectItem: (id: string) => void;
  onSourceWidthChange: (width: number) => void;
  onSubmitReview: (item: ResourceListItem) => void;
  scope: MemoryScope;
  selectedId: string | null;
  sourceWidth: number;
  surface: MemoryTabSurface;
  tabStrip: ReactNode;
}) {
  return (
    <PageLayout
      sourceWidth={sourceWidth}
      onSourceWidthChange={onSourceWidthChange}
      tabStrip={tabStrip}
      source={
        <>
          <div className="source-toolbar">
            <KindNavigation counts={counts} kind={kind} onChange={onKindChange} />
            <IconButton
              icon={Search}
              label="Search"
              onClick={onOpenSearch}
            />
          </div>
          {kind === "Context" ? (
            <FileTree
              createLabel={`New ${kind}`}
              items={items}
              selectedId={selectedId}
              onCreate={() => onCreate(kind)}
              onPin={onPinItem}
              onSelect={onSelectItem}
            />
          ) : (
            <ResourceList
              createLabel={`New ${kind === "Rules" ? "Rule" : kind}`}
              items={items}
              selectedId={selectedId}
              onCreate={() => onCreate(kind)}
              onPin={onPinItem}
              onSelect={onSelectItem}
            />
          )}
        </>
      }
    >
      {item ? (
        surface === "markdown-preview" ? (
          <MarkdownPreviewItem
            key={`${item.selectionId}:preview`}
            item={item}
            onChange={(update) => onDocumentChange(item, update)}
            onDiscard={() => onDiscardDraft(item)}
            onOpenReview={() => item.draft && onOpenReview(item.draft.id)}
            onOpenSource={() => onPinItem(item.selectionId)}
            onProposeDeletion={() => onProposeDeletion(item)}
            onSubmit={() => onSubmitReview(item)}
          />
        ) : (
          <MemoryEditor
            key={`${item.selectionId}:source`}
            item={item}
            onChange={(update) => onDocumentChange(item, update)}
            onDiscard={() => onDiscardDraft(item)}
            onOpenMarkdownPreview={() => onOpenMarkdownPreview(item)}
            onOpenReview={() => item.draft && onOpenReview(item.draft.id)}
            onProposeDeletion={() => onProposeDeletion(item)}
            onSubmit={() => onSubmitReview(item)}
          />
        )
      ) : (
        <EmptyState
          icon={FileText}
          title={items.length ? "No open tab" : `No ${kind.toLowerCase()} here`}
          actionLabel={items.length ? undefined : `Create ${kind === "Rules" ? "Rule" : kind}`}
          onAction={items.length ? undefined : () => onCreate(kind)}
        />
      )}
    </PageLayout>
  );
}

function KindNavigation({
  counts,
  kind,
  onChange,
}: {
  counts: Record<MemoryKind, number>;
  kind: MemoryKind;
  onChange: (kind: MemoryKind) => void;
}) {
  return (
    <div aria-label="Resource type" className="kind-navigation" role="tablist">
      {memoryKinds.map((entry) => {
        const Icon = kindIcons[entry];
        return (
          <button
            aria-label={`${entry}, ${counts[entry]}`}
            aria-selected={kind === entry}
            className={kind === entry ? "kind-item active" : "kind-item"}
            key={entry}
            onClick={() => onChange(entry)}
            role="tab"
            title={`${entry} · ${counts[entry]}`}
            type="button"
          >
            <Icon aria-hidden="true" size={14} />
          </button>
        );
      })}
    </div>
  );
}

function ResourceList({
  createLabel,
  items,
  onCreate,
  onPin,
  onSelect,
  selectedId,
}: {
  createLabel?: string;
  items: ResourceListItem[];
  onCreate?: () => void;
  onPin: (id: string) => void;
  onSelect: (id: string) => void;
  selectedId: string | null;
}) {
  return (
    <div className="resource-list" role="listbox" onKeyDown={moveListFocus}>
      {createLabel && onCreate ? (
        <NavigatorCreateRow label={createLabel} onClick={onCreate} />
      ) : null}
      {items.map((item) => (
        <button
          aria-label={resourceStateAriaLabel(item, item.document.title)}
          aria-selected={selectedId === item.selectionId}
          className={
            selectedId === item.selectionId ? "resource-row active" : "resource-row"
          }
          key={item.selectionId}
          onDoubleClick={() => onPin(item.selectionId)}
          onClick={() => onSelect(item.selectionId)}
          role="option"
          type="button"
        >
          <span>
            <strong className={resourceNameClass(item)}>{item.document.title}</strong>
            <small>{resourceSecondaryText(item)}</small>
          </span>
        </button>
      ))}
    </div>
  );
}

type TreeNode = {
  name: string;
  path: string;
  children: TreeNode[];
  item?: ResourceListItem;
};

function FileTree({
  createLabel,
  items,
  onCreate,
  onPin,
  onSelect,
  selectedId,
}: {
  createLabel?: string;
  items: ResourceListItem[];
  onCreate?: () => void;
  onPin: (id: string) => void;
  onSelect: (id: string) => void;
  selectedId: string | null;
}) {
  const tree = useMemo(() => buildTree(items), [items]);
  return (
    <div className="file-tree" role="tree" onKeyDown={moveTreeFocus}>
      {createLabel && onCreate ? (
        <div role="none">
          <NavigatorCreateRow label={createLabel} onClick={onCreate} />
        </div>
      ) : null}
      {tree.map((node) => (
        <TreeBranch
          depth={0}
          key={node.path}
          node={node}
          onPin={onPin}
          onSelect={onSelect}
          selectedId={selectedId}
        />
      ))}
    </div>
  );
}

function NavigatorCreateRow({
  label,
  onClick,
}: {
  label: string;
  onClick: () => void;
}) {
  return (
    <button className="navigator-create-row" onClick={onClick} type="button">
      {label}
    </button>
  );
}

function TreeBranch({
  depth,
  node,
  onPin,
  onSelect,
  selectedId,
}: {
  depth: number;
  node: TreeNode;
  onPin: (id: string) => void;
  onSelect: (id: string) => void;
  selectedId: string | null;
}) {
  const [expanded, setExpanded] = useState(true);
  if (node.item) {
    const active = selectedId === node.item.selectionId;
    return (
      <button
        aria-label={resourceStateAriaLabel(node.item, node.name)}
        aria-level={depth + 1}
        aria-selected={active}
        className={active ? "tree-file active" : "tree-file"}
        onDoubleClick={() => onPin(node.item!.selectionId)}
        onClick={() => onSelect(node.item!.selectionId)}
        role="treeitem"
        style={{ paddingLeft: 8 + depth * 14 }}
        type="button"
      >
        <FileText aria-hidden="true" size={13} />
        <span className={resourceNameClass(node.item)}>{node.name}</span>
      </button>
    );
  }
  return (
    <div role="group">
      <button
        aria-expanded={expanded}
        aria-level={depth + 1}
        className="tree-folder"
        onClick={() => setExpanded((current) => !current)}
        role="treeitem"
        style={{ paddingLeft: 8 + depth * 14 }}
        type="button"
      >
        {expanded ? (
          <FolderOpen aria-hidden="true" size={13} />
        ) : (
          <Folder aria-hidden="true" size={13} />
        )}
        <span>{node.name}</span>
      </button>
      {expanded
        ? node.children.map((child) => (
            <TreeBranch
              depth={depth + 1}
              key={child.path}
              node={child}
              onPin={onPin}
              onSelect={onSelect}
              selectedId={selectedId}
            />
          ))
        : null}
    </div>
  );
}

function MemoryEditor({
  item,
  onChange,
  onDiscard,
  onOpenMarkdownPreview,
  onOpenReview,
  onProposeDeletion,
  onSubmit,
}: {
  item: ResourceListItem;
  onChange: (update: (document: MemoryDocument) => MemoryDocument) => void;
  onDiscard: () => void;
  onOpenMarkdownPreview: () => void;
  onOpenReview: () => void;
  onProposeDeletion: () => void;
  onSubmit: () => void;
}) {
  const draft = item.draft;
  const locked = draft?.status === "in_review";
  const deleting = draft?.operation === "delete";
  return (
    <section className="editor-surface">
      <MemoryItemToolbar
        item={item}
        onChange={onChange}
        onDiscard={onDiscard}
        onOpenMarkdownPreview={onOpenMarkdownPreview}
        onOpenReview={onOpenReview}
        onProposeDeletion={onProposeDeletion}
        onSubmit={onSubmit}
        surface="source"
      />
      {deleting ? (
        <DeletionDraft document={item.document} locked={locked} />
      ) : item.kind === "Rules" ? (
        <RuleEditor document={item.document} disabled={locked} onChange={onChange} />
      ) : item.kind === "Workflows" ? (
        <WorkflowEditor document={item.document} disabled={locked} onChange={onChange} />
      ) : (
        <TextDocumentEditor
          document={item.document}
          disabled={locked}
          onChange={onChange}
        />
      )}
    </section>
  );
}

function MarkdownPreviewItem({
  item,
  onChange,
  onDiscard,
  onOpenReview,
  onOpenSource,
  onProposeDeletion,
  onSubmit,
}: {
  item: ResourceListItem;
  onChange: (update: (document: MemoryDocument) => MemoryDocument) => void;
  onDiscard: () => void;
  onOpenReview: () => void;
  onOpenSource: () => void;
  onProposeDeletion: () => void;
  onSubmit: () => void;
}) {
  return (
    <section className="editor-surface">
      <MemoryItemToolbar
        item={item}
        onChange={onChange}
        onDiscard={onDiscard}
        onOpenReview={onOpenReview}
        onOpenSource={onOpenSource}
        onProposeDeletion={onProposeDeletion}
        onSubmit={onSubmit}
        surface="markdown-preview"
      />
      {isMarkdownPath(item.document.path) ? (
        <div className="document-editor">
          <article className="markdown-preview">
            <ReactMarkdown remarkPlugins={[remarkGfm]}>{item.document.body}</ReactMarkdown>
          </article>
        </div>
      ) : (
        <EmptyState icon={Eye} title="Preview unavailable" />
      )}
    </section>
  );
}

type ItemToolAction = {
  disabled?: boolean;
  icon: LucideIcon;
  label: string;
  onClick: () => void;
  tone?: "danger";
};

function MemoryItemToolbar({
  item,
  onChange,
  onDiscard,
  onOpenMarkdownPreview,
  onOpenReview,
  onOpenSource,
  onProposeDeletion,
  onSubmit,
  surface,
}: {
  item: ResourceListItem;
  onChange: (update: (document: MemoryDocument) => MemoryDocument) => void;
  onDiscard: () => void;
  onOpenMarkdownPreview?: () => void;
  onOpenReview: () => void;
  onOpenSource?: () => void;
  onProposeDeletion: () => void;
  onSubmit: () => void;
  surface: MemoryTabSurface;
}) {
  const [menuOpen, setMenuOpen] = useState(false);
  const [renaming, setRenaming] = useState(false);
  const [nextPath, setNextPath] = useState(item.document.path);
  const draft = item.draft;
  const locked = draft?.status === "in_review";
  const deleting = draft?.operation === "delete";
  const workingState = resourceWorkingState(item);
  const stateLabel = workingStateLabel(workingState);

  useEffect(() => {
    if (!menuOpen) {
      return;
    }
    const closeOnEscape = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") {
        setMenuOpen(false);
      }
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [menuOpen]);

  const commitRename = () => {
    const path = nextPath.trim();
    if (path && path !== item.document.path) {
      onChange((current) => ({ ...current, path }));
    }
    setRenaming(false);
  };

  const cancelRename = () => {
    setNextPath(item.document.path);
    setRenaming(false);
  };

  const toolbarActions: ItemToolAction[] = [];
  if (renaming) {
    toolbarActions.push(
      { icon: Check, label: "Apply path", onClick: commitRename },
      { icon: X, label: "Cancel rename", onClick: cancelRename },
    );
  } else {
    if (
      surface === "source" &&
      isMarkdownPath(item.document.path) &&
      !deleting &&
      onOpenMarkdownPreview
    ) {
      toolbarActions.push({
        icon: Eye,
        label: "Open Markdown Preview",
        onClick: onOpenMarkdownPreview,
      });
    } else if (surface === "markdown-preview" && onOpenSource) {
      toolbarActions.push({
        icon: Code2,
        label: "Open Source",
        onClick: onOpenSource,
      });
    }
    if (draft?.status === "editing") {
      toolbarActions.push({
        disabled: draft.syncState !== "synced",
        icon: GitPullRequest,
        label: "Submit Review",
        onClick: onSubmit,
      });
    } else if (draft?.status === "in_review") {
      toolbarActions.push({
        icon: GitPullRequest,
        label: "Open Review",
        onClick: onOpenReview,
      });
    }
  }

  const menuActions: ItemToolAction[] = [];
  if (!locked) {
    menuActions.push({
      icon: FilePenLine,
      label: "Rename / Move",
      onClick: () => {
        setMenuOpen(false);
        setNextPath(item.document.path);
        setRenaming(true);
      },
    });
  }
  if (draft?.status === "editing") {
    menuActions.push({
      icon: X,
      label: "Discard Draft",
      onClick: () => {
        setMenuOpen(false);
        onDiscard();
      },
      tone: "danger",
    });
  } else if (!draft && item.resource) {
    menuActions.push({
      icon: Trash2,
      label: "Propose Deletion",
      onClick: () => {
        setMenuOpen(false);
        onProposeDeletion();
      },
      tone: "danger",
    });
  }

  return (
    <div className="item-toolbar">
      <div className="item-context">
        {renaming ? (
          <form
            className="item-path-editor"
            onSubmit={(event) => {
              event.preventDefault();
              commitRename();
            }}
          >
            <input
              aria-label="New path"
              autoFocus
              onChange={(event) => setNextPath(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Escape") {
                  event.preventDefault();
                  cancelRename();
                }
              }}
              spellCheck={false}
              value={nextPath}
            />
          </form>
        ) : (
          <span className="item-breadcrumb" title={item.document.path}>
            {item.document.path}
          </span>
        )}
        {stateLabel ? (
          <span className={`item-state ${workingState}`}>{stateLabel}</span>
        ) : null}
      </div>
      <div className="item-tools">
        {toolbarActions.map((action) => (
          <IconButton key={action.label} {...action} />
        ))}
        {!renaming ? (
            <div className="item-menu-anchor">
              <button
                aria-expanded={menuOpen}
                aria-haspopup="menu"
                aria-label="More Item Actions"
                className={menuOpen ? "icon-button active" : "icon-button"}
                onClick={() => setMenuOpen((current) => !current)}
                title="More Item Actions"
                type="button"
              >
                <MoreHorizontal aria-hidden="true" size={15} />
              </button>
              {menuOpen ? (
                <>
                  <div
                    className="item-menu-backdrop"
                    onMouseDown={() => setMenuOpen(false)}
                    role="presentation"
                  />
                  <div className="item-menu" role="menu">
                    <div className="item-menu-metadata">
                      <strong>
                        {item.resource
                          ? `Published v${item.resource.version}`
                          : "Not published"}
                      </strong>
                      <small>
                        {item.scope === "Hub" ? "Hub" : item.projectName ?? "Project"}
                        {` · ${item.kind}`}
                      </small>
                    </div>
                    {menuActions.map(({ icon: Icon, label, onClick, tone }) => (
                      <button
                        className={
                          tone === "danger"
                            ? "item-menu-action danger"
                            : "item-menu-action"
                        }
                        key={label}
                        onClick={onClick}
                        role="menuitem"
                        type="button"
                      >
                        <Icon aria-hidden="true" size={14} />
                        <span>{label}</span>
                      </button>
                    ))}
                  </div>
                </>
              ) : null}
            </div>
        ) : null}
      </div>
    </div>
  );
}

function TextDocumentEditor({
  disabled,
  document,
  onChange,
}: {
  disabled: boolean;
  document: MemoryDocument;
  onChange: (update: (document: MemoryDocument) => MemoryDocument) => void;
}) {
  return (
    <div className="document-editor">
      <TextEditor
        ariaLabel={`${fileNameFromPath(document.path)} source`}
        onChange={(body) =>
          onChange((current) => ({
            ...current,
            body,
            title: isMarkdownPath(current.path)
              ? markdownTitle(body, current.title)
              : current.title,
          }))
        }
        path={document.path}
        readOnly={disabled}
        value={document.body}
      />
    </div>
  );
}

function RuleEditor({
  disabled,
  document,
  onChange,
}: {
  disabled: boolean;
  document: MemoryDocument;
  onChange: (update: (document: MemoryDocument) => MemoryDocument) => void;
}) {
  return (
    <div className="structured-editor">
      <LabeledField label="Name">
        <input
          disabled={disabled}
          onChange={(event) =>
            onChange((current) => ({ ...current, title: event.target.value }))
          }
          value={document.title}
        />
      </LabeledField>
      <LabeledField label="Applies when">
        <textarea
          disabled={disabled}
          onChange={(event) =>
            onChange((current) => ({ ...current, appliesWhen: event.target.value }))
          }
          rows={2}
          value={document.appliesWhen}
        />
      </LabeledField>
      <LabeledField label="Constraint" fill>
        <textarea
          disabled={disabled}
          onChange={(event) =>
            onChange((current) => ({ ...current, body: event.target.value }))
          }
          value={document.body}
        />
      </LabeledField>
      <LabeledField label="Tags">
        <input
          disabled={disabled}
          onChange={(event) =>
            onChange((current) => ({
              ...current,
              tags: event.target.value
                .split(",")
                .map((tag) => tag.trim())
                .filter(Boolean),
            }))
          }
          placeholder="coding, migration"
          value={document.tags.join(", ")}
        />
      </LabeledField>
    </div>
  );
}

function WorkflowEditor({
  disabled,
  document,
  onChange,
}: {
  disabled: boolean;
  document: MemoryDocument;
  onChange: (update: (document: MemoryDocument) => MemoryDocument) => void;
}) {
  const updateStep = (index: number, value: string) =>
    onChange((current) => ({
      ...current,
      steps: current.steps.map((step, stepIndex) =>
        stepIndex === index ? value : step,
      ),
    }));
  const moveStep = (index: number, direction: -1 | 1) =>
    onChange((current) => {
      const target = index + direction;
      if (target < 0 || target >= current.steps.length) {
        return current;
      }
      const steps = [...current.steps];
      [steps[index], steps[target]] = [steps[target], steps[index]];
      return { ...current, steps };
    });
  return (
    <div className="workflow-editor">
      <input
        aria-label="Workflow name"
        className="document-title"
        disabled={disabled}
        onChange={(event) =>
          onChange((current) => ({ ...current, title: event.target.value }))
        }
        value={document.title}
      />
      <textarea
        aria-label="Workflow purpose"
        className="workflow-purpose"
        disabled={disabled}
        onChange={(event) =>
          onChange((current) => ({ ...current, body: event.target.value }))
        }
        placeholder="What does this workflow accomplish?"
        rows={2}
        value={document.body}
      />
      <ol className="workflow-steps">
        {document.steps.map((step, index) => (
          <li key={`${index}-${step.slice(0, 16)}`}>
            <span>{index + 1}</span>
            <textarea
              aria-label={`Step ${index + 1}`}
              disabled={disabled}
              onChange={(event) => updateStep(index, event.target.value)}
              rows={2}
              value={step}
            />
            <div className="step-actions">
              <IconButton
                disabled={disabled || index === 0}
                icon={ArrowUp}
                label="Move step up"
                onClick={() => moveStep(index, -1)}
              />
              <IconButton
                disabled={disabled || index === document.steps.length - 1}
                icon={ArrowDown}
                label="Move step down"
                onClick={() => moveStep(index, 1)}
              />
              <IconButton
                disabled={disabled}
                icon={Trash2}
                label="Remove step"
                tone="danger"
                onClick={() =>
                  onChange((current) => ({
                    ...current,
                    steps: current.steps.filter((_, stepIndex) => stepIndex !== index),
                  }))
                }
              />
            </div>
          </li>
        ))}
      </ol>
      <button
        className="button add-step"
        disabled={disabled}
        onClick={() =>
          onChange((current) => ({ ...current, steps: [...current.steps, ""] }))
        }
        type="button"
      >
        <Plus aria-hidden="true" size={14} />
        Add Step
      </button>
    </div>
  );
}

function LabeledField({
  children,
  fill,
  label,
}: {
  children: ReactNode;
  fill?: boolean;
  label: string;
}) {
  return (
    <label className={fill ? "labeled-field fill" : "labeled-field"}>
      <span>{label}</span>
      {children}
    </label>
  );
}

function DeletionDraft({
  document,
  locked,
}: {
  document: MemoryDocument;
  locked: boolean;
}) {
  return (
    <div className="deletion-draft">
      <Trash2 aria-hidden="true" size={20} />
      <div>
        <strong>{document.title}</strong>
        <p>
          This draft proposes deleting the resource. Nothing is removed until an approved
          review is merged.
        </p>
        {locked ? <small>The proposal is waiting for a review decision.</small> : null}
      </div>
    </div>
  );
}

function BundlesWorkspace({
  bundle,
  bundles,
  onCreate,
  onDelete,
  onOpenSearch,
  onOpenPicker,
  onPin,
  onSelect,
  onSourceWidthChange,
  onUpdate,
  resources,
  selectedId,
  sourceWidth,
  tabStrip,
}: {
  bundle: PersonalBundle | null;
  bundles: PersonalBundle[];
  onCreate: () => void;
  onDelete: (bundle: PersonalBundle) => void;
  onOpenSearch: () => void;
  onOpenPicker: () => void;
  onPin: (id: string) => void;
  onSelect: (id: string) => void;
  onSourceWidthChange: (width: number) => void;
  onUpdate: (id: string, update: (bundle: PersonalBundle) => PersonalBundle) => void;
  resources: AuthorityResource[];
  selectedId: string;
  sourceWidth: number;
  tabStrip: ReactNode;
}) {
  return (
    <PageLayout
      sourceWidth={sourceWidth}
      onSourceWidthChange={onSourceWidthChange}
      tabStrip={tabStrip}
      source={
        <>
          <div className="source-toolbar">
            <IconButton icon={Search} label="Search" onClick={onOpenSearch} />
          </div>
          <div className="resource-list" role="listbox" onKeyDown={moveListFocus}>
            <NavigatorCreateRow label="New bundle" onClick={onCreate} />
            {bundles.map((entry) => (
              <button
                aria-selected={entry.id === selectedId}
                className={entry.id === selectedId ? "resource-row active" : "resource-row"}
                key={entry.id}
                onDoubleClick={() => onPin(entry.id)}
                onClick={() => onSelect(entry.id)}
                role="option"
                type="button"
              >
                <span>
                  <strong>{entry.name}</strong>
                  <small>{entry.resourceIds.length} resources</small>
                </span>
                <SyncMark compact state={entry.syncState} />
              </button>
            ))}
          </div>
        </>
      }
    >
      {bundle ? (
        <BundleEditor
          bundle={bundle}
          resources={resources}
          onDelete={() => onDelete(bundle)}
          onOpenPicker={onOpenPicker}
          onUpdate={(update) => onUpdate(bundle.id, update)}
        />
      ) : (
        <EmptyState
          icon={Package}
          title={bundles.length ? "No open tab" : "No bundles"}
          actionLabel={bundles.length ? undefined : "Create Bundle"}
          onAction={bundles.length ? undefined : onCreate}
        />
      )}
    </PageLayout>
  );
}

function BundleEditor({
  bundle,
  onDelete,
  onOpenPicker,
  onUpdate,
  resources,
}: {
  bundle: PersonalBundle;
  onDelete: () => void;
  onOpenPicker: () => void;
  onUpdate: (update: (bundle: PersonalBundle) => PersonalBundle) => void;
  resources: AuthorityResource[];
}) {
  const included = bundle.resourceIds
    .map((id) => resources.find((resource) => resource.id === id))
    .filter((resource): resource is AuthorityResource => Boolean(resource));
  const move = (index: number, direction: -1 | 1) =>
    onUpdate((current) => {
      const target = index + direction;
      if (target < 0 || target >= current.resourceIds.length) {
        return current;
      }
      const resourceIds = [...current.resourceIds];
      [resourceIds[index], resourceIds[target]] = [resourceIds[target], resourceIds[index]];
      return { ...current, resourceIds };
    });
  return (
    <section className="editor-surface">
      <div className="item-toolbar">
        <div className="item-tools">
          <IconButton icon={Plus} label="Add Resources" onClick={onOpenPicker} />
          <IconButton
            icon={Trash2}
            label="Delete Bundle"
            onClick={onDelete}
            tone="danger"
          />
        </div>
      </div>
      <div className="bundle-editor">
        <input
          aria-label="Bundle name"
          className="document-title"
          onChange={(event) =>
            onUpdate((current) => ({ ...current, name: event.target.value }))
          }
          value={bundle.name}
        />
        <textarea
          aria-label="Bundle description"
          className="bundle-description"
          onChange={(event) =>
            onUpdate((current) => ({ ...current, description: event.target.value }))
          }
          placeholder="What task is this bundle for?"
          rows={2}
          value={bundle.description}
        />
        <div className="bundle-resource-list">
          {included.length ? (
            included.map((resource, index) => (
              <div className="bundle-resource" key={resource.id}>
                <span>
                  <strong>{resource.document.title}</strong>
                  <small>{resource.kind} · Hub</small>
                </span>
                <div className="bundle-resource-actions">
                  <IconButton
                    disabled={index === 0}
                    icon={ArrowUp}
                    label="Move resource up"
                    onClick={() => move(index, -1)}
                  />
                  <IconButton
                    disabled={index === included.length - 1}
                    icon={ArrowDown}
                    label="Move resource down"
                    onClick={() => move(index, 1)}
                  />
                  <IconButton
                    icon={X}
                    label="Remove from bundle"
                    onClick={() =>
                      onUpdate((current) => ({
                        ...current,
                        resourceIds: current.resourceIds.filter((id) => id !== resource.id),
                      }))
                    }
                  />
                </div>
              </div>
            ))
          ) : (
            <EmptyState
              compact
              icon={Package}
              title="This bundle is empty"
              actionLabel="Add Resources"
              onAction={onOpenPicker}
            />
          )}
        </div>
      </div>
    </section>
  );
}

function ReviewsWorkspace({
  draft,
  filter,
  filteredReviews,
  onAddComment,
  onDiscardConflict,
  onFilterChange,
  onMerge,
  onOpenSearch,
  onPin,
  onSelect,
  onResolveConflict,
  onSourceWidthChange,
  onUpdateStatus,
  resource,
  review,
  reviews,
  selectedId,
  sourceWidth,
  tabStrip,
}: {
  draft: DraftRecord | null;
  filter: ReviewFilter;
  filteredReviews: ReviewRecord[];
  onAddComment: (reviewId: string, body: string) => void;
  onDiscardConflict: (reviewId: string) => void;
  onFilterChange: (filter: ReviewFilter) => void;
  onMerge: (reviewId: string) => void;
  onOpenSearch: () => void;
  onPin: (id: string) => void;
  onSelect: (id: string) => void;
  onResolveConflict: (reviewId: string, resolvedContent: string | null) => void;
  onSourceWidthChange: (width: number) => void;
  onUpdateStatus: (reviewId: string, status: ReviewStatus, note: string | null) => void;
  resource: AuthorityResource | null;
  review: ReviewRecord | null;
  reviews: ReviewRecord[];
  selectedId: string;
  sourceWidth: number;
  tabStrip: ReactNode;
}) {
  return (
    <PageLayout
      sourceWidth={sourceWidth}
      onSourceWidthChange={onSourceWidthChange}
      tabStrip={tabStrip}
      source={
        <>
          <div className="source-toolbar">
            <ReviewFilterNavigation
              filter={filter}
              onChange={onFilterChange}
              reviews={reviews}
            />
            <IconButton icon={Search} label="Search" onClick={onOpenSearch} />
          </div>
          <div className="resource-list" role="listbox" onKeyDown={moveListFocus}>
            {filteredReviews.map((entry) => (
              <button
                aria-selected={entry.id === selectedId}
                className={entry.id === selectedId ? "resource-row active" : "resource-row"}
                key={entry.id}
                onDoubleClick={() => onPin(entry.id)}
                onClick={() => onSelect(entry.id)}
                role="option"
                type="button"
              >
                <span>
                  <strong>{entry.title}</strong>
                  <small>{entry.author} · {entry.createdAt}</small>
                </span>
              </button>
            ))}
          </div>
        </>
      }
    >
      {review && draft ? (
        <ReviewEditor
          draft={draft}
          resource={resource}
          review={review}
          onAddComment={(body) => onAddComment(review.id, body)}
          onApprove={() => onUpdateStatus(review.id, "approved", "Approved for merge.")}
          onDiscardConflict={() => onDiscardConflict(review.id)}
          onMerge={() => onMerge(review.id)}
          onReject={() =>
            onUpdateStatus(review.id, "rejected", "Changes requested before resubmission.")
          }
          onResolveConflict={(content) => onResolveConflict(review.id, content)}
        />
      ) : (
        <EmptyState
          icon={GitPullRequest}
          title={filteredReviews.length ? "No open tab" : `No ${filter} reviews`}
        />
      )}
    </PageLayout>
  );
}

function ReviewFilterNavigation({
  filter,
  onChange,
  reviews,
}: {
  filter: ReviewFilter;
  onChange: (filter: ReviewFilter) => void;
  reviews: ReviewRecord[];
}) {
  return (
    <div aria-label="Review status" className="kind-navigation" role="tablist">
      {reviewFilters.map((entry) => {
        const Icon = reviewFilterIcons[entry];
        const count = reviews.filter((review) => review.status === entry).length;
        const label = capitalize(entry);
        return (
          <button
            aria-label={`${label}, ${count}`}
            aria-selected={filter === entry}
            className={filter === entry ? "kind-item active" : "kind-item"}
            key={entry}
            onClick={() => onChange(entry)}
            role="tab"
            title={`${label} · ${count}`}
            type="button"
          >
            <Icon aria-hidden="true" size={14} />
          </button>
        );
      })}
    </div>
  );
}

function ReviewEditor({
  draft,
  onAddComment,
  onApprove,
  onDiscardConflict,
  onMerge,
  onReject,
  onResolveConflict,
  resource,
  review,
}: {
  draft: DraftRecord;
  onAddComment: (body: string) => void;
  onApprove: () => void;
  onDiscardConflict: () => void;
  onMerge: () => void;
  onReject: () => void;
  onResolveConflict: (resolvedContent: string | null) => void;
  resource: AuthorityResource | null;
  review: ReviewRecord;
}) {
  const [comment, setComment] = useState("");
  const diff = reviewDiff(resource, draft);
  return (
    <section className="editor-surface">
      <div className="item-toolbar">
        <div className="review-meta">
          <span>{draft.kind}</span>
          <small>Base v{draft.baseVersion ?? 0}</small>
        </div>
        <div className="item-tools">
          {review.conflict ? (
            <>
              <IconButton icon={RefreshCw} label="Refresh Conflict" onClick={onMerge} />
              <IconButton
                icon={Trash2}
                label="Discard Conflicted Draft"
                onClick={onDiscardConflict}
                tone="danger"
              />
            </>
          ) : review.status === "open" ? (
            <>
              <IconButton icon={Check} label="Approve Review" onClick={onApprove} />
              <IconButton
                icon={X}
                label="Request Changes"
                onClick={onReject}
                tone="danger"
              />
            </>
          ) : review.status === "approved" ? (
            <IconButton icon={GitMerge} label="Merge Review" onClick={onMerge} />
          ) : null}
        </div>
      </div>
      <div className="review-editor">
        <header className="review-heading">
          <h1>{review.title}</h1>
          <p>{draft.document.path}</p>
        </header>
        {review.conflict ? (
          <ReviewConflictResolver
            draft={draft}
            onResolve={onResolveConflict}
            review={review}
          />
        ) : (
          <pre className="diff-viewer" aria-label="Resource changes">
            {diff.map((line, index) => (
              <span
                className={
                  line.startsWith("+")
                    ? "diff-add"
                    : line.startsWith("-")
                      ? "diff-remove"
                      : "diff-context"
                }
                key={`${index}-${line}`}
              >
                {line || " "}
              </span>
            ))}
          </pre>
        )}
        <section className="comments" aria-label="Review discussion">
          {review.comments.map((entry) => (
            <div className="comment" key={entry.id}>
              <div>
                <strong>{entry.author}</strong>
                <time>{entry.createdAt}</time>
              </div>
              <p>{entry.body}</p>
            </div>
          ))}
          <div className="comment-composer">
            <textarea
              aria-label="Review comment"
              onChange={(event) => setComment(event.target.value)}
              placeholder="Add a review note…"
              rows={2}
              value={comment}
            />
            <IconButton
              disabled={!comment.trim()}
              icon={Send}
              label="Add comment"
              onClick={() => {
                onAddComment(comment);
                setComment("");
              }}
            />
          </div>
        </section>
      </div>
    </section>
  );
}

function ReviewConflictResolver({
  draft,
  onResolve,
  review,
}: {
  draft: DraftRecord;
  onResolve: (resolvedContent: string | null) => void;
  review: ReviewRecord;
}) {
  const draftContent = review.operations
    ?.slice()
    .reverse()
    .find((operation) => operation.action === "create" || operation.action === "update")
    ?.body ?? null;
  const terminalOperation = review.operations?.[review.operations.length - 1] ?? null;
  const operationOnlyLabel = terminalOperation?.action === "rename"
    ? `Rename to ${terminalOperation.newPath ?? draft.document.path}`
    : terminalOperation?.action === "delete"
      ? `Delete ${draft.document.path}`
      : "No editable content";
  const operationOnlyTone = terminalOperation?.action === "delete" ? " danger" : "";
  const [resolvedContent, setResolvedContent] = useState(draftContent ?? "");

  useEffect(() => {
    setResolvedContent(draftContent ?? "");
  }, [draftContent, review.id, review.draftVersion]);

  if (!review.conflict) {
    return null;
  }

  return (
    <section className="conflict-resolver" aria-label="Draft conflict resolution">
      <div className="conflict-sources">
        <ConflictSource
          commitId={review.conflict.baseCommitId}
          content={review.conflict.baseContent}
          label="Base"
        />
        <ConflictSource
          commitId={review.conflict.currentCommitId}
          content={review.conflict.currentContent}
          label="Current"
        />
        <ConflictSource
          commitId={null}
          content={draftContent ?? operationOnlyLabel}
          label="Draft"
        />
      </div>
      <div className="conflict-result">
        <header>
          <span>Resolved</span>
          <button
            className="button primary"
            onClick={() => onResolve(draftContent === null ? null : resolvedContent)}
            type="button"
          >
            <GitPullRequest aria-hidden="true" size={14} />
            Reopen Review
          </button>
        </header>
        {draftContent === null ? (
          <div className={`conflict-operation${operationOnlyTone}`}>
            {terminalOperation?.action === "delete" ? (
              <Trash2 aria-hidden="true" size={16} />
            ) : (
              <FilePenLine aria-hidden="true" size={16} />
            )}
            <span>{operationOnlyLabel}</span>
          </div>
        ) : (
          <div className="conflict-resolution-editor">
            <TextEditor
              ariaLabel="Resolved draft content"
              onChange={setResolvedContent}
              path={draft.document.path}
              readOnly={false}
              value={resolvedContent}
            />
          </div>
        )}
      </div>
    </section>
  );
}

function ConflictSource({
  commitId,
  content,
  label,
}: {
  commitId: string | null;
  content: string | null;
  label: string;
}) {
  return (
    <section className="conflict-source">
      <header>
        <span>{label}</span>
        {commitId ? <code title={commitId}>{commitId.slice(0, 8)}</code> : null}
      </header>
      <pre>{content ?? "Not present"}</pre>
    </section>
  );
}

function PageLayout({
  children,
  onSourceWidthChange,
  source,
  sourceWidth,
  tabStrip,
}: {
  children: ReactNode;
  onSourceWidthChange: (width: number) => void;
  source: ReactNode;
  sourceWidth: number;
  tabStrip?: ReactNode;
}) {
  const style = {
    "--source-width": `${sourceWidth}px`,
  } as CSSProperties;
  return (
    <section className="page-layout" style={style}>
      <aside className="page-navigator">{source}</aside>
      <PaneResizer
        ariaLabel="Resize page navigator"
        side="left"
        value={sourceWidth}
        min={210}
        max={360}
        onChange={onSourceWidthChange}
      />
      <main className={tabStrip ? "page-body with-tabs" : "page-body"}>
        {tabStrip}
        <div className="page-active-item">{children}</div>
      </main>
    </section>
  );
}

function PaneResizer({
  ariaLabel,
  max,
  min,
  onChange,
  side,
  value,
}: {
  ariaLabel: string;
  max: number;
  min: number;
  onChange: (value: number) => void;
  side: "left" | "right";
  value: number;
}) {
  const onPointerDown = (event: PointerEvent<HTMLDivElement>) => {
    event.currentTarget.setPointerCapture(event.pointerId);
    const startX = event.clientX;
    const startValue = value;
    const move = (moveEvent: globalThis.PointerEvent) => {
      const delta = moveEvent.clientX - startX;
      const next = side === "left" ? startValue + delta : startValue - delta;
      onChange(Math.min(max, Math.max(min, next)));
    };
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  };
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") {
      return;
    }
    event.preventDefault();
    const screenDirection = event.key === "ArrowRight" ? 1 : -1;
    const valueDirection = side === "left" ? screenDirection : -screenDirection;
    const next = value + valueDirection * 12;
    onChange(Math.min(max, Math.max(min, next)));
  };
  return (
    <div
      aria-label={ariaLabel}
      aria-orientation="vertical"
      aria-valuemax={max}
      aria-valuemin={min}
      aria-valuenow={Math.round(value)}
      className={`pane-resizer ${side}`}
      onKeyDown={onKeyDown}
      onPointerDown={onPointerDown}
      role="separator"
      tabIndex={0}
    />
  );
}

function AgentPanel({
  onClose,
  target,
}: {
  onClose: () => void;
  target: AgentTarget | null;
}) {
  const [instruction, setInstruction] = useState("");
  const [state, setState] = useState<"idle" | "working" | "ready" | "applied">(
    "idle",
  );
  const timerRef = useRef<number | null>(null);

  useEffect(() => {
    setInstruction("");
    setState("idle");
    if (timerRef.current !== null) {
      window.clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, [target?.key]);

  useEffect(
    () => () => {
      if (timerRef.current !== null) {
        window.clearTimeout(timerRef.current);
      }
    },
    [],
  );

  const run = (nextInstruction?: string) => {
    const prompt = (nextInstruction ?? instruction).trim();
    if (!target || !prompt) {
      return;
    }
    setInstruction(prompt);
    setState("working");
    timerRef.current = window.setTimeout(() => setState("ready"), 650);
  };

  return (
    <aside
      aria-label="Agent"
      className={target ? "agent-pane" : "agent-pane empty"}
    >
      <div className="agent-toolbar">
        <span>Agent</span>
        <IconButton icon={X} label="Close Agent" onClick={onClose} />
      </div>
      {target ? (
        <>
          <div className="agent-context" title={target.label}>
            <span>{target.label}</span>
          </div>
          <div className="agent-thread">
            {state === "idle" ? (
              <div className="agent-suggestions">
                <strong>Suggested actions</strong>
                <div className="agent-quick-actions">
                  {target.quickActions.map((action) => (
                    <button key={action} onClick={() => run(action)} type="button">
                      <span>{action}</span>
                    </button>
                  ))}
                </div>
              </div>
            ) : (
              <div className="agent-exchange">
                <div className="agent-message user-message">
                  <strong>You</strong>
                  <p>{instruction}</p>
                </div>
                <div className="agent-message agent-message-response">
                  <div className="agent-response-mark">
                    {state === "working" ? (
                      <LoaderCircle aria-hidden="true" className="spin" size={15} />
                    ) : (
                      <Sparkles aria-hidden="true" size={15} />
                    )}
                  </div>
                  <div>
                    {state === "working" ? (
                      <p className="agent-working">Analyzing {target.label}…</p>
                    ) : (
                      <>
                        <strong>Proposed change</strong>
                        <p>{target.proposal}</p>
                        <div className="agent-proposal-actions">
                          {state === "applied" ? (
                            <span className="agent-applied">
                              <CheckCircle2 aria-hidden="true" size={14} />
                              Applied
                            </span>
                          ) : target.applyLabel === "No Change" ? (
                            <span className="agent-applied neutral">No change required</span>
                          ) : (
                            <button
                              className="button primary"
                              onClick={() => {
                                target.onApply();
                                setState("applied");
                              }}
                              type="button"
                            >
                              {target.applyLabel}
                            </button>
                          )}
                        </div>
                      </>
                    )}
                  </div>
                </div>
              </div>
            )}
          </div>
          <div className="agent-composer">
            <div className="agent-composer-field">
              <textarea
                aria-label="Agent instruction"
                disabled={state === "working"}
                onChange={(event) => setInstruction(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
                    event.preventDefault();
                    run();
                  }
                }}
                placeholder="Ask about this page…"
                rows={3}
                value={instruction}
              />
              <div className="agent-composer-actions">
                <IconButton
                  disabled={!instruction.trim() || state === "working"}
                  icon={state === "working" ? LoaderCircle : Send}
                  label="Send to Agent"
                  onClick={() => run()}
                />
              </div>
            </div>
          </div>
        </>
      ) : (
        <div className="agent-thread">
          <EmptyState compact icon={Sparkles} title="No page context" />
        </div>
      )}
    </aside>
  );
}

function ResourcePicker({
  bundle,
  onAdd,
  onClose,
  resources,
}: {
  bundle: PersonalBundle;
  onAdd: (resourceId: string) => void;
  onClose: () => void;
  resources: AuthorityResource[];
}) {
  const [query, setQuery] = useState("");
  const filtered = resources.filter((resource) =>
    `${resource.document.title} ${resource.kind}`
      .toLocaleLowerCase()
      .includes(query.trim().toLocaleLowerCase()),
  );
  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={onClose}>
      <section
        aria-label="Add resources to bundle"
        aria-modal="true"
        className="resource-picker"
        onMouseDown={(event) => event.stopPropagation()}
        role="dialog"
      >
        <div className="modal-heading">
          <strong>Add resources</strong>
          <IconButton icon={X} label="Close" onClick={onClose} />
        </div>
        <div className="picker-search">
          <Search aria-hidden="true" size={14} />
          <input
            aria-label="Filter Hub resources"
            autoFocus
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Filter Hub resources…"
            value={query}
          />
        </div>
        <div className="picker-results">
          {filtered.map((resource) => {
            const included = bundle.resourceIds.includes(resource.id);
            return (
              <button
                className="picker-row"
                disabled={included}
                key={resource.id}
                onClick={() => onAdd(resource.id)}
                type="button"
              >
                <MemoryKindIcon kind={resource.kind} />
                <span>
                  <strong>{resource.document.title}</strong>
                  <small>{resource.kind}</small>
                </span>
                {included ? <Check aria-hidden="true" size={14} /> : <Plus aria-hidden="true" size={14} />}
              </button>
            );
          })}
        </div>
      </section>
    </div>
  );
}

function ConfirmDialog({
  onCancel,
  state,
}: {
  onCancel: () => void;
  state: ConfirmState;
}) {
  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={onCancel}>
      <section
        aria-describedby="confirm-message"
        aria-labelledby="confirm-title"
        aria-modal="true"
        className="confirm-dialog"
        onMouseDown={(event) => event.stopPropagation()}
        role="alertdialog"
      >
        <div className="confirm-icon">
          <AlertTriangle aria-hidden="true" size={18} />
        </div>
        <div>
          <h2 id="confirm-title">{state.title}</h2>
          <p id="confirm-message">{state.message}</p>
        </div>
        <div className="confirm-actions">
          <button autoFocus className="button" onClick={onCancel} type="button">
            Cancel
          </button>
          <button
            className={state.tone === "danger" ? "button danger" : "button primary"}
            onClick={state.onConfirm}
            type="button"
          >
            {state.confirmLabel}
          </button>
        </div>
      </section>
    </div>
  );
}

function DiagnosticsView({
  loadState,
  onCommand,
  onRefresh,
  onRetrySync,
}: {
  loadState: LoadState;
  onCommand: (command: string) => void;
  onRefresh: () => void;
  onRetrySync: () => void;
}) {
  const rows = daemonRows(loadState);
  return (
    <section className="utility-view" aria-label="Diagnostics">
      <div className="utility-actions">
        <button className="button" onClick={() => onCommand("install_daemon_launch_agent")} type="button">
          Install
        </button>
        <button className="button" onClick={() => onCommand("start_daemon_launch_agent")} type="button">
          Start
        </button>
        <button className="button" onClick={() => onCommand("restart_daemon_launch_agent")} type="button">
          Restart
        </button>
        <button className="button" onClick={() => onCommand("stop_daemon_launch_agent")} type="button">
          Stop
        </button>
        <IconButton icon={RefreshCw} label="Retry synchronization" onClick={onRetrySync} />
        <IconButton icon={RefreshCw} label="Refresh daemon status" onClick={onRefresh} />
      </div>
      {loadState.status === "failed" ? (
        <div className="persistent-message error" role="alert">
          <AlertTriangle aria-hidden="true" size={16} />
          <span>{loadState.message}</span>
        </div>
      ) : null}
      <dl className="metadata-list">
        {rows.map(([label, value]) => (
          <div key={label}>
            <dt>{label}</dt>
            <dd>{value}</dd>
          </div>
        ))}
      </dl>
    </section>
  );
}

function SettingsView({
  loadState,
  onOpenDiagnostics,
  projectName,
}: {
  loadState: LoadState;
  onOpenDiagnostics: () => void;
  projectName: string;
}) {
  const hubUrl =
    loadState.status === "ready"
      ? (loadState.projectConfig?.server_url ?? loadState.health?.server_url ?? "Not configured")
      : "Unavailable";
  return (
    <section className="utility-view settings-view" aria-label="Settings">
      <section className="settings-section">
        <h2>Connection</h2>
        <label className="settings-row">
          <span>Server URL</span>
          <input readOnly value={hubUrl} />
        </label>
        <label className="settings-row">
          <span>Project</span>
          <input readOnly value={projectName} />
        </label>
      </section>
      <section className="settings-section">
        <h2>Local runtime</h2>
        <div className="settings-row">
          <span>Draft synchronization</span>
          <strong>Automatic</strong>
        </div>
        <div className="settings-row">
          <span>Background service</span>
          <strong>LaunchAgent</strong>
        </div>
        <button
          className="settings-row settings-action"
          onClick={onOpenDiagnostics}
          type="button"
        >
          <span>Daemon diagnostics</span>
          <strong>Open</strong>
        </button>
      </section>
    </section>
  );
}

function AuthenticationView({
  message,
  onAuthenticate,
}: {
  message?: string;
  onAuthenticate: () => void;
}) {
  return (
    <section className="session-view" aria-labelledby="sign-in-title">
      <form
        className="session-form"
        onSubmit={(event) => {
          event.preventDefault();
          onAuthenticate();
        }}
      >
        <h1 id="sign-in-title">Sign in</h1>
        <p>Continue with your organization account.</p>
        {message ? <p className="session-error" role="alert">{message}</p> : null}
        <button className="button primary" type="submit">
          Continue with SSO
        </button>
      </form>
    </section>
  );
}

function ConnectionStateView({
  message,
  onRetry,
  state,
}: {
  message?: string;
  onRetry: () => void;
  state: "loading" | "failed";
}) {
  return (
    <section className="session-view" aria-live="polite">
      <div className="connection-state">
        {state === "loading" ? (
          <>
            <LoaderCircle aria-hidden="true" className="spin" size={18} />
            <p>Connecting to Server…</p>
          </>
        ) : (
          <>
            <strong>Server unavailable</strong>
            <p>{message}</p>
            <button className="button" onClick={onRetry} type="button">
              <RefreshCw aria-hidden="true" size={14} />
              Retry
            </button>
          </>
        )}
      </div>
    </section>
  );
}

function EmptyState({
  actionLabel,
  compact,
  icon: Icon,
  onAction,
  title,
}: {
  actionLabel?: string;
  compact?: boolean;
  icon: LucideIcon;
  onAction?: () => void;
  title: string;
}) {
  return (
    <div className={compact ? "empty-state compact" : "empty-state"}>
      <Icon aria-hidden="true" size={compact ? 18 : 22} />
      <p>{title}</p>
      {actionLabel && onAction ? (
        <button className="button" onClick={onAction} type="button">
          <Plus aria-hidden="true" size={14} />
          {actionLabel}
        </button>
      ) : null}
    </div>
  );
}

function IconButton({
  disabled,
  icon: Icon,
  label,
  onClick,
  tone,
}: {
  disabled?: boolean;
  icon: LucideIcon;
  label: string;
  onClick: () => void;
  tone?: "danger";
}) {
  return (
    <button
      aria-label={label}
      className={tone === "danger" ? "icon-button danger" : "icon-button"}
      disabled={disabled}
      onClick={onClick}
      title={label}
      type="button"
    >
      <Icon aria-hidden="true" size={15} />
    </button>
  );
}

function MemoryKindIcon({ kind }: { kind: MemoryKind }) {
  const Icon = kindIcons[kind];
  return <Icon aria-hidden="true" size={14} />;
}

function SyncMark({
  compact,
  state,
}: {
  compact?: boolean;
  state: SyncState;
}) {
  const Icon =
    state === "syncing"
      ? LoaderCircle
      : state === "conflict" || state === "failed"
        ? AlertTriangle
        : state === "local"
          ? CloudOff
          : Cloud;
  return (
    <Icon
      aria-label={syncLabel(state)}
      className={state === "syncing" ? "spin" : undefined}
      size={compact ? 13 : 14}
    />
  );
}

function kindCounts(
  resources: AuthorityResource[],
  drafts: DraftRecord[],
  scope: MemoryScope,
  projectId: string | null,
): Record<MemoryKind, number> {
  return Object.fromEntries(
    memoryKinds.map((kind) => [kind, listResources(resources, drafts, scope, projectId, kind).length]),
  ) as Record<MemoryKind, number>;
}

function buildTree(items: ResourceListItem[]): TreeNode[] {
  const root: TreeNode = { name: "", path: "", children: [] };
  for (const item of items) {
    const parts = item.document.path.split("/").filter(Boolean);
    let current = root;
    for (const [index, part] of parts.entries()) {
      const path = current.path ? `${current.path}/${part}` : part;
      let child = current.children.find((node) => node.name === part);
      if (!child) {
        child = { name: part, path, children: [] };
        current.children.push(child);
      }
      if (index === parts.length - 1) {
        child.item = item;
      }
      current = child;
    }
  }
  const sort = (nodes: TreeNode[]): TreeNode[] =>
    nodes
      .map((node) => ({ ...node, children: sort(node.children) }))
      .sort((left, right) => {
        if (Boolean(left.item) !== Boolean(right.item)) {
          return left.item ? 1 : -1;
        }
        return left.name.localeCompare(right.name);
      });
  return sort(root.children);
}

function moveTreeFocus(event: KeyboardEvent<HTMLDivElement>) {
  if (event.key !== "ArrowDown" && event.key !== "ArrowUp") {
    return;
  }
  const nodes = Array.from(
    event.currentTarget.querySelectorAll<HTMLElement>("[role='treeitem']"),
  ).filter((node) => node.offsetParent !== null);
  const index = nodes.indexOf(document.activeElement as HTMLElement);
  const next = event.key === "ArrowDown" ? index + 1 : index - 1;
  if (nodes[next]) {
    event.preventDefault();
    nodes[next].focus();
  }
}

function moveListFocus(event: KeyboardEvent<HTMLDivElement>) {
  if (event.key !== "ArrowDown" && event.key !== "ArrowUp") {
    return;
  }
  const options = Array.from(
    event.currentTarget.querySelectorAll<HTMLElement>("[role='option']"),
  );
  const index = options.indexOf(document.activeElement as HTMLElement);
  const next = event.key === "ArrowDown" ? index + 1 : index - 1;
  if (options[next]) {
    event.preventDefault();
    options[next].focus();
  }
}

function resourceSecondaryText(item: ResourceListItem): string {
  if (item.kind === "Rules") {
    return item.document.appliesWhen;
  }
  if (item.kind === "Workflows") {
    return `${item.document.steps.length} steps`;
  }
  return item.document.path;
}

function workingStateLabel(state: ResourceWorkingState): string | null {
  if (state === "draft") {
    return "Draft";
  }
  if (state === "new") {
    return "New draft";
  }
  if (state === "deletion") {
    return "Deletion draft";
  }
  if (state === "review") {
    return "Review open";
  }
  if (state === "conflict") {
    return "Conflict";
  }
  return null;
}

function resourceNameClass(item: ResourceListItem): string {
  const state = resourceWorkingState(item);
  return state === "clean" ? "resource-name" : `resource-name ${state}`;
}

function resourceStateAriaLabel(item: ResourceListItem, name: string): string {
  const state = workingStateLabel(resourceWorkingState(item));
  return state ? `${name}, ${state}` : name;
}

function fileNameFromPath(path: string): string {
  const segments = path.split("/").filter(Boolean);
  return segments[segments.length - 1] ?? path;
}

function isMarkdownPath(path: string): boolean {
  return /\.(md|markdown)$/i.test(path);
}

function syncLabel(state: SyncState): string {
  if (state === "syncing") {
    return "Saving…";
  }
  if (state === "conflict") {
    return "Conflict";
  }
  if (state === "failed") {
    return "Save failed";
  }
  if (state === "local") {
    return "Saved locally";
  }
  return "Synced";
}

function capitalize(value: string): string {
  return `${value.charAt(0).toUpperCase()}${value.slice(1)}`;
}

function accountInitials(account: DesktopAccount): string {
  const source = account.displayName?.trim() || account.email.split("@")[0] || "?";
  const words = source.split(/\s+/).filter(Boolean);
  const initials = words.length > 1
    ? `${words[0][0] ?? ""}${words[words.length - 1][0] ?? ""}`
    : Array.from(source).slice(0, 2).join("");
  return initials.toUpperCase();
}

function markdownTitle(body: string, fallback: string): string {
  const heading = body.match(/^#\s+(.+)$/m)?.[1].trim();
  return heading || fallback;
}

function findMemoryTabItem(
  tab: Extract<WorkspaceTab, { view: "Hub" | "Local" }>,
  resources: AuthorityResource[],
  drafts: DraftRecord[],
): ResourceListItem | null {
  const scope = tab.view === "Hub" ? "Hub" : "Project";
  return (
    listResources(resources, drafts, scope, tab.projectId, tab.kind).find(
      (item) => item.selectionId === tab.targetId,
    ) ?? null
  );
}

function refEtag(commitId: string | null): string {
  return `"${commitId ?? "ref-none"}"`;
}

function apiErrorCode(error: ClumsiesApiError): string | null {
  const envelope = error.details;
  if (!envelope || typeof envelope !== "object" || !("error" in envelope)) {
    return null;
  }
  const detail = envelope.error;
  return detail
    && typeof detail === "object"
    && "code" in detail
    && typeof detail.code === "string"
    ? detail.code
    : null;
}

function daemonRows(state: LoadState): [string, string][] {
  if (state.status === "preview") {
    return [
      ["Mode", "Browser preview"],
      ["Transport", "XPC available in Desktop"],
      ["Draft sync", "Simulated for product validation"],
    ];
  }
  if (state.status === "loading") {
    return [["Status", "Checking…"]];
  }
  if (state.status === "failed") {
    return [["Status", "Unavailable"]];
  }
  if (state.status === "authentication_required") {
    return [["Status", "Sign-in required"]];
  }
  const { bootstrap, health, mcpStatus, projectConfig, syncStatus } = state;
  return [
    ["LaunchAgent", bootstrap.label],
    ["Mach service", bootstrap.mach_service_name],
    ["Installed", bootstrap.installed ? "Yes" : "No"],
    ["Running", bootstrap.runtime.running ? "Yes" : "No"],
    ["PID", bootstrap.runtime.pid ? String(bootstrap.runtime.pid) : "None"],
    ["Version", health?.daemon_version ?? "Unknown"],
    ["Server", health?.server_url ?? "Unknown"],
    ["Project", health?.project_id ?? "Not selected"],
    ["Local database", health?.local_db.ready ? "Ready" : "Unknown"],
    ["Project config", projectConfig?.ready ? "Ready" : "Incomplete"],
    ["Draft sync", syncStatus?.draft_sync.state ?? "Unknown"],
    ["Commit sync", syncStatus?.commit_sync.state ?? "Unknown"],
    ["Pending operations", String(syncStatus?.pending_operation_count ?? 0)],
    ["Failed operations", String(syncStatus?.failed_operation_count ?? 0)],
    ["Conflicts", String(syncStatus?.conflict_count ?? 0)],
    ["MCP", mcpStatus?.running ? "Running" : "Not daemon-managed"],
    ["Last error", bootstrap.runtime.last_error ?? "None"],
  ];
}
