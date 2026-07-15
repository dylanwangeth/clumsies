export type WindowSurface = "main" | "authentication";

export function windowSurface(search: string): WindowSurface {
  return new URLSearchParams(search).get("surface") === "authentication"
    ? "authentication"
    : "main";
}
