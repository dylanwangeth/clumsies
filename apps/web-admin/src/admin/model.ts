export type AdminSection =
  | "overview"
  | "members"
  | "projects"
  | "access"
  | "audit"
  | "settings";

export type AdminRoute = {
  section: AdminSection;
  projectId?: string;
};

const SECTIONS = new Set<AdminSection>([
  "overview",
  "members",
  "projects",
  "access",
  "audit",
  "settings",
]);

export function parseAdminRoute(pathname: string): AdminRoute {
  const segments = pathname
    .replace(/^\/admin\/?/, "")
    .split("/")
    .filter(Boolean)
    .map(decodeURIComponent);
  const section = segments[0] as AdminSection | undefined;
  if (!section || !SECTIONS.has(section)) {
    return { section: "overview" };
  }
  if (section === "projects" && segments[1]) {
    return { section, projectId: segments[1] };
  }
  return { section };
}

export function adminPath(route: AdminRoute): string {
  if (route.section === "overview") return "/admin";
  if (route.section === "projects" && route.projectId) {
    return `/admin/projects/${encodeURIComponent(route.projectId)}`;
  }
  return `/admin/${route.section}`;
}

export function formatDateTime(value: string): string {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "Unavailable";
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

export function formatRelativeTime(value: string, now = Date.now()): string {
  const timestamp = new Date(value).getTime();
  if (!Number.isFinite(timestamp) || !Number.isFinite(now)) return "Unavailable";
  const deltaSeconds = Math.round((timestamp - now) / 1_000);
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  const ranges: Array<[number, Intl.RelativeTimeFormatUnit]> = [
    [60, "second"],
    [60, "minute"],
    [24, "hour"],
    [7, "day"],
  ];
  let valueInUnit = deltaSeconds;
  for (const [range, unit] of ranges) {
    if (Math.abs(valueInUnit) < range) {
      return formatter.format(Math.round(valueInUnit), unit);
    }
    valueInUnit /= range;
  }
  return formatter.format(Math.round(valueInUnit), "week");
}

export function credentialStatus(
  revoked: boolean,
  expiresAt: string | null,
  now = Date.now(),
): "active" | "expired" | "revoked" | "unknown" {
  if (revoked) return "revoked";
  if (!expiresAt) return "active";
  const expiresAtMs = new Date(expiresAt).getTime();
  if (!Number.isFinite(expiresAtMs)) return "unknown";
  return expiresAtMs <= now ? "expired" : "active";
}

export function initials(displayName: string | null, email: string): string {
  const source = displayName?.trim() || email.split("@")[0] || "?";
  const parts = source.split(/\s+/).filter(Boolean);
  return parts
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase())
    .join("");
}

export function humanizeAction(action: string): string {
  return action
    .replace(/^[^.]+\./, "")
    .split("_")
    .filter(Boolean)
    .map((word) => word[0]?.toUpperCase() + word.slice(1))
    .join(" ");
}

export function matchesSearch(values: Array<string | null | undefined>, query: string): boolean {
  const normalized = query.trim().toLocaleLowerCase();
  if (!normalized) return true;
  return values.some((value) => value?.toLocaleLowerCase().includes(normalized));
}
