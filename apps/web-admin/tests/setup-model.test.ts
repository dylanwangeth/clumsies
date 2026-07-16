import { describe, expect, test } from "bun:test";
import {
  parseEmailDomains,
  resolveSetupStage,
  validateSetupForm,
} from "../src/setup-model";

describe("Web Setup model", () => {
  test("normalizes a comma or line separated domain list", () => {
    expect(parseEmailDomains(" @Example.COM, example.com\nteam.example.com ")).toEqual([
      "example.com",
      "team.example.com",
    ]);
  });

  test("requires valid names and domains", () => {
    expect(
      validateSetupForm({
        orgName: " ",
        projectName: "Default",
        domains: "bad_domain",
      }),
    ).toEqual({
      orgName: "Enter an organization name between 1 and 120 characters.",
      domains: "bad_domain is not a valid email domain.",
    });
  });

  test("derives setup stage from authority state and in-memory CSRF proof", () => {
    const required = {
      state: "setup_required" as const,
      setup_code_configured: true,
      oidc_configured: true,
      session: null,
    };
    expect(resolveSetupStage(null, null)).toBe("loading");
    expect(resolveSetupStage(required, null)).toBe("access");
    expect(resolveSetupStage(required, "csrf")).toBe("configure");
    expect(
      resolveSetupStage({ ...required, state: "initialized" }, null),
    ).toBe("complete");
  });
});
