import { describe, expect, test } from "bun:test";
import {
  applyDraft,
  createBlankDraft,
  createDraftFromResource,
  globalSearch,
  initialBundles,
  initialDrafts,
  initialResources,
  initialReviews,
  listResources,
  resourceWorkingState,
  reviewDiff,
} from "../src/model";

describe("memory draft lifecycle", () => {
  test("editing overlays a resource without mutating authoritative memory", () => {
    const resource = initialResources.find(
      (entry) => entry.id === "project-context-daemon",
    );
    expect(resource).toBeDefined();

    const draft = createDraftFromResource(resource!);
    draft.document.body = "Updated in a personal draft.";
    const items = listResources(
      initialResources,
      [draft],
      "Project",
      "koal",
      "Context",
    );
    const visible = items.find((entry) => entry.resource?.id === resource!.id);

    expect(visible?.document.body).toBe("Updated in a personal draft.");
    expect(resource!.document.body).not.toBe("Updated in a personal draft.");
    expect(resource!.version).toBe(9);
  });

  test("merging an update creates the next authoritative version", () => {
    const resource = initialResources.find(
      (entry) => entry.id === "hub-context-external-memory",
    );
    const draft = createDraftFromResource(resource!);
    draft.document.title = "External memory lifecycle";

    const merged = applyDraft(initialResources, draft);
    const updated = merged.find((entry) => entry.id === resource!.id);

    expect(updated?.document.title).toBe("External memory lifecycle");
    expect(updated?.version).toBe(resource!.version + 1);
    expect(resource!.document.title).toBe("External memory model");
  });

  test("merging a new draft publishes a new resource", () => {
    const draft = createBlankDraft("Project", "Rules", "koal", "Koal");
    draft.document.title = "New project constraint";

    const merged = applyDraft(initialResources, draft);
    const published = merged.find(
      (entry) => entry.document.title === "New project constraint",
    );

    expect(published).toMatchObject({
      scope: "Project",
      projectId: "koal",
      kind: "Rules",
      version: 1,
    });
  });

  test("a deletion proposal removes authority only when merged", () => {
    const resource = initialResources[0];
    const draft = createDraftFromResource(resource);
    draft.operation = "delete";

    expect(initialResources.some((entry) => entry.id === resource.id)).toBe(true);
    expect(applyDraft(initialResources, draft)).not.toContainEqual(resource);
  });

  test("working state exposes only states that change the active item", () => {
    const resource = initialResources.find(
      (entry) => entry.id === "project-context-daemon",
    )!;
    const clean = listResources(
      [resource],
      [],
      "Project",
      "koal",
      "Context",
    )[0];
    const draft = createDraftFromResource(resource);
    const draftItem = listResources(
      [resource],
      [draft],
      "Project",
      "koal",
      "Context",
    )[0];

    expect(resourceWorkingState(clean)).toBe("clean");
    expect(resourceWorkingState(draftItem)).toBe("draft");

    draft.status = "in_review";
    expect(resourceWorkingState({ ...draftItem, draft })).toBe("review");

    draft.syncState = "conflict";
    expect(resourceWorkingState({ ...draftItem, draft })).toBe("conflict");

    const deletionDraft = createDraftFromResource(resource);
    deletionDraft.operation = "delete";
    expect(resourceWorkingState({ ...draftItem, draft: deletionDraft })).toBe(
      "deletion",
    );

    const newDraft = createBlankDraft("Project", "Context", "koal", "Koal");
    const newItem = listResources(
      [],
      [newDraft],
      "Project",
      "koal",
      "Context",
    )[0];
    expect(resourceWorkingState(newItem)).toBe("new");
  });
});

describe("cross-domain discovery and review", () => {
  test("global search spans memory, drafts, bundles, and reviews", () => {
    const memory = globalSearch(
      "daemon",
      initialResources,
      initialDrafts,
      initialBundles,
      initialReviews,
    );
    const draft = globalSearch(
      "admission",
      initialResources,
      initialDrafts,
      initialBundles,
      initialReviews,
    );
    const bundle = globalSearch(
      "daily coding",
      initialResources,
      initialDrafts,
      initialBundles,
      initialReviews,
    );
    const review = globalSearch(
      "weiwang",
      initialResources,
      initialDrafts,
      initialBundles,
      initialReviews,
    );

    expect(memory.some((entry) => entry.type === "memory")).toBe(true);
    expect(draft.some((entry) => entry.type === "draft")).toBe(true);
    expect(bundle.some((entry) => entry.type === "bundle")).toBe(true);
    expect(review.some((entry) => entry.type === "review")).toBe(true);
  });

  test("review diff distinguishes additions and removals", () => {
    const resource = initialResources.find(
      (entry) => entry.id === "hub-rule-compatibility",
    );
    const draft = createDraftFromResource(resource!);
    draft.document.body = "Use the new contract directly.";

    const diff = reviewDiff(resource!, draft);

    expect(diff.some((line) => line.startsWith("- "))).toBe(true);
    expect(diff.some((line) => line === "+ Use the new contract directly.")).toBe(
      true,
    );
  });

  test("review diff uses the submitted snapshot without a local draft", () => {
    const change = {
      ...initialReviews[0]!.change,
      beforeText: "# Before\n\nShared context.",
      afterText: "# After\n\nShared context.",
    };

    expect(reviewDiff(null, change)).toEqual([
      "- # Before",
      "+ # After",
      "  ",
      "  Shared context.",
    ]);
  });

  test("deletion reviews show the submitted base content", () => {
    const change = {
      ...initialReviews[0]!.change,
      operation: "delete" as const,
      beforeText: "# Removed\n\nNo longer authoritative.",
      afterText: null,
    };

    expect(reviewDiff(null, change)).toEqual([
      "- # Removed",
      "- ",
      "- No longer authoritative.",
    ]);
  });
});
