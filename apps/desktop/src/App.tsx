import { useCallback, useEffect, useState } from "react";
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
  | { status: "ready"; bootstrap: DaemonBootstrapStatus; health: DaemonHealth | null }
  | { status: "failed"; message: string };

const navItems = [
  "Enterprise Memory",
  "Project Memory",
  "Drafts",
  "Reviews",
  "macOS Daemon",
  "Settings",
];

export function App() {
  const [selected, setSelected] = useState("macOS Daemon");
  const [loadState, setLoadState] = useState<LoadState>({ status: "idle" });

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

  return (
    <main className="shell">
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark">c</span>
          <span>clumsies</span>
        </div>
        <nav className="nav" aria-label="Primary">
          {navItems.map((item) => (
            <button
              className={item === selected ? "nav-item active" : "nav-item"}
              key={item}
              onClick={() => setSelected(item)}
              type="button"
            >
              {item}
            </button>
          ))}
        </nav>
      </aside>

      <section className="workspace">
        <header className="topbar">
          <div>
            <h1>{selected}</h1>
            <p>Desktop workspace backed by the macOS LaunchAgent daemon.</p>
          </div>
          <div className="topbar-actions">
            <button
              className="secondary"
              onClick={() => runLaunchAgentCommand("install_daemon_launch_agent")}
              type="button"
            >
              Install Agent
            </button>
            <button
              className="secondary"
              onClick={() => runLaunchAgentCommand("start_daemon_launch_agent")}
              type="button"
            >
              Start
            </button>
            <button
              className="secondary"
              onClick={() => runLaunchAgentCommand("restart_daemon_launch_agent")}
              type="button"
            >
              Restart
            </button>
            <button
              className="secondary"
              onClick={() => runLaunchAgentCommand("stop_daemon_launch_agent")}
              type="button"
            >
              Stop
            </button>
            <button className="secondary" onClick={readHealth} type="button">
              Health
            </button>
            <button className="primary" onClick={refreshBootstrap} type="button">
              Refresh
            </button>
          </div>
        </header>

        <section className="panel" aria-label="macOS daemon status">
          <div className="panel-header">
            <h2>macOS Daemon</h2>
            <span className={statusClass(loadState)}>
              {statusLabel(loadState)}
            </span>
          </div>
          {loadState.status === "ready" ? (
            <DaemonStatus bootstrap={loadState.bootstrap} health={loadState.health} />
          ) : loadState.status === "failed" ? (
            <p className="error">{loadState.message}</p>
          ) : (
            <p className="muted">Checking LaunchAgent status...</p>
          )}
        </section>
      </section>
    </main>
  );
}

function DaemonStatus({
  bootstrap,
  health,
}: {
  bootstrap: DaemonBootstrapStatus;
  health: DaemonHealth | null;
}) {
  const rows = [
    ["LaunchAgent", bootstrap.label],
    ["Mach Service", bootstrap.mach_service_name],
    ["Transport", bootstrap.endpoint.transport],
    ["Endpoint", bootstrap.endpoint.service_name],
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

  return (
    <dl className="status-grid">
      {rows.map(([label, value]) => (
        <div className="status-row" key={label}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  );
}

function statusLabel(state: LoadState): string {
  if (state.status === "ready") {
    if (state.bootstrap.runtime.running) return "Running";
    if (state.bootstrap.runtime.bootstrapped) return "Loaded";
    return state.bootstrap.installed ? "Installed" : "Missing";
  }
  if (state.status === "failed") return "Offline";
  if (state.status === "loading") return "Checking";
  return "Idle";
}

function statusClass(state: LoadState): string {
  return `status-pill ${state.status}`;
}
