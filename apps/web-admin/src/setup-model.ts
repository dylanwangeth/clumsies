export type SetupState = "setup_required" | "initialized";

export type SetupStatusModel = {
  state: SetupState;
  setup_code_configured: boolean;
  oidc_configured: boolean;
  session: unknown | null;
};

export type SetupStage = "loading" | "access" | "configure" | "complete";

export type SetupForm = {
  orgName: string;
  projectName: string;
  domains: string;
};

export type SetupFormErrors = Partial<Record<keyof SetupForm, string>>;

export function resolveSetupStage(
  status: SetupStatusModel | null,
  csrfToken: string | null,
): SetupStage {
  if (!status) return "loading";
  if (status.state === "initialized") return "complete";
  return csrfToken ? "configure" : "access";
}

export function parseEmailDomains(value: string): string[] {
  return [
    ...new Set(
      value
        .split(/[\n,]/)
        .map((domain) => domain.trim().replace(/^@/, "").toLowerCase())
        .filter(Boolean),
    ),
  ].sort();
}

export function validateSetupForm(form: SetupForm): SetupFormErrors {
  const errors: SetupFormErrors = {};
  if (!validName(form.orgName)) {
    errors.orgName = "Enter an organization name between 1 and 120 characters.";
  }
  if (!validName(form.projectName)) {
    errors.projectName = "Enter a project name between 1 and 120 characters.";
  }
  const invalidDomain = parseEmailDomains(form.domains).find(
    (domain) => !validDomain(domain),
  );
  if (invalidDomain) {
    errors.domains = `${invalidDomain} is not a valid email domain.`;
  }
  return errors;
}

function validName(value: string): boolean {
  const normalized = value.trim();
  return (
    normalized.length > 0 &&
    [...normalized].length <= 120 &&
    ![...normalized].some((character) => /[\u0000-\u001f\u007f]/.test(character))
  );
}

function validDomain(domain: string): boolean {
  return (
    domain.length <= 253 &&
    domain.split(".").every(
      (label) =>
        label.length > 0 &&
        label.length <= 63 &&
        !label.startsWith("-") &&
        !label.endsWith("-") &&
        /^[a-z0-9-]+$/i.test(label),
    )
  );
}
