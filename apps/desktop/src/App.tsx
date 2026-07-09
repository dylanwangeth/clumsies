import type { ReactNode } from "react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { invoke } from "@tauri-apps/api/core";

type DaemonBootstrapStatus = {
  label: string;
  mach_service_name: string;
  plist_path: string;
  installed: boolean;
  endpoint: {
    transport: "macos_xpc_mach_service";
    service_name: string;
  };
  runtime: {
    installed: boolean;
    bootstrapped: boolean;
    running: boolean;
    pid: number | null;
    state: string | null;
    last_exit_code: number | null;
    last_error: string | null;
  };
};

type DaemonHealth = {
  daemon_version: string;
  hub_url: string;
  project_id: string | null;
  daemon_installation_id: string;
  log_dir: string;
  local_db: {
    path: string;
    ready: boolean;
    schema_version: number;
  };
};

type LoadState =
  | { status: "idle" | "loading" }
  | {
      status: "ready";
      bootstrap: DaemonBootstrapStatus;
      health: DaemonHealth | null;
    }
  | { status: "failed"; message: string };

type PrimaryView = "Hub" | "Memory" | "Bundles" | "Reviews";
type UtilityView = "Diagnostics" | "Settings";
type View = PrimaryView | UtilityView;
type MemoryType = "Context" | "Rules" | "Workflows" | "Metaprompt";
type HubType = MemoryType;
type BundleName = string;
type ReviewQueue = "Awaiting" | "Submitted" | "Approved" | "Merged";
type ResourceRow = {
  id: string;
  name: string;
  detail: string;
  state: string;
};
type MetadataRow = [string, string];
type SourceEntry<T extends string> = {
  label: T;
  count: string;
};
type BundleRecord = {
  resources: ResourceRow[];
  metadata: MetadataRow[];
};
type AgentContext = {
  detail: string;
  draft: string[];
  intent: string;
  quickActions: string[];
  state: string;
  target: string;
};
type ObjectAction = {
  label: string;
  onClick: () => void;
  tone?: "primary" | "danger";
};
type FileTreeNode = {
  children: FileTreeNode[];
  name: string;
  path: string;
  resource?: ResourceRow;
};

const primaryViews: PrimaryView[] = ["Hub", "Memory", "Bundles", "Reviews"];
const utilityViews: UtilityView[] = ["Diagnostics", "Settings"];
const memoryTypes: MemoryType[] = ["Context", "Rules", "Workflows", "Metaprompt"];
const hubTypes: HubType[] = ["Context", "Rules", "Workflows", "Metaprompt"];
const initialBundleNames: BundleName[] = [
  "Daily Coding",
  "Architecture Review",
  "Writing",
];
const reviewQueues: ReviewQueue[] = ["Awaiting", "Submitted", "Approved", "Merged"];

const hubRows: Record<HubType, ResourceRow[]> = {
  Context: [
    {
      id: "org-context-desktop-product",
      name: "Desktop product architecture",
      detail: "context/org/desktop-product.md",
      state: "Published",
    },
    {
      id: "org-context-external-memory",
      name: "External memory model",
      detail: "context/org/external-memory.md",
      state: "Published",
    },
    {
      id: "org-context-deployment-handbook",
      name: "Deployment handbook",
      detail: "context/org/deployment.md",
      state: "Draft",
    },
  ],
  Rules: [
    {
      id: "org-rule-compatibility-policy",
      name: "Compatibility policy",
      detail: "rules/coding/COMPATIBILITY.md",
      state: "Published",
    },
    {
      id: "org-rule-ui-product-rules",
      name: "UI product rules",
      detail: "rules/style/UIUX_DESIGN_METHOD.md",
      state: "Draft",
    },
  ],
  Workflows: [
    {
      id: "org-workflow-coding",
      name: "Coding workflow",
      detail: "workflow/CODING.md",
      state: "Published",
    },
    {
      id: "org-workflow-commit-message",
      name: "Commit message workflow",
      detail: "workflow/GEN_COMMIT_MSG.md",
      state: "Published",
    },
  ],
  Metaprompt: [
    {
      id: "org-metaprompt-default-agent",
      name: "Default agent prompt",
      detail: "mpf/META_PROMPT.md",
      state: "Published",
    },
  ],
};

const memoryRows: Record<MemoryType, ResourceRow[]> = {
  Context: [
    {
      id: "project-context-desktop-daemon-decision",
      name: "Desktop daemon decision",
      detail: "adr/ADR_012_DESKTOP_DAEMON_LOCAL_MEMORY_RUNTIME.md",
      state: "Synced",
    },
    {
      id: "project-context-production-architecture",
      name: "Production architecture",
      detail: "clumsies/外部记忆生产化架构设计.md",
      state: "Local draft",
    },
  ],
  Rules: [
    {
      id: "project-rule-no-compatibility-layers",
      name: "No compatibility layers",
      detail: "coding/COMPATIBILITY.md",
      state: "Synced",
    },
    {
      id: "project-rule-semantic-single-source",
      name: "Semantic single source",
      detail: "style/UIUX_DESIGN_METHOD.md",
      state: "Local draft",
    },
  ],
  Workflows: [
    {
      id: "project-workflow-coding",
      name: "Coding",
      detail: "workflow/CODING.md",
      state: "Synced",
    },
    {
      id: "project-workflow-todo-capture",
      name: "Todo capture",
      detail: "workflow/TODO.md",
      state: "Synced",
    },
  ],
  Metaprompt: [
    {
      id: "project-metaprompt-workspace",
      name: "Workspace metaprompt",
      detail: "META_PROMPT.md",
      state: "Synced",
    },
  ],
};

const bundleCatalog: Record<BundleName, BundleRecord> = {
  "Daily Coding": {
    resources: [
      {
        id: "bundle-daily-org-rule-compatibility-policy",
        name: "Compatibility policy",
        detail: "Organization rule",
        state: "Included",
      },
      {
        id: "bundle-daily-org-context-external-memory",
        name: "External memory model",
        detail: "Organization context",
        state: "Included",
      },
      {
        id: "bundle-daily-org-workflow-coding",
        name: "Coding workflow",
        detail: "Organization workflow",
        state: "Included",
      },
    ],
    metadata: [
      ["State", "Active"],
      ["Owner", "weiwang"],
      ["Contents", "11 rules, 16 context docs, 2 workflows"],
      ["Rules", "11"],
      ["Context", "16"],
      ["Workflows", "2"],
    ],
  },
  "Architecture Review": {
    resources: [
      {
        id: "bundle-architecture-org-context-desktop-product",
        name: "Desktop product architecture",
        detail: "Organization context",
        state: "Included",
      },
      {
        id: "bundle-architecture-org-context-external-memory",
        name: "External memory model",
        detail: "Organization context",
        state: "Included",
      },
      {
        id: "bundle-architecture-org-rule-ui-product-rules",
        name: "UI product rules",
        detail: "Organization rule",
        state: "Included",
      },
    ],
    metadata: [
      ["State", "Ready"],
      ["Owner", "weiwang"],
      ["Contents", "7 rules, 9 context docs, 4 workflows"],
      ["Rules", "7"],
      ["Context", "9"],
      ["Workflows", "4"],
    ],
  },
  Writing: {
    resources: [
      {
        id: "bundle-writing-org-rule-terminology",
        name: "Terminology",
        detail: "Organization rule",
        state: "Included",
      },
      {
        id: "bundle-writing-org-rule-citation-format",
        name: "Citation format",
        detail: "Organization rule",
        state: "Included",
      },
      {
        id: "bundle-writing-org-context-writing-standards",
        name: "Writing standards",
        detail: "Organization context",
        state: "Included",
      },
    ],
    metadata: [
      ["State", "Ready"],
      ["Owner", "weiwang"],
      ["Contents", "5 rules, 12 context docs"],
      ["Rules", "5"],
      ["Context", "12"],
      ["Workflows", "0"],
    ],
  },
};

const reviewRows: Record<ReviewQueue, ResourceRow[]> = {
  Awaiting: [
    {
      id: "review-desktop-shell-ia",
      name: "Desktop shell IA",
      detail: "Context",
      state: "Awaiting",
    },
    {
      id: "review-semantic-single-source-rule",
      name: "Semantic single source rule",
      detail: "Rules",
      state: "Awaiting",
    },
  ],
  Submitted: [
    {
      id: "review-bundle-review-detail",
      name: "Bundle review detail",
      detail: "Bundles",
      state: "Submitted",
    },
  ],
  Approved: [
    {
      id: "review-rust-daemon-boundary",
      name: "Rust daemon boundary",
      detail: "Context",
      state: "Approved",
    },
  ],
  Merged: [
    {
      id: "review-macos-ipc-runtime",
      name: "macOS IPC runtime",
      detail: "Context",
      state: "Merged",
    },
  ],
};

export function App() {
  const [selectedView, setSelectedView] = useState<View>("Memory");
  const [selectedHubType, setSelectedHubType] = useState<HubType>("Context");
  const [selectedMemoryType, setSelectedMemoryType] = useState<MemoryType>("Context");
  const [selectedBundle, setSelectedBundle] = useState<BundleName>("Daily Coding");
  const [selectedReviewQueue, setSelectedReviewQueue] =
    useState<ReviewQueue>("Awaiting");
  const [selectedHubResourceKey, setSelectedHubResourceKey] = useState<string | null>(
    null,
  );
  const [selectedMemoryResourceKey, setSelectedMemoryResourceKey] = useState<
    string | null
  >(null);
  const [selectedReviewKey, setSelectedReviewKey] = useState<string | null>(null);
  const [searchByView, setSearchByView] = useState<Record<PrimaryView, string>>({
    Hub: "",
    Memory: "",
    Bundles: "",
    Reviews: "",
  });
  const [loadState, setLoadState] = useState<LoadState>({ status: "idle" });
  const [hubData, setHubData] = useState<Record<HubType, ResourceRow[]>>(hubRows);
  const [memoryData, setMemoryData] =
    useState<Record<MemoryType, ResourceRow[]>>(memoryRows);
  const [bundleData, setBundleData] =
    useState<Record<BundleName, BundleRecord>>(bundleCatalog);
  const [bundleOrder, setBundleOrder] =
    useState<BundleName[]>(initialBundleNames);
  const [reviewsData, setReviewsData] =
    useState<Record<ReviewQueue, ResourceRow[]>>(reviewRows);

  const updateSearch = useCallback((view: PrimaryView, query: string) => {
    setSearchByView((current) => ({ ...current, [view]: query }));
  }, []);

  const createHubResource = useCallback((type: HubType) => {
    const resource = createResource("Hub", type);
    setHubData((current) => appendGroupedResource(current, type, resource));
    setSelectedHubType(type);
    setSelectedHubResourceKey(resourceKey(resource));
  }, []);

  const saveHubResource = useCallback((type: HubType, row: ResourceRow) => {
    setHubData((current) => updateGroupedResourceState(current, type, row, "Draft"));
  }, []);

  const publishHubResource = useCallback((type: HubType, row: ResourceRow) => {
    setHubData((current) =>
      updateGroupedResourceState(current, type, row, "Published"),
    );
  }, []);

  const deleteHubResource = useCallback((type: HubType, row: ResourceRow) => {
    setHubData((current) => removeGroupedResource(current, type, row));
    setSelectedHubResourceKey(null);
  }, []);

  const createMemoryResource = useCallback((type: MemoryType) => {
    const resource = createResource("Project", type);
    setMemoryData((current) => appendGroupedResource(current, type, resource));
    setSelectedMemoryType(type);
    setSelectedMemoryResourceKey(resourceKey(resource));
  }, []);

  const saveMemoryResource = useCallback((type: MemoryType, row: ResourceRow) => {
    setMemoryData((current) =>
      updateGroupedResourceState(current, type, row, "Local draft"),
    );
  }, []);

  const submitMemoryResource = useCallback((type: MemoryType, row: ResourceRow) => {
    setMemoryData((current) =>
      updateGroupedResourceState(current, type, row, "Submitted"),
    );
    setReviewsData((current) => appendReview(current, type, row));
  }, []);

  const deleteMemoryResource = useCallback((type: MemoryType, row: ResourceRow) => {
    setMemoryData((current) => removeGroupedResource(current, type, row));
    setSelectedMemoryResourceKey(null);
  }, []);

  const createBundle = useCallback(() => {
    const name = createBundleName(bundleData);
    setBundleData((current) => ({
      ...current,
      [name]: emptyBundleRecord(),
    }));
    setBundleOrder((current) => [name, ...current]);
    setSelectedBundle(name);
  }, [bundleData]);

  const saveBundle = useCallback((name: BundleName) => {
    setBundleData((current) => updateBundleMetadata(current, name, "State", "Ready"));
  }, []);

  const addBundleResource = useCallback((name: BundleName) => {
    setBundleData((current) => appendBundleResource(current, name));
  }, []);

  const deleteBundle = useCallback((name: BundleName) => {
    setBundleData((current) => {
      const remaining = { ...current };
      delete remaining[name];
      return remaining;
    });
    const nextOrder = bundleOrder.filter((item) => item !== name);
    setBundleOrder(nextOrder);
    setSelectedBundle(nextOrder[0] ?? "");
  }, [bundleOrder]);

  const approveReview = useCallback((queue: ReviewQueue, row: ResourceRow) => {
    setReviewsData((current) => moveReview(current, queue, "Approved", row));
    setSelectedReviewQueue("Approved");
    setSelectedReviewKey(resourceKey(row));
  }, []);

  const rejectReview = useCallback((queue: ReviewQueue, row: ResourceRow) => {
    setReviewsData((current) => removeGroupedResource(current, queue, row));
    setSelectedReviewKey(null);
  }, []);

  const mergeReview = useCallback((queue: ReviewQueue, row: ResourceRow) => {
    setReviewsData((current) => moveReview(current, queue, "Merged", row));
    setSelectedReviewQueue("Merged");
    setSelectedReviewKey(resourceKey(row));
  }, []);

  const runLaunchAgentCommand = useCallback(async (command: string) => {
    setLoadState({ status: "loading" });
    try {
      const bootstrap = await invoke<DaemonBootstrapStatus>(command);
      setLoadState({ status: "ready", bootstrap, health: null });
    } catch (error) {
      setLoadState({
        status: "failed",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }, []);

  const refreshBootstrap = useCallback(
    () => runLaunchAgentCommand("read_daemon_bootstrap_status"),
    [runLaunchAgentCommand],
  );

  const readHealth = useCallback(async () => {
    setLoadState({ status: "loading" });
    try {
      const [bootstrap, health] = await Promise.all([
        invoke<DaemonBootstrapStatus>("read_daemon_bootstrap_status"),
        invoke<DaemonHealth>("read_daemon_health"),
      ]);
      setLoadState({ status: "ready", bootstrap, health });
    } catch (error) {
      setLoadState({
        status: "failed",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }, []);

  useEffect(() => {
    void refreshBootstrap();
  }, [refreshBootstrap]);

  const status = useMemo(() => daemonStatus(loadState), [loadState]);
  const selectedPrimaryView = primaryViews.includes(selectedView as PrimaryView)
    ? (selectedView as PrimaryView)
    : null;

  return (
    <main className="app-shell">
      <aside className="sidebar">
        <div className="traffic-lights" aria-hidden="true">
          <span className="traffic-light red" />
          <span className="traffic-light yellow" />
          <span className="traffic-light green" />
        </div>
        <div className="brand">
          <span className="brand-mark">C</span>
          <strong>clumsies</strong>
        </div>

        <nav className="nav-section" aria-label="Primary">
          {primaryViews.map((view) => (
            <button
              className={view === selectedView ? "nav-item active" : "nav-item"}
              key={view}
              onClick={() => setSelectedView(view)}
              type="button"
            >
              {view}
            </button>
          ))}
        </nav>

        <div className="sidebar-footer">
          <button
            className="sync-summary"
            onClick={() => setSelectedView("Diagnostics")}
            type="button"
          >
            <span className={status.dotClass} />
            <span>{status.label}</span>
          </button>
          <nav className="utility-nav" aria-label="Utilities">
            {utilityViews.map((view) => (
              <button
                className={
                  view === selectedView ? "utility-item active" : "utility-item"
                }
                key={view}
                onClick={() => setSelectedView(view)}
                type="button"
              >
                {view}
              </button>
            ))}
          </nav>
        </div>
      </aside>

      <section className={selectedPrimaryView ? "workspace with-search" : "workspace"}>
        {selectedPrimaryView ? (
          <div className="workspace-searchbar">
            <SearchField
              value={searchByView[selectedPrimaryView]}
              onChange={(query) => updateSearch(selectedPrimaryView, query)}
            />
          </div>
        ) : null}
        <div className="workspace-content">
          {selectedView === "Hub" ? (
            <HubView
              rowsByType={hubData}
              selectedType={selectedHubType}
              onSelectType={setSelectedHubType}
              selectedResourceKey={selectedHubResourceKey}
              onSelectResource={setSelectedHubResourceKey}
              searchQuery={searchByView.Hub}
              onCreateResource={createHubResource}
              onSaveResource={saveHubResource}
              onPublishResource={publishHubResource}
              onDeleteResource={deleteHubResource}
            />
          ) : selectedView === "Memory" ? (
            <MemoryView
              rowsByType={memoryData}
              selectedType={selectedMemoryType}
              onSelectType={setSelectedMemoryType}
              selectedResourceKey={selectedMemoryResourceKey}
              onSelectResource={setSelectedMemoryResourceKey}
              searchQuery={searchByView.Memory}
              onCreateResource={createMemoryResource}
              onSaveResource={saveMemoryResource}
              onSubmitResource={submitMemoryResource}
              onDeleteResource={deleteMemoryResource}
            />
          ) : selectedView === "Bundles" ? (
            <BundlesView
              bundlesByName={bundleData}
              bundleNames={bundleOrder}
              selectedBundle={selectedBundle}
              onSelectBundle={setSelectedBundle}
              searchQuery={searchByView.Bundles}
              onCreateBundle={createBundle}
              onSaveBundle={saveBundle}
              onAddResource={addBundleResource}
              onDeleteBundle={deleteBundle}
            />
          ) : selectedView === "Reviews" ? (
            <ReviewsView
              rowsByQueue={reviewsData}
              selectedQueue={selectedReviewQueue}
              onSelectQueue={setSelectedReviewQueue}
              selectedReviewKey={selectedReviewKey}
              onSelectReview={setSelectedReviewKey}
              searchQuery={searchByView.Reviews}
              onApproveReview={approveReview}
              onRejectReview={rejectReview}
              onMergeReview={mergeReview}
            />
          ) : selectedView === "Diagnostics" ? (
            <DiagnosticsView
              loadState={loadState}
              onCommand={runLaunchAgentCommand}
              onRefresh={readHealth}
            />
          ) : (
            <SettingsView />
          )}
        </div>
      </section>
    </main>
  );
}

function HubView({
  onCreateResource,
  onDeleteResource,
  onPublishResource,
  onSaveResource,
  onSelectType,
  onSelectResource,
  rowsByType,
  searchQuery,
  selectedResourceKey,
  selectedType,
}: {
  onCreateResource: (type: HubType) => void;
  onDeleteResource: (type: HubType, row: ResourceRow) => void;
  onPublishResource: (type: HubType, row: ResourceRow) => void;
  onSaveResource: (type: HubType, row: ResourceRow) => void;
  onSelectType: (type: HubType) => void;
  onSelectResource: (resourceKey: string) => void;
  rowsByType: Record<HubType, ResourceRow[]>;
  searchQuery: string;
  selectedResourceKey: string | null;
  selectedType: HubType;
}) {
  const filteredRowsByType = filterRowsByGroup(rowsByType, searchQuery);
  const rows = filteredRowsByType[selectedType];
  const selectedRow = selectedResource(rows, selectedResourceKey);
  const body = resourceMarkdown("Hub", selectedType, selectedRow);
  const agentContext = resourceAgentContext("Hub", selectedType, selectedRow);
  const actions = resourceActions("Hub", selectedType, selectedRow, {
    onCreate: () => onCreateResource(selectedType),
    onDelete: () => onDeleteResource(selectedType, selectedRow),
    onPublish: () => onPublishResource(selectedType, selectedRow),
    onSave: () => onSaveResource(selectedType, selectedRow),
  });

  return (
    <DomainWorkbench
      ariaLabel="Hub resources"
      sources={hubTypes.map((type) => ({
        label: type,
        count: String(filteredRowsByType[type].length),
      }))}
      selectedSource={selectedType}
      onSelectSource={onSelectType}
      resources={rows}
      selectedResourceKey={resourceKey(selectedRow)}
      onSelectResource={onSelectResource}
      actions={actions}
      agentContext={agentContext}
      editor={
        selectedType === "Rules" ? (
          <RuleEditor key={resourceKey(selectedRow)} row={selectedRow} body={body} />
        ) : (
          <MarkdownEditor key={resourceKey(selectedRow)} row={selectedRow} body={body} />
        )
      }
    />
  );
}

function MemoryView({
  onCreateResource,
  onDeleteResource,
  onSaveResource,
  onSelectType,
  onSelectResource,
  onSubmitResource,
  rowsByType,
  searchQuery,
  selectedResourceKey,
  selectedType,
}: {
  onCreateResource: (type: MemoryType) => void;
  onDeleteResource: (type: MemoryType, row: ResourceRow) => void;
  onSaveResource: (type: MemoryType, row: ResourceRow) => void;
  onSelectType: (type: MemoryType) => void;
  onSelectResource: (resourceKey: string) => void;
  onSubmitResource: (type: MemoryType, row: ResourceRow) => void;
  rowsByType: Record<MemoryType, ResourceRow[]>;
  searchQuery: string;
  selectedResourceKey: string | null;
  selectedType: MemoryType;
}) {
  const filteredRowsByType = filterRowsByGroup(rowsByType, searchQuery);
  const rows = filteredRowsByType[selectedType];
  const selectedRow = selectedResource(rows, selectedResourceKey);
  const body = resourceMarkdown("Project", selectedType, selectedRow);
  const agentContext = resourceAgentContext("Project", selectedType, selectedRow);
  const actions = resourceActions("Project", selectedType, selectedRow, {
    onCreate: () => onCreateResource(selectedType),
    onDelete: () => onDeleteResource(selectedType, selectedRow),
    onSave: () => onSaveResource(selectedType, selectedRow),
    onSubmit: () => onSubmitResource(selectedType, selectedRow),
  });

  return (
    <DomainWorkbench
      ariaLabel="Project memory"
      contextControl={
        <select aria-label="Project" className="source-select" defaultValue="koal">
          <option value="koal">Koal</option>
        </select>
      }
      sources={memoryTypes.map((type) => ({
        label: type,
        count: String(filteredRowsByType[type].length),
      }))}
      selectedSource={selectedType}
      onSelectSource={onSelectType}
      resources={rows}
      selectedResourceKey={resourceKey(selectedRow)}
      onSelectResource={onSelectResource}
      actions={actions}
      agentContext={agentContext}
      editor={
        selectedType === "Rules" ? (
          <RuleEditor key={resourceKey(selectedRow)} row={selectedRow} body={body} />
        ) : (
          <MarkdownEditor key={resourceKey(selectedRow)} row={selectedRow} body={body} />
        )
      }
    />
  );
}

function BundlesView({
  bundleNames,
  bundlesByName,
  onAddResource,
  onCreateBundle,
  onDeleteBundle,
  onSaveBundle,
  onSelectBundle,
  searchQuery,
  selectedBundle,
}: {
  bundleNames: BundleName[];
  bundlesByName: Record<BundleName, BundleRecord>;
  onAddResource: (name: BundleName) => void;
  onCreateBundle: () => void;
  onDeleteBundle: (name: BundleName) => void;
  onSaveBundle: (name: BundleName) => void;
  onSelectBundle: (bundle: BundleName) => void;
  searchQuery: string;
  selectedBundle: BundleName;
}) {
  const bundles = filterBundles(bundlesByName, bundleNames, searchQuery);
  const fallbackBundle = bundleNames[0] ?? "";
  const activeBundle = selectedBundle && bundles[selectedBundle]
    ? selectedBundle
    : fallbackBundle;
  const bundle = bundles[activeBundle] ?? emptyBundleRecord();
  const agentContext = bundleAgentContext(activeBundle, bundle);
  const actions = bundleActions(bundle, {
    onAddResource: () => onAddResource(activeBundle),
    onCreate: onCreateBundle,
    onDelete: () => onDeleteBundle(activeBundle),
    onSave: () => onSaveBundle(activeBundle),
  });

  return (
    <BundleWorkbench
      ariaLabel="Bundles"
      sources={bundleNames.map((name) => ({
        label: name,
        count: String((bundles[name] ?? emptyBundleRecord()).resources.length),
      }))}
      selectedSource={activeBundle}
      onSelectSource={onSelectBundle}
      bundle={bundle}
      selectedBundle={activeBundle}
      agentContext={agentContext}
      actions={actions}
    />
  );
}

function ReviewsView({
  onApproveReview,
  onMergeReview,
  onRejectReview,
  onSelectQueue,
  onSelectReview,
  rowsByQueue,
  searchQuery,
  selectedReviewKey,
  selectedQueue,
}: {
  onApproveReview: (queue: ReviewQueue, row: ResourceRow) => void;
  onMergeReview: (queue: ReviewQueue, row: ResourceRow) => void;
  onRejectReview: (queue: ReviewQueue, row: ResourceRow) => void;
  onSelectQueue: (queue: ReviewQueue) => void;
  onSelectReview: (reviewKey: string) => void;
  rowsByQueue: Record<ReviewQueue, ResourceRow[]>;
  searchQuery: string;
  selectedReviewKey: string | null;
  selectedQueue: ReviewQueue;
}) {
  const filteredRowsByQueue = filterRowsByGroup(rowsByQueue, searchQuery);
  const rows = filteredRowsByQueue[selectedQueue];
  const selectedRow = selectedResource(rows, selectedReviewKey);
  const diffBody = reviewDiff(selectedRow);
  const agentContext = reviewAgentContext(selectedRow);
  const actions = reviewActions(selectedRow.state, {
    onApprove: () => onApproveReview(selectedQueue, selectedRow),
    onMerge: () => onMergeReview(selectedQueue, selectedRow),
    onReject: () => onRejectReview(selectedQueue, selectedRow),
  });

  return (
    <ReviewWorkbench
      ariaLabel="Reviews"
      sources={reviewQueues.map((queue) => ({
        label: queue,
        count: String(filteredRowsByQueue[queue].length),
      }))}
      selectedSource={selectedQueue}
      onSelectSource={onSelectQueue}
      reviews={rows}
      selectedReviewKey={resourceKey(selectedRow)}
      onSelectReview={onSelectReview}
      diffBody={diffBody}
      agentContext={agentContext}
      actions={actions}
    />
  );
}

function DiagnosticsView({
  loadState,
  onCommand,
  onRefresh,
}: {
  loadState: LoadState;
  onCommand: (command: string) => void;
  onRefresh: () => void;
}) {
  return (
    <section className="diagnostics" aria-label="Diagnostics">
      <div className="diagnostics-actions">
        <button
          className="action-button"
          onClick={() => onCommand("install_daemon_launch_agent")}
          type="button"
        >
          Install
        </button>
        <button
          className="action-button"
          onClick={() => onCommand("start_daemon_launch_agent")}
          type="button"
        >
          Start
        </button>
        <button
          className="action-button"
          onClick={() => onCommand("restart_daemon_launch_agent")}
          type="button"
        >
          Restart
        </button>
        <button
          className="action-button"
          onClick={() => onCommand("stop_daemon_launch_agent")}
          type="button"
        >
          Stop
        </button>
        <button className="action-button" onClick={onRefresh} type="button">
          Refresh
        </button>
      </div>
      {loadState.status === "ready" ? (
        <DaemonStatus bootstrap={loadState.bootstrap} health={loadState.health} />
      ) : loadState.status === "failed" ? (
        <p className="error-message">{loadState.message}</p>
      ) : (
        <p className="empty-state">Checking LaunchAgent status.</p>
      )}
    </section>
  );
}

function SettingsView() {
  return (
    <section className="settings-view" aria-label="Settings">
      <SettingsGroup title="Hub">
        <div className="form-row">
          <label htmlFor="hub-url">URL</label>
          <input id="hub-url" readOnly value="http://127.0.0.1:3000" />
        </div>
        <div className="form-row">
          <label htmlFor="project-id">Project</label>
          <input id="project-id" readOnly value="Koal" />
        </div>
      </SettingsGroup>
      <SettingsGroup title="Runtime">
        <div className="preference-row">
          <span>Launch</span>
          <span className="preference-value">LaunchAgent</span>
        </div>
        <div className="preference-row">
          <span>Drafts</span>
          <span className="preference-value">Daemon operation log</span>
        </div>
      </SettingsGroup>
    </section>
  );
}

function DomainWorkbench<T extends string>({
  actions,
  agentContext,
  ariaLabel,
  contextControl,
  editor,
  onSelectSource,
  onSelectResource,
  resources,
  selectedResourceKey,
  selectedSource,
  sources,
}: {
  actions: ObjectAction[];
  agentContext: AgentContext;
  ariaLabel: string;
  contextControl?: ReactNode;
  editor: ReactNode;
  onSelectSource: (source: T) => void;
  onSelectResource: (resourceKey: string) => void;
  resources: ResourceRow[];
  selectedResourceKey: string;
  selectedSource: T;
  sources: SourceEntry<T>[];
}) {
  return (
    <section className="workbench" aria-label={ariaLabel}>
      <SourceList>
        {contextControl}
        {sources.map((source) => (
          <SourceItem
            active={source.label === selectedSource}
            count={source.count}
            key={source.label}
            label={source.label}
            onClick={() => onSelectSource(source.label)}
          />
        ))}
        <FileTree
          onSelectResource={onSelectResource}
          resources={resources}
          selectedResourceKey={selectedResourceKey}
        />
      </SourceList>
      <EditorPane actions={actions}>{editor}</EditorPane>
      <AgentPanel context={agentContext} />
    </section>
  );
}

function BundleWorkbench<T extends string>({
  actions,
  agentContext,
  ariaLabel,
  bundle,
  onSelectSource,
  selectedBundle,
  selectedSource,
  sources,
}: {
  actions: ObjectAction[];
  agentContext: AgentContext;
  ariaLabel: string;
  bundle: BundleRecord;
  onSelectSource: (source: T) => void;
  selectedBundle: string;
  selectedSource: T;
  sources: SourceEntry<T>[];
}) {
  return (
    <section className="workbench" aria-label={ariaLabel}>
      <SourceList>
        {sources.map((source) => (
          <SourceItem
            active={source.label === selectedSource}
            count={source.count}
            key={source.label}
            label={source.label}
            onClick={() => onSelectSource(source.label)}
          />
        ))}
      </SourceList>
      <EditorPane actions={actions}>
        <BundleEditor key={selectedBundle} bundle={bundle} name={selectedBundle} />
      </EditorPane>
      <AgentPanel context={agentContext} />
    </section>
  );
}

function ReviewWorkbench<T extends string>({
  actions,
  agentContext,
  ariaLabel,
  diffBody,
  onSelectReview,
  onSelectSource,
  reviews,
  selectedReviewKey,
  selectedSource,
  sources,
}: {
  actions: ObjectAction[];
  agentContext: AgentContext;
  ariaLabel: string;
  diffBody: string;
  onSelectReview: (reviewKey: string) => void;
  onSelectSource: (source: T) => void;
  reviews: ResourceRow[];
  selectedReviewKey: string;
  selectedSource: T;
  sources: SourceEntry<T>[];
}) {
  return (
    <section className="workbench" aria-label={ariaLabel}>
      <SourceList>
        {sources.map((source) => (
          <SourceItem
            active={source.label === selectedSource}
            count={source.count}
            key={source.label}
            label={source.label}
            onClick={() => onSelectSource(source.label)}
          />
        ))}
        <FileTree
          onSelectResource={onSelectReview}
          resources={reviews}
          selectedResourceKey={selectedReviewKey}
        />
      </SourceList>
      <EditorPane actions={actions}>
        <pre className="diff-viewer">{diffBody}</pre>
      </EditorPane>
      <AgentPanel context={agentContext} />
    </section>
  );
}

function AgentPanel({ context }: { context: AgentContext }) {
  return (
    <aside className="agent-pane" aria-label="Agent">
      <div className="agent-header">
        <span>Agent</span>
        <strong>{context.target}</strong>
        <small>{context.state}</small>
      </div>
      <textarea
        aria-label="Agent instruction"
        className="agent-input"
        defaultValue={context.intent}
      />
      <div className="agent-actions">
        {context.quickActions.map((action) => (
          <button className="action-button" key={action} type="button">
            {action}
          </button>
        ))}
      </div>
      <div className="agent-draft">
        {context.draft.map((item) => (
          <div key={item}>{item}</div>
        ))}
      </div>
      <div className="agent-target">{context.detail}</div>
    </aside>
  );
}

function EditorPane({
  actions,
  children,
}: {
  actions: ObjectAction[];
  children: ReactNode;
}) {
  return (
    <section className="editor-pane">
      <ActionBar actions={actions} />
      {children}
    </section>
  );
}

function ActionBar({ actions }: { actions: ObjectAction[] }) {
  return (
    <div className="object-actions">
      {actions.map((action) => (
        <button
          className={action.tone ? `action-button ${action.tone}` : "action-button"}
          key={action.label}
          onClick={action.onClick}
          type="button"
        >
          {action.label}
        </button>
      ))}
    </div>
  );
}

function SourceList({ children }: { children: ReactNode }) {
  return <aside className="source-list">{children}</aside>;
}

function SearchField({
  onChange,
  value,
}: {
  onChange: (value: string) => void;
  value: string;
}) {
  return (
    <input
      aria-label="Search"
      className="workspace-search"
      onChange={(event) => onChange(event.currentTarget.value)}
      placeholder="Search"
      type="search"
      value={value}
    />
  );
}

function SourceItem({
  active,
  count,
  label,
  onClick,
}: {
  active?: boolean;
  count: string;
  label: string;
  onClick?: () => void;
}) {
  return (
    <button
      className={active ? "source-item active" : "source-item"}
      onClick={onClick}
      type="button"
    >
      <span>{label}</span>
      <span>{count}</span>
    </button>
  );
}

function FileTree({
  onSelectResource,
  resources,
  selectedResourceKey,
}: {
  onSelectResource: (resourceKey: string) => void;
  resources: ResourceRow[];
  selectedResourceKey: string;
}) {
  const nodes = buildFileTree(resources);

  return (
    <div className="file-tree" role="tree">
      {nodes.map((node) => (
        <FileTreeBranch
          depth={0}
          key={node.path}
          node={node}
          onSelectResource={onSelectResource}
          selectedResourceKey={selectedResourceKey}
        />
      ))}
    </div>
  );
}

function FileTreeBranch({
  depth,
  node,
  onSelectResource,
  selectedResourceKey,
}: {
  depth: number;
  node: FileTreeNode;
  onSelectResource: (resourceKey: string) => void;
  selectedResourceKey: string;
}) {
  if (node.resource) {
    const key = resourceKey(node.resource);
    return (
      <button
        className={key === selectedResourceKey ? "file-tree-item active" : "file-tree-item"}
        onClick={() => onSelectResource(key)}
        style={{ paddingLeft: 8 + depth * 14 }}
        type="button"
      >
        <span>{node.name}</span>
        <span>{node.resource.state}</span>
      </button>
    );
  }

  return (
    <div className="file-tree-branch" role="group">
      <div className="file-tree-dir" style={{ paddingLeft: 8 + depth * 14 }}>
        <span>{node.name}</span>
      </div>
      {node.children.map((child) => (
        <FileTreeBranch
          depth={depth + 1}
          key={child.path}
          node={child}
          onSelectResource={onSelectResource}
          selectedResourceKey={selectedResourceKey}
        />
      ))}
    </div>
  );
}

function MarkdownEditor({ body, row }: { body: string; row: ResourceRow }) {
  return (
    <div className="document-editor">
      <input aria-label="Title" className="title-input" defaultValue={row.name} />
      <input aria-label="Path" className="path-input" defaultValue={row.detail} />
      <textarea
        aria-label="Markdown body"
        className="markdown-editor"
        defaultValue={body}
      />
    </div>
  );
}

function RuleEditor({ body, row }: { body: string; row: ResourceRow }) {
  return (
    <div className="document-editor">
      <input aria-label="Rule name" className="title-input" defaultValue={row.name} />
      <div className="field-row">
        <input aria-label="Status" defaultValue={row.state} />
        <input aria-label="Location" defaultValue={row.detail} />
      </div>
      <textarea
        aria-label="Rule body"
        className="markdown-editor"
        defaultValue={body}
      />
    </div>
  );
}

function BundleEditor({
  bundle,
  name,
}: {
  bundle: BundleRecord;
  name: string;
}) {
  return (
    <div className="bundle-editor">
      <input aria-label="Bundle name" className="title-input" defaultValue={name} />
      <div className="bundle-items">
        {bundle.resources.map((resource) => (
          <div className="bundle-item" key={resourceKey(resource)}>
            <span>{resource.name}</span>
            <span>{resource.detail}</span>
            <span>{resource.state}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function Inspector({
  rows,
  title,
}: {
  rows: MetadataRow[];
  title: string;
}) {
  return (
    <aside className="inspector">
      <h2>{title}</h2>
      <dl className="metadata-list">
        {rows.map(([label, value]) => (
          <div key={label}>
            <dt>{label}</dt>
            <dd>{value}</dd>
          </div>
        ))}
      </dl>
    </aside>
  );
}

function SettingsGroup({
  children,
  title,
}: {
  children: ReactNode;
  title: string;
}) {
  return (
    <section className="settings-group">
      <h2>{title}</h2>
      {children}
    </section>
  );
}

function DaemonStatus({
  bootstrap,
  health,
}: {
  bootstrap: DaemonBootstrapStatus;
  health: DaemonHealth | null;
}) {
  const rows: MetadataRow[] = [
    ["LaunchAgent", bootstrap.label],
    ["Mach Service", bootstrap.mach_service_name],
    ["Transport", bootstrap.endpoint.transport],
    ["Plist", bootstrap.plist_path],
    ["Installed", bootstrap.installed ? "Yes" : "No"],
    ["Bootstrapped", bootstrap.runtime.bootstrapped ? "Yes" : "No"],
    ["Running", bootstrap.runtime.running ? "Yes" : "No"],
    ["PID", bootstrap.runtime.pid ? String(bootstrap.runtime.pid) : "None"],
    ["State", bootstrap.runtime.state ?? "Unknown"],
    [
      "Last Exit",
      bootstrap.runtime.last_exit_code === null
        ? "None"
        : String(bootstrap.runtime.last_exit_code),
    ],
    ["Last Error", bootstrap.runtime.last_error ?? "None"],
    ["Version", health?.daemon_version ?? "Unknown"],
    ["Installation", health?.daemon_installation_id ?? "Unknown"],
    ["Hub", health?.hub_url ?? "Unknown"],
    ["Project", health?.project_id ?? "Not selected"],
    ["Local DB", health ? (health.local_db.ready ? "Ready" : "Not ready") : "Unknown"],
    ["Schema", health ? String(health.local_db.schema_version) : "Unknown"],
  ];

  return <Inspector rows={rows} title="Local Daemon" />;
}

function selectedResource(rows: ResourceRow[], selectedKey: string | null): ResourceRow {
  return (
    rows.find((row) => resourceKey(row) === selectedKey) ??
    rows[0] ?? {
      id: "empty",
      detail: "No resource",
      name: "No results",
      state: "Empty",
    }
  );
}

function resourceKey(row: ResourceRow): string {
  return row.id;
}

function resourceAgentContext(
  scope: "Hub" | "Project",
  type: MemoryType,
  row: ResourceRow,
): AgentContext {
  if (row.id === "empty") {
    return {
      detail: `${scope} ${type}`,
      draft: [
        "Pick a source document",
        "Create the memory object",
        "Submit it through the review path",
      ],
      intent: `Create a new ${scope.toLowerCase()} ${type.toLowerCase()} memory from notes.`,
      quickActions: ["Draft from notes", "Find candidates", "Use template"],
      state: "Empty",
      target: `New ${type}`,
    };
  }

  return {
    detail: row.detail,
    draft: [
      "Identify durable facts and constraints",
      "Remove duplicate or task-only details",
      scope === "Hub" ? "Prepare a publishable version" : "Prepare a reviewable draft",
    ],
    intent: `Organize this ${type.toLowerCase()} memory so future agents can retrieve and use it reliably.`,
    quickActions: ["Extract rules", "Find duplicates", "Prepare review"],
    state: row.state,
    target: row.name,
  };
}

function bundleAgentContext(name: BundleName, bundle: BundleRecord): AgentContext {
  return {
    detail: `${bundle.resources.length} resources`,
    draft: [
      "Check whether the bundle matches the task boundary",
      "Suggest missing context or rules",
      "Remove resources that will distract retrieval",
    ],
    intent: `Review the ${name || "selected"} bundle and suggest a tighter memory set for the current task.`,
    quickActions: ["Suggest missing", "Remove noise", "Reorder bundle"],
    state: bundle.metadata.find(([label]) => label === "State")?.[1] ?? "Draft",
    target: name || "Untitled Bundle",
  };
}

function reviewAgentContext(row: ResourceRow): AgentContext {
  if (row.id === "empty") {
    return {
      detail: "No review selected",
      draft: ["Select a review item", "Inspect the diff", "Choose a review action"],
      intent: "Find memory drafts that need review.",
      quickActions: ["Find pending", "Group by type", "Summarize queue"],
      state: "Empty",
      target: "Review queue",
    };
  }

  return {
    detail: row.detail,
    draft: [
      "Summarize what changed",
      "Check whether the change conflicts with existing memory",
      "Recommend approve, reject, or merge",
    ],
    intent: "Evaluate this memory change and prepare a concise review decision.",
    quickActions: ["Summarize diff", "Check conflicts", "Draft decision"],
    state: row.state,
    target: row.name,
  };
}

function resourceActions(
  scope: "Hub" | "Project",
  type: MemoryType,
  row: ResourceRow,
  handlers: {
    onCreate: () => void;
    onDelete: () => void;
    onPublish?: () => void;
    onSave: () => void;
    onSubmit?: () => void;
  },
): ObjectAction[] {
  const createLabel = `New ${type}`;
  if (row.id === "empty") {
    return [{ label: createLabel, onClick: handlers.onCreate, tone: "primary" }];
  }
  if (scope === "Hub") {
    return [
      { label: createLabel, onClick: handlers.onCreate },
      { label: "Save", onClick: handlers.onSave },
      {
        label: "Publish",
        onClick: handlers.onPublish ?? handlers.onSave,
        tone: "primary",
      },
      { label: "Delete", onClick: handlers.onDelete, tone: "danger" },
    ];
  }
  return [
    { label: createLabel, onClick: handlers.onCreate },
    { label: "Save Draft", onClick: handlers.onSave },
    {
      label: "Submit Review",
      onClick: handlers.onSubmit ?? handlers.onSave,
      tone: "primary",
    },
    { label: "Delete", onClick: handlers.onDelete, tone: "danger" },
  ];
}

function bundleActions(
  bundle: BundleRecord,
  handlers: {
    onAddResource: () => void;
    onCreate: () => void;
    onDelete: () => void;
    onSave: () => void;
  },
): ObjectAction[] {
  if (bundle.resources.length === 0) {
    return [
      { label: "New Bundle", onClick: handlers.onCreate },
      { label: "Add Resource", onClick: handlers.onAddResource, tone: "primary" },
    ];
  }
  return [
    { label: "New Bundle", onClick: handlers.onCreate },
    { label: "Save", onClick: handlers.onSave },
    { label: "Add Resource", onClick: handlers.onAddResource, tone: "primary" },
    { label: "Delete", onClick: handlers.onDelete, tone: "danger" },
  ];
}

function reviewActions(
  state: string,
  handlers: {
    onApprove: () => void;
    onMerge: () => void;
    onReject: () => void;
  },
): ObjectAction[] {
  if (state === "Awaiting" || state === "Submitted") {
    return [
      { label: "Approve", onClick: handlers.onApprove, tone: "primary" },
      { label: "Reject", onClick: handlers.onReject, tone: "danger" },
    ];
  }
  if (state === "Approved") {
    return [{ label: "Merge", onClick: handlers.onMerge, tone: "primary" }];
  }
  return [];
}

function createResource(scope: "Hub" | "Project", type: MemoryType): ResourceRow {
  const suffix = Date.now().toString(36);
  const slug = type.toLowerCase();
  return {
    id: `${scope.toLowerCase()}-${slug}-${suffix}`,
    name: `Untitled ${type}`,
    detail: `${resourceFolder(scope, type)}/untitled-${slug}-${suffix}.md`,
    state: scope === "Hub" ? "Draft" : "Local draft",
  };
}

function resourceFolder(scope: "Hub" | "Project", type: MemoryType): string {
  if (type === "Context") {
    return scope === "Hub" ? "context/org" : "context/project";
  }
  if (type === "Rules") {
    return scope === "Hub" ? "rules/org" : "rules/project";
  }
  if (type === "Workflows") {
    return "workflow";
  }
  return "mpf";
}

function appendGroupedResource<T extends string>(
  groups: Record<T, ResourceRow[]>,
  group: T,
  resource: ResourceRow,
): Record<T, ResourceRow[]> {
  return { ...groups, [group]: [resource, ...groups[group]] };
}

function updateGroupedResourceState<T extends string>(
  groups: Record<T, ResourceRow[]>,
  group: T,
  row: ResourceRow,
  state: string,
): Record<T, ResourceRow[]> {
  if (row.id === "empty") {
    return groups;
  }
  return {
    ...groups,
    [group]: groups[group].map((resource) =>
      resourceKey(resource) === resourceKey(row) ? { ...resource, state } : resource,
    ),
  };
}

function removeGroupedResource<T extends string>(
  groups: Record<T, ResourceRow[]>,
  group: T,
  row: ResourceRow,
): Record<T, ResourceRow[]> {
  if (row.id === "empty") {
    return groups;
  }
  return {
    ...groups,
    [group]: groups[group].filter((resource) => resourceKey(resource) !== resourceKey(row)),
  };
}

function appendReview(
  reviews: Record<ReviewQueue, ResourceRow[]>,
  type: MemoryType,
  row: ResourceRow,
): Record<ReviewQueue, ResourceRow[]> {
  if (row.id === "empty") {
    return reviews;
  }
  const review: ResourceRow = {
    id: `review-${resourceKey(row)}`,
    name: row.name,
    detail: type,
    state: "Awaiting",
  };
  const withoutExisting = removeReviewFromAllQueues(reviews, review);
  return appendGroupedResource<ReviewQueue>(withoutExisting, "Awaiting", review);
}

function moveReview(
  reviews: Record<ReviewQueue, ResourceRow[]>,
  from: ReviewQueue,
  to: ReviewQueue,
  row: ResourceRow,
): Record<ReviewQueue, ResourceRow[]> {
  if (row.id === "empty") {
    return reviews;
  }
  const moved = { ...row, state: to };
  const withoutExisting = removeReviewFromAllQueues(
    removeGroupedResource(reviews, from, row),
    moved,
  );
  return appendGroupedResource<ReviewQueue>(withoutExisting, to, moved);
}

function removeReviewFromAllQueues(
  reviews: Record<ReviewQueue, ResourceRow[]>,
  row: ResourceRow,
): Record<ReviewQueue, ResourceRow[]> {
  return Object.fromEntries(
    reviewQueues.map((queue) => [
      queue,
      reviews[queue].filter((review) => resourceKey(review) !== resourceKey(row)),
    ]),
  ) as Record<ReviewQueue, ResourceRow[]>;
}

function createBundleName(bundles: Record<BundleName, BundleRecord>): BundleName {
  let index = Object.keys(bundles).length + 1;
  let name = `Untitled Bundle ${index}`;
  while (bundles[name]) {
    index += 1;
    name = `Untitled Bundle ${index}`;
  }
  return name;
}

function emptyBundleRecord(): BundleRecord {
  return {
    resources: [],
    metadata: [
      ["State", "Draft"],
      ["Owner", "weiwang"],
      ["Contents", "No resources"],
      ["Rules", "0"],
      ["Context", "0"],
      ["Workflows", "0"],
    ],
  };
}

function updateBundleMetadata(
  bundles: Record<BundleName, BundleRecord>,
  name: BundleName,
  label: string,
  value: string,
): Record<BundleName, BundleRecord> {
  const bundle = bundles[name] ?? emptyBundleRecord();
  return {
    ...bundles,
    [name]: {
      ...bundle,
      metadata: bundle.metadata.map((row) => (row[0] === label ? [label, value] : row)),
    },
  };
}

function appendBundleResource(
  bundles: Record<BundleName, BundleRecord>,
  name: BundleName,
): Record<BundleName, BundleRecord> {
  const bundle = bundles[name] ?? emptyBundleRecord();
  const resource = createBundleResource(bundle.resources.length + 1);
  const nextBundle = {
    ...bundle,
    resources: [...bundle.resources, resource],
  };
  return {
    ...bundles,
    [name]: refreshBundleMetadata(nextBundle),
  };
}

function createBundleResource(index: number): ResourceRow {
  return {
    id: `bundle-resource-${Date.now().toString(36)}-${index}`,
    name: `Included resource ${index}`,
    detail: "Project context",
    state: "Included",
  };
}

function refreshBundleMetadata(bundle: BundleRecord): BundleRecord {
  const resourceCount = bundle.resources.length;
  return {
    ...bundle,
    metadata: bundle.metadata.map(([label, value]) => {
      if (label === "Contents") {
        return [label, `${resourceCount} resources`];
      }
      if (label === "Context") {
        return [label, String(resourceCount)];
      }
      return [label, value];
    }),
  };
}

function buildFileTree(resources: ResourceRow[]): FileTreeNode[] {
  const root: FileTreeNode = { children: [], name: "", path: "" };

  for (const resource of resources) {
    const parts = filePath(resource).split("/").filter(Boolean);
    let current = root;

    for (const [index, part] of parts.entries()) {
      const path = current.path ? `${current.path}/${part}` : part;
      let child = current.children.find((node) => node.name === part);
      if (!child) {
        child = { children: [], name: part, path };
        current.children.push(child);
      }
      if (index === parts.length - 1) {
        child.resource = resource;
      }
      current = child;
    }
  }

  return sortFileTree(root.children);
}

function filePath(resource: ResourceRow): string {
  if (resource.detail.includes("/")) {
    return resource.detail;
  }
  return `${resource.detail}/${resource.name}`;
}

function sortFileTree(nodes: FileTreeNode[]): FileTreeNode[] {
  return nodes
    .map((node) => ({ ...node, children: sortFileTree(node.children) }))
    .sort((left, right) => {
      if (left.resource && !right.resource) {
        return 1;
      }
      if (!left.resource && right.resource) {
        return -1;
      }
      return left.name.localeCompare(right.name);
    });
}

function filterRowsByGroup<T extends string>(
  groups: Record<T, ResourceRow[]>,
  query: string,
): Record<T, ResourceRow[]> {
  return Object.fromEntries(
    Object.entries(groups).map(([group, rows]) => [
      group,
      filterRows(rows as ResourceRow[], query),
    ]),
  ) as Record<T, ResourceRow[]>;
}

function filterRows(rows: ResourceRow[], query: string): ResourceRow[] {
  const normalizedQuery = normalizeSearch(query);
  if (!normalizedQuery) {
    return rows;
  }
  return rows.filter((row) =>
    normalizeSearch(`${row.name} ${row.detail} ${row.state}`).includes(
      normalizedQuery,
    ),
  );
}

function filterBundles(
  bundlesByName: Record<BundleName, BundleRecord>,
  bundleNames: BundleName[],
  query: string,
): Record<BundleName, BundleRecord> {
  const normalizedQuery = normalizeSearch(query);
  return Object.fromEntries(
    bundleNames.map((name) => {
      const bundle = bundlesByName[name] ?? emptyBundleRecord();
      const bundleText = normalizeSearch(
        `${name} ${bundle.metadata.map(([label, value]) => `${label} ${value}`).join(" ")}`,
      );
      const resources = bundleText.includes(normalizedQuery)
        ? bundle.resources
        : filterRows(bundle.resources, query);
      return [name, { ...bundle, resources }];
    }),
  ) as Record<BundleName, BundleRecord>;
}

function normalizeSearch(value: string): string {
  return value.trim().toLowerCase();
}

function resourceMarkdown(
  scope: "Hub" | "Project",
  type: HubType,
  row: ResourceRow,
): string {
  if (type === "Rules") {
    return `# ${row.name}

## Applies When

- Scope: ${scope}
- Status: ${row.state}
- Source: ${row.detail}

## Rule

Keep this constraint precise enough that an agent can apply it without reading unrelated history.

## Rationale

The rule is stored as a stable object, while this body remains Markdown so humans can review and revise the reasoning behind it.`;
  }

  if (type === "Workflows") {
    return `# ${row.name}

## Entry

Use this workflow when the current task matches the resource description.

## Steps

- Activate the relevant memory scope.
- Retrieve only the resources needed for the task.
- Apply the loaded constraints before editing.
- Store any durable correction as a draft operation.

## Exit

The workflow is complete when the task result and memory updates are both coherent.`;
  }

  if (type === "Metaprompt") {
    return `# ${row.name}

## Role

The metaprompt defines the startup boundary for agents that consume this memory space.

## Constraints

- Treat context as task-conditioned memory, not a general knowledge dump.
- Prefer activated rules over unstated assumptions.
- Write durable updates through the draft path.`;
  }

  return `# ${row.name}

## Context

${row.detail}

This context should be edited as a Markdown document, versioned through personal drafts, reviewed when promoted, and merged only by the Hub authority flow.

## Current State

${row.state}`;
}

function reviewDiff(row: ResourceRow): string {
  return `--- authority/${row.detail.toLowerCase()}
+++ draft/${row.detail.toLowerCase()}
@@
- Previous memory text kept the object as a list-only record.
+ Updated memory text carries the actual content body.
+
+ The review should show what changes in the memory document,
+ not only the metadata row that points to it.

State: ${row.state}
Target: ${row.name}`;
}

function daemonStatus(state: LoadState): { dotClass: string; label: string } {
  if (state.status === "ready") {
    if (state.bootstrap.runtime.running) {
      return { dotClass: "status-dot ready", label: "Running" };
    }
    if (state.bootstrap.runtime.bootstrapped) {
      return { dotClass: "status-dot waiting", label: "Loaded" };
    }
    return {
      dotClass: state.bootstrap.installed ? "status-dot waiting" : "status-dot",
      label: state.bootstrap.installed ? "Installed" : "Missing",
    };
  }
  if (state.status === "failed") {
    return { dotClass: "status-dot failed", label: "Offline" };
  }
  if (state.status === "loading") {
    return { dotClass: "status-dot waiting", label: "Checking" };
  }
  return { dotClass: "status-dot", label: "Idle" };
}
