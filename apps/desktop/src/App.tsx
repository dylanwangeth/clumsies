import { useCallback, useEffect, useMemo, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { createDaemonApiClient } from "@clumsies/api-client";

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
  | { status: "ready"; health: DaemonHealth }
  | { status: "failed"; message: string };

const navItems = [
  "Enterprise Memory",
  "Project Memory",
  "Drafts",
  "Reviews",
  "Daemon",
  "Settings",
];

const daemonUrl = "http://127.0.0.1:37123";

export function App() {
  const [selected, setSelected] = useState("Daemon");
  const [loadState, setLoadState] = useState<LoadState>({ status: "idle" });

  const daemonClient = useMemo(
    () => createDaemonApiClient({ baseUrl: daemonUrl }),
    [],
  );

  const refreshHealth = useCallback(async () => {
    setLoadState({ status: "loading" });
    try {
      const health = await invoke<DaemonHealth>("read_daemon_health", {
        daemonUrl,
      });
      setLoadState({ status: "ready", health });
    } catch (error) {
      const { data, error: responseError } = await daemonClient.GET(
        "/daemon/health",
      );
      if (data) {
        setLoadState({ status: "ready", health: data });
        return;
      }
      setLoadState({
        status: "failed",
        message:
          responseError?.error.message ??
          (error instanceof Error ? error.message : String(error)),
      });
    }
  }, [daemonClient]);

  useEffect(() => {
    void refreshHealth();
  }, [refreshHealth]);

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
            <p>Desktop workspace backed by the local clumsies daemon.</p>
          </div>
          <button className="primary" onClick={refreshHealth} type="button">
            Refresh
          </button>
        </header>

        <section className="panel" aria-label="Daemon status">
          <div className="panel-header">
            <h2>Local Daemon</h2>
            <span className={statusClass(loadState)}>
              {statusLabel(loadState)}
            </span>
          </div>
          {loadState.status === "ready" ? (
            <DaemonStatus health={loadState.health} />
          ) : loadState.status === "failed" ? (
            <p className="error">{loadState.message}</p>
          ) : (
            <p className="muted">Checking daemon health...</p>
          )}
        </section>
      </section>
    </main>
  );
}

function DaemonStatus({ health }: { health: DaemonHealth }) {
  const rows = [
    ["Version", health.daemon_version],
    ["Hub", health.hub_url],
    ["Project", health.project_id ?? "Not selected"],
    ["Installation", health.daemon_installation_id],
    ["Logs", health.log_dir],
    ["Local DB", health.local_db.ready ? "Ready" : "Not ready"],
    ["Schema", String(health.local_db.schema_version)],
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
  if (state.status === "ready") return "Ready";
  if (state.status === "failed") return "Offline";
  if (state.status === "loading") return "Checking";
  return "Idle";
}

function statusClass(state: LoadState): string {
  return `status-pill ${state.status}`;
}
