import { getVersion } from "@tauri-apps/api/app";
import { relaunch } from "@tauri-apps/plugin-process";
import {
  check,
  type DownloadEvent,
  type Update,
} from "@tauri-apps/plugin-updater";

export type DesktopUpdateMetadata = {
  currentVersion: string;
  version: string;
  date: string | null;
  notes: string | null;
};

export type DesktopUpdateProgress = {
  phase: "downloading" | "installing";
  downloadedBytes: number;
  totalBytes: number | null;
};

type UpdateHandle = Pick<
  Update,
  "body" | "close" | "currentVersion" | "date" | "downloadAndInstall" | "version"
>;

export type DesktopUpdaterBindings = {
  currentVersion: () => Promise<string>;
  check: () => Promise<UpdateHandle | null>;
  relaunch: () => Promise<void>;
};

export class DesktopUpdater {
  private pendingUpdate: UpdateHandle | null = null;

  constructor(private readonly bindings: DesktopUpdaterBindings) {}

  currentVersion(): Promise<string> {
    return this.bindings.currentVersion();
  }

  async check(): Promise<DesktopUpdateMetadata | null> {
    const previousUpdate = this.pendingUpdate;
    this.pendingUpdate = null;
    if (previousUpdate) {
      await previousUpdate.close();
    }
    this.pendingUpdate = await this.bindings.check();
    if (!this.pendingUpdate) {
      return null;
    }
    return {
      currentVersion: this.pendingUpdate.currentVersion,
      version: this.pendingUpdate.version,
      date: this.pendingUpdate.date ?? null,
      notes: this.pendingUpdate.body ?? null,
    };
  }

  async install(
    onProgress: (progress: DesktopUpdateProgress) => void,
  ): Promise<void> {
    if (!this.pendingUpdate) {
      throw new Error("Check for an update before installing it");
    }

    let downloadedBytes = 0;
    let totalBytes: number | null = null;
    await this.pendingUpdate.downloadAndInstall((event) => {
      if (event.event === "Started") {
        totalBytes = event.data.contentLength ?? null;
      } else if (event.event === "Progress") {
        downloadedBytes += event.data.chunkLength;
      }
      onProgress(progressForEvent(event, downloadedBytes, totalBytes));
    });
    onProgress({ phase: "installing", downloadedBytes, totalBytes });
    this.pendingUpdate = null;
    await this.bindings.relaunch();
  }
}

export function createNativeDesktopUpdater(): DesktopUpdater {
  return new DesktopUpdater({
    currentVersion: getVersion,
    check: () => check({ timeout: 30_000 }),
    relaunch,
  });
}

function progressForEvent(
  event: DownloadEvent,
  downloadedBytes: number,
  totalBytes: number | null,
): DesktopUpdateProgress {
  return {
    phase: event.event === "Finished" ? "installing" : "downloading",
    downloadedBytes,
    totalBytes,
  };
}
