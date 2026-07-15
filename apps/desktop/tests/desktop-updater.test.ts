import { describe, expect, test } from "bun:test";
import type { DownloadEvent } from "@tauri-apps/plugin-updater";
import {
  DesktopUpdater,
  type DesktopUpdateProgress,
} from "../src/desktop-updater";

function updateStub(events: DownloadEvent[]) {
  let closed = false;
  return {
    currentVersion: "0.1.0",
    version: "0.2.0",
    date: "2026-07-15T00:00:00Z",
    body: "A release",
    close: async () => {
      closed = true;
    },
    downloadAndInstall: async (onEvent?: (event: DownloadEvent) => void) => {
      for (const event of events) {
        onEvent?.(event);
      }
    },
    wasClosed: () => closed,
  };
}

describe("Desktop updater", () => {
  test("reports the installed version without checking the network", async () => {
    const updater = new DesktopUpdater({
      currentVersion: async () => "0.1.0",
      check: async () => null,
      relaunch: async () => {},
    });

    expect(await updater.currentVersion()).toBe("0.1.0");
  });

  test("reports when the configured endpoint has no newer release", async () => {
    const updater = new DesktopUpdater({
      currentVersion: async () => "0.1.0",
      check: async () => null,
      relaunch: async () => {},
    });

    expect(await updater.check()).toBeNull();
  });

  test("retains update metadata and replaces an older pending handle", async () => {
    const first = updateStub([]);
    const second = updateStub([]);
    let checkCount = 0;
    const updater = new DesktopUpdater({
      currentVersion: async () => "0.1.0",
      check: async () => (checkCount++ === 0 ? first : second),
      relaunch: async () => {},
    });

    expect(await updater.check()).toEqual({
      currentVersion: "0.1.0",
      version: "0.2.0",
      date: "2026-07-15T00:00:00Z",
      notes: "A release",
    });
    await updater.check();

    expect(first.wasClosed()).toBeTrue();
    expect(second.wasClosed()).toBeFalse();
  });

  test("does not retain a closed update when its replacement check fails", async () => {
    const first = updateStub([]);
    let checkCount = 0;
    const updater = new DesktopUpdater({
      currentVersion: async () => "0.1.0",
      check: async () => {
        if (checkCount++ === 0) {
          return first;
        }
        throw new Error("endpoint unavailable");
      },
      relaunch: async () => {},
    });

    await updater.check();
    await expect(updater.check()).rejects.toThrow("endpoint unavailable");

    expect(first.wasClosed()).toBeTrue();
    await expect(updater.install(() => {})).rejects.toThrow(
      "Check for an update before installing it",
    );
  });

  test("installs the pending update, reports progress, and relaunches", async () => {
    const update = updateStub([
      { event: "Started", data: { contentLength: 12 } },
      { event: "Progress", data: { chunkLength: 5 } },
      { event: "Progress", data: { chunkLength: 7 } },
      { event: "Finished" },
    ]);
    let relaunched = false;
    const updater = new DesktopUpdater({
      currentVersion: async () => "0.1.0",
      check: async () => update,
      relaunch: async () => {
        relaunched = true;
      },
    });
    const progress: DesktopUpdateProgress[] = [];

    await updater.check();
    await updater.install((event) => progress.push(event));

    expect(progress).toContainEqual({
      phase: "downloading",
      downloadedBytes: 12,
      totalBytes: 12,
    });
    expect(progress.at(-1)).toEqual({
      phase: "installing",
      downloadedBytes: 12,
      totalBytes: 12,
    });
    expect(relaunched).toBeTrue();
  });

  test("does not install without a successful update check", async () => {
    const updater = new DesktopUpdater({
      currentVersion: async () => "0.1.0",
      check: async () => null,
      relaunch: async () => {},
    });

    await expect(updater.install(() => {})).rejects.toThrow(
      "Check for an update before installing it",
    );
  });
});
