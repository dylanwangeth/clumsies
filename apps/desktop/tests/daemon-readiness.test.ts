import { describe, expect, test } from "bun:test";
import type {
  DaemonApiClient,
  DaemonBootstrapStatus,
} from "@clumsies/api-client";
import { ensureDaemonReady } from "../src/daemon-readiness";

function bootstrapStatus(
  runtime: Partial<DaemonBootstrapStatus["runtime"]>,
): DaemonBootstrapStatus {
  return {
    label: "io.github.lilhammerfun.clumsies.agent",
    mach_service_name: "io.github.lilhammerfun.clumsies.agent",
    plist_path: "/tmp/clumsies.plist",
    installed: true,
    endpoint: {
      transport: "macos_xpc_mach_service",
      service_name: "io.github.lilhammerfun.clumsies.agent",
    },
    runtime: {
      installed: true,
      bootstrapped: true,
      running: false,
      pid: null,
      state: null,
      last_exit_code: null,
      last_error: null,
      ...runtime,
    },
  };
}

describe("daemon readiness", () => {
  test("requires a stable running process before Desktop uses XPC", async () => {
    const statuses = [
      bootstrapStatus({ state: "spawn scheduled" }),
      bootstrapStatus({ running: true, pid: 42, state: "running" }),
      bootstrapStatus({ running: true, pid: 42, state: "running" }),
    ];
    let reads = 0;
    const daemon = {
      start: async () => statuses[0],
      bootstrapStatus: async () => statuses[++reads],
    } as DaemonApiClient;

    const ready = await ensureDaemonReady(daemon, {
      attempts: 3,
      intervalMs: 0,
      stableRunningSamples: 2,
    });

    expect(ready.runtime.pid).toBe(42);
    expect(reads).toBe(2);
  });

  test("reports a crash loop without issuing an XPC request", async () => {
    const failed = bootstrapStatus({
      state: "spawn scheduled",
      last_exit_code: 1,
    });
    const daemon = {
      start: async () => failed,
      bootstrapStatus: async () => failed,
    } as DaemonApiClient;

    await expect(
      ensureDaemonReady(daemon, {
        attempts: 2,
        intervalMs: 0,
        stableRunningSamples: 2,
      }),
    ).rejects.toThrow("state spawn scheduled, exit code 1");
  });
});
