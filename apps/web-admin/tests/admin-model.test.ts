import { describe, expect, test } from "bun:test";
import {
  adminPath,
  credentialStatus,
  humanizeAction,
  formatDateTime,
  formatRelativeTime,
  initials,
  matchesSearch,
  parseAdminRoute,
} from "../src/admin/model";

describe("Web Admin model", () => {
  test("parses stable admin routes and falls back to overview", () => {
    expect(parseAdminRoute("/admin")).toEqual({ section: "overview" });
    expect(parseAdminRoute("/admin/members")).toEqual({ section: "members" });
    expect(parseAdminRoute("/admin/projects/prj%20one")).toEqual({
      section: "projects",
      projectId: "prj one",
    });
    expect(parseAdminRoute("/admin/setup/callback")).toEqual({ section: "overview" });
    expect(adminPath({ section: "projects", projectId: "prj one" })).toBe(
      "/admin/projects/prj%20one",
    );
  });

  test("formats compact labels without duplicating domain prefixes", () => {
    expect(humanizeAction("admin.project_member_created")).toBe(
      "Project Member Created",
    );
    expect(initials("Wei Wang", "wei@example.com")).toBe("WW");
    expect(initials(null, "owner@example.com")).toBe("O");
  });

  test("searches all meaningful row fields case-insensitively", () => {
    expect(matchesSearch(["Owner", "owner@example.com"], "EXAMPLE")).toBe(true);
    expect(matchesSearch(["Owner", "owner@example.com"], "member")).toBe(false);
  });

  test("does not crash the admin app on an invalid timestamp", () => {
    expect(formatDateTime("not-a-date")).toBe("Unavailable");
    expect(formatRelativeTime("not-a-date")).toBe("Unavailable");
  });

  test("does not present expired or malformed credentials as active", () => {
    const now = new Date("2026-07-16T12:00:00Z").getTime();
    expect(credentialStatus(false, "2026-07-16T12:01:00Z", now)).toBe("active");
    expect(credentialStatus(false, "2026-07-16T11:59:00Z", now)).toBe("expired");
    expect(credentialStatus(true, "2026-07-16T12:01:00Z", now)).toBe("revoked");
    expect(credentialStatus(false, "not-a-date", now)).toBe("unknown");
  });
});
