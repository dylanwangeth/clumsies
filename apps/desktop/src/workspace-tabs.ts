import type { MemoryKind } from "./model";

export type MemoryTabSurface = "source" | "markdown-preview";

export type WorkspaceTab =
  | {
      key: string;
      view: "Hub" | "Local";
      targetId: string;
      kind: MemoryKind;
      projectId: string | null;
      surface: MemoryTabSurface;
      pinned: boolean;
    }
  | {
      key: string;
      view: "Bundles" | "Reviews";
      targetId: string;
      pinned: boolean;
    };

export function openWorkspaceTab(
  tabs: WorkspaceTab[],
  tab: WorkspaceTab,
  pin = tab.pinned,
): WorkspaceTab[] {
  const existingIndex = tabs.findIndex((entry) => entry.key === tab.key);
  const nextTab = { ...tab, pinned: tab.pinned || pin } as WorkspaceTab;

  if (existingIndex >= 0) {
    return tabs.map((entry, index) =>
      index === existingIndex
        ? ({ ...entry, ...nextTab, pinned: entry.pinned || nextTab.pinned } as WorkspaceTab)
        : entry,
    );
  }

  if (!nextTab.pinned) {
    const previewIndex = tabs.findIndex((entry) => !entry.pinned);
    if (previewIndex >= 0) {
      return tabs.map((entry, index) => (index === previewIndex ? nextTab : entry));
    }
  }

  return [...tabs, nextTab];
}

export function pinWorkspaceTab(tabs: WorkspaceTab[], key: string): WorkspaceTab[] {
  return tabs.map((tab) => (tab.key === key ? { ...tab, pinned: true } : tab));
}

export function retargetMemoryTabs(
  tabs: WorkspaceTab[],
  view: "Hub" | "Local",
  currentTargetId: string,
  nextTargetId: string,
): WorkspaceTab[] {
  return tabs.map((tab) =>
    tab.view === view && tab.targetId === currentTargetId
      ? {
          ...tab,
          key: memoryTabKey(view, nextTargetId, tab.surface),
          targetId: nextTargetId,
          pinned: true,
        }
      : tab,
  );
}

export function closeWorkspaceTab(
  tabs: WorkspaceTab[],
  key: string,
  activeKey: string | null,
): { tabs: WorkspaceTab[]; activeKey: string | null } {
  const closingIndex = tabs.findIndex((tab) => tab.key === key);
  if (closingIndex < 0) {
    return { tabs, activeKey };
  }

  const remaining = tabs.filter((tab) => tab.key !== key);
  if (activeKey !== key) {
    return { tabs: remaining, activeKey };
  }

  const next = remaining[closingIndex] ?? remaining[closingIndex - 1] ?? null;
  return { tabs: remaining, activeKey: next?.key ?? null };
}

export function memoryTabKey(
  view: "Hub" | "Local",
  targetId: string,
  surface: MemoryTabSurface,
): string {
  return `${view.toLowerCase()}:${targetId}:${surface}`;
}
