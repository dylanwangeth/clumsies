import { describe, expect, test } from "bun:test";
import {
  closeWorkspaceTab,
  memoryTabKey,
  openWorkspaceTab,
  pinWorkspaceTab,
  retargetMemoryTabs,
  type WorkspaceTab,
} from "../src/workspace-tabs";

const localTab = (
  targetId: string,
  pinned = false,
): WorkspaceTab => ({
  key: memoryTabKey("Local", targetId, "source"),
  view: "Local",
  targetId,
  kind: "Context",
  projectId: "koal",
  surface: "source",
  pinned,
});

describe("workspace tabs", () => {
  test("a new preview replaces the existing preview without disturbing pinned tabs", () => {
    const pinned = localTab("pinned", true);
    const firstPreview = localTab("first");
    const secondPreview = localTab("second");

    const tabs = openWorkspaceTab(
      openWorkspaceTab([pinned], firstPreview),
      secondPreview,
    );

    expect(tabs).toEqual([pinned, secondPreview]);
  });

  test("pinning a preview preserves it when another preview opens", () => {
    const first = localTab("first");
    const pinned = pinWorkspaceTab(openWorkspaceTab([], first), first.key);
    const second = localTab("second");

    expect(openWorkspaceTab(pinned, second)).toEqual([
      { ...first, pinned: true },
      second,
    ]);
  });

  test("reopening an existing tab activates the same identity and can pin it", () => {
    const preview = localTab("same");
    const tabs = openWorkspaceTab([preview], preview, true);

    expect(tabs).toEqual([{ ...preview, pinned: true }]);
  });

  test("source and markdown preview have independent tab identities", () => {
    const source = localTab("same", true);
    const markdownPreview: WorkspaceTab = {
      ...source,
      key: memoryTabKey("Local", "same", "markdown-preview"),
      surface: "markdown-preview",
    };

    expect(openWorkspaceTab([source], markdownPreview, true)).toEqual([
      source,
      markdownPreview,
    ]);
  });

  test("reopening a markdown preview does not duplicate it", () => {
    const source = localTab("same", true);
    const markdownPreview: WorkspaceTab = {
      ...source,
      key: memoryTabKey("Local", "same", "markdown-preview"),
      surface: "markdown-preview",
    };

    expect(
      openWorkspaceTab(
        openWorkspaceTab([source], markdownPreview, true),
        markdownPreview,
        true,
      ),
    ).toEqual([source, markdownPreview]);
  });

  test("publishing a draft retargets its source and preview tabs together", () => {
    const source = localTab("draft", true);
    const markdownPreview: WorkspaceTab = {
      ...source,
      key: memoryTabKey("Local", "draft", "markdown-preview"),
      surface: "markdown-preview",
    };

    expect(
      retargetMemoryTabs(
        [source, markdownPreview, localTab("unrelated", true)],
        "Local",
        "draft",
        "resource",
      ),
    ).toEqual([
      {
        ...source,
        key: memoryTabKey("Local", "resource", "source"),
        targetId: "resource",
      },
      {
        ...markdownPreview,
        key: memoryTabKey("Local", "resource", "markdown-preview"),
        targetId: "resource",
      },
      localTab("unrelated", true),
    ]);
  });

  test("closing the active tab selects the adjacent tab", () => {
    const first = localTab("first", true);
    const second = localTab("second", true);
    const third = localTab("third", true);

    expect(closeWorkspaceTab([first, second, third], second.key, second.key)).toEqual({
      tabs: [first, third],
      activeKey: third.key,
    });
    expect(closeWorkspaceTab([first], first.key, first.key)).toEqual({
      tabs: [],
      activeKey: null,
    });
  });
});
