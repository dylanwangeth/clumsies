import type {
  DaemonApiClient,
  DaemonBootstrapStatus,
} from "@clumsies/api-client";

type DaemonReadinessPolicy = {
  attempts: number;
  intervalMs: number;
  stableRunningSamples: number;
};

const defaultPolicy: DaemonReadinessPolicy = {
  attempts: 20,
  intervalMs: 100,
  stableRunningSamples: 2,
};

export async function ensureDaemonReady(
  daemon: DaemonApiClient,
  policy: DaemonReadinessPolicy = defaultPolicy,
): Promise<DaemonBootstrapStatus> {
  let status = await daemon.start();
  let runningSamples = 0;

  for (let attempt = 0; attempt < policy.attempts; attempt += 1) {
    runningSamples = status.runtime.running ? runningSamples + 1 : 0;
    if (runningSamples >= policy.stableRunningSamples) {
      return status;
    }
    if (attempt + 1 < policy.attempts) {
      await new Promise((resolve) => setTimeout(resolve, policy.intervalMs));
      status = await daemon.bootstrapStatus();
    }
  }

  const details = [
    status.runtime.state ? `state ${status.runtime.state}` : null,
    status.runtime.last_exit_code === null
      ? null
      : `exit code ${status.runtime.last_exit_code}`,
    status.runtime.last_error,
  ].filter((detail): detail is string => Boolean(detail));
  throw new Error(
    details.length > 0
      ? `daemon did not become ready (${details.join(", ")})`
      : "daemon did not become ready",
  );
}
