import { expect, test } from "@playwright/test";

const TEST_MEMBER_EMAIL = "stage8.member@clumsies.local";
const TEST_PROJECT_NAME = "Stage 8 QA";

test("setup and organization governance form one complete administrator journey", async ({ page }) => {
  await page.goto(".");

  await expect(page.getByRole("heading", { name: "Claim this installation" })).toBeVisible();
  await page.getByLabel("Setup Code").fill("clumsies-web-admin-e2e-setup-code");
  await page.getByRole("button", { name: "Continue", exact: true }).click();

  await expect(page.getByRole("heading", { name: "Configure the workspace" })).toBeVisible();
  await page.getByLabel("Organization name").fill("Clumsies Lab");
  await page.getByLabel("Default project").fill("Default");
  await page.getByRole("button", { name: "Continue with SSO" }).click();

  await expect(page.getByRole("heading", { name: "Overview" })).toBeVisible();
  await expect(page.getByText("postgres reachable", { exact: true })).toBeVisible();
  await expect(page.getByText("OIDC ready", { exact: true })).toBeVisible();

  await page.getByRole("button", { name: "Members", exact: true }).click();
  const currentMemberRow = page.getByRole("row", { name: /owner@clumsies\.local/ });
  await expect(currentMemberRow.getByRole("button", { name: "Edit member" })).toBeDisabled();
  await page.getByRole("button", { name: "Invite member" }).click();
  const inviteDialog = page.getByRole("dialog", { name: "Invite member" });
  await inviteDialog.getByLabel("Email").fill(TEST_MEMBER_EMAIL);
  await inviteDialog.getByRole("button", { name: "Create invitation" }).click();

  let memberRow = page.getByRole("row", { name: new RegExp(TEST_MEMBER_EMAIL) });
  await expect(memberRow).toContainText("Invited");
  await memberRow.getByRole("button", { name: "Edit member" }).click();
  const memberDialog = page.getByRole("dialog", { name: "Edit member" });
  await memberDialog.getByLabel("Organization role").selectOption("admin");
  await memberDialog.getByRole("button", { name: "Save changes" }).click();
  memberRow = page.getByRole("row", { name: new RegExp(TEST_MEMBER_EMAIL) });
  await expect(memberRow).toContainText("Admin");

  await page.getByRole("button", { name: "Projects", exact: true }).click();
  await page.getByRole("button", { name: "New project" }).click();
  const projectDialog = page.getByRole("dialog", { name: "New project" });
  await projectDialog.getByLabel("Name").fill(TEST_PROJECT_NAME);
  await projectDialog.getByLabel("Description").fill("Temporary project for Web Admin E2E verification.");
  await projectDialog.getByRole("button", { name: "Create project" }).click();

  let projectRow = page.getByRole("row", { name: new RegExp(TEST_PROJECT_NAME) });
  await expect(projectRow).toContainText("Temporary project");
  await projectRow.getByRole("button", { name: new RegExp(TEST_PROJECT_NAME) }).click();
  await expect(page.getByRole("heading", { name: TEST_PROJECT_NAME })).toBeVisible();

  await page.getByRole("button", { name: "Add member" }).click();
  const addMemberDialog = page.getByRole("dialog", { name: "Add project member" });
  await addMemberDialog.getByLabel("Organization member").selectOption({ label: `${TEST_MEMBER_EMAIL} · ${TEST_MEMBER_EMAIL}` });
  await addMemberDialog.getByRole("button", { name: "Add member" }).click();

  let projectMemberRow = page.getByRole("row", { name: new RegExp(TEST_MEMBER_EMAIL) });
  await expect(projectMemberRow).toContainText("Member");
  await projectMemberRow.getByLabel(`Project role for ${TEST_MEMBER_EMAIL}`).selectOption("admin");
  await expect(projectMemberRow).toContainText("Admin");
  await projectMemberRow.getByRole("button", { name: "Remove project access" }).click();
  await page.getByRole("dialog", { name: "Remove project access" }).getByRole("button", { name: "Remove access" }).click();
  await expect(page.getByRole("row", { name: new RegExp(TEST_MEMBER_EMAIL) })).toHaveCount(0);

  await page.getByRole("main").getByRole("button", { name: "Projects", exact: true }).click();
  projectRow = page.getByRole("row", { name: new RegExp(TEST_PROJECT_NAME) });
  await projectRow.getByRole("button", { name: "Edit project" }).click();
  const editProjectDialog = page.getByRole("dialog", { name: "Edit project" });
  await editProjectDialog.getByLabel("Description").fill("Verified by the Stage 8 administrator journey.");
  await editProjectDialog.getByRole("button", { name: "Save changes" }).click();
  projectRow = page.getByRole("row", { name: new RegExp(TEST_PROJECT_NAME) });
  await expect(projectRow).toContainText("Verified by the Stage 8 administrator journey.");
  await projectRow.getByRole("button", { name: "Delete project" }).click();
  await page.getByRole("dialog", { name: "Delete project" }).getByRole("button", { name: "Delete project" }).click();
  await expect(page.getByRole("row", { name: new RegExp(TEST_PROJECT_NAME) })).toHaveCount(0);

  await page.getByRole("button", { name: "Access", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Enterprise identity" })).toBeVisible();
  await expect(page.getByText("Configured", { exact: true })).toBeVisible();
  await expect(page.getByRole("columnheader", { name: "Expires" })).toBeVisible();

  await page.getByRole("button", { name: "Audit", exact: true }).click();
  await page.getByRole("searchbox", { name: "Search audit events" }).fill("project");
  await expect(page.getByText("admin.project_created", { exact: true })).toBeVisible();
  await expect(page.getByText("admin.project_deleted", { exact: true })).toBeVisible();

  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await page.getByLabel("Name", { exact: true }).fill("Clumsies Lab QA");
  await page.getByRole("button", { name: "Save changes" }).click();
  await expect(page.getByText("Clumsies Lab QA", { exact: true })).toBeVisible();
  await page.getByLabel("Name", { exact: true }).fill("Clumsies Lab");
  await page.getByRole("button", { name: "Save changes" }).click();
  await expect(page.getByText("Clumsies Lab", { exact: true })).toBeVisible();

  await page.getByRole("button", { name: "Members", exact: true }).click();
  memberRow = page.getByRole("row", { name: new RegExp(TEST_MEMBER_EMAIL) });
  await memberRow.getByRole("button", { name: "Disable member" }).click();
  await page.getByRole("dialog", { name: "Disable organization member" }).getByRole("button", { name: "Disable member" }).click();
  await expect(page.getByRole("row", { name: new RegExp(TEST_MEMBER_EMAIL) })).toContainText("Disabled");

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.getByRole("button", { name: "Open navigation" })).toBeVisible();
  await page.getByRole("button", { name: "Open navigation" }).click();
  await expect(page.getByRole("navigation", { name: "Administration" })).toBeVisible();
  await page.getByRole("complementary").getByRole("button", { name: "Close navigation" }).click();
  await page.setViewportSize({ width: 1280, height: 720 });

  await page.getByRole("button", { name: "Sign out" }).click();
  await expect(page.getByRole("heading", { name: "Organization administration" })).toBeVisible();
  await page.getByRole("button", { name: "Continue with SSO" }).click();
  await expect(page.getByRole("heading", { name: "Overview" })).toBeVisible();
});
